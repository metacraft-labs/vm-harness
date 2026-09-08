## t_vmharness_serve_roundtrip_incus — RA1 gate, REAL-backend variant.
##
## The incus-backed companion to ``t_vmharness_serve_roundtrip`` (which uses
## the sanctioned noop mock for a hermetic run). Here a REMOTE client drives
## a genuine per-job ephemeral Incus CONTAINER through a ``vm-harness serve``
## daemon: provision-free ``run --ephemeral`` (launch → in-guest exec probe →
## ``incus delete --force``), over the authenticated endpoint, leaving NO
## residual container. This proves the same remote path against a real
## backend, not just scaffolding.
##
## Host-gated (``just test-host``): needs a Linux host with a usable Incus and
## the ``vmh-base`` image (see t_vmharness_incus_ephemeral_run for the socket
## / group / ``VMH_INCUS_CMD`` notes). Self-skips cleanly otherwise.
##
## Same no-threads self-exec topology as the noop gate: the test binary
## re-execs itself as the daemon (``__serve``) and as the CLI worker
## (``__vmh_cli``).

import std/[os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli   # runCli — the local dispatch the daemon worker re-runs

when isMainModule:
  let params = commandLineParams()
  if params.len >= 1 and params[0] == "__vmh_cli":
    quit(runCli(params[1 .. ^1]))
  elif params.len >= 5 and params[0] == "__serve":
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__vmh_cli"],
      portFile: params[4],
      quiet: false)
    runServe(cfg)
    quit(0)

when not defined(linux):
  echo "[skip] t_vmharness_serve_roundtrip_incus: Linux host required"
  quit(0)

let baseImage =
  block:
    let e = getEnv("VMH_INCUS_BASE")
    if e.len > 0: e else: "vmh-base"

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

proc incusHas(name: string): bool =
  ## True iff a container named ``name`` currently exists (residue check).
  let cmd = getEnv("VMH_INCUS_CMD", "incus")
  let (outp, code) = execCmdEx(cmd & " list --format csv -c n")
  if code != 0: return false
  for line in outp.splitLines():
    if line.strip() == name: return true
  false

suite "t_vmharness_serve_roundtrip_incus":
  # Availability gate first.
  let ib = newIncusBackend(baseImage = baseImage)
  if not ib.probeAvailability():
    test "incus usable (else skip)":
      echo "[skip] incus daemon not reachable (set VMH_INCUS_CMD=\"sudo -n " &
           "incus\" if the incus-admin group is not active in this session)"
      skip()
  else:
    let work = createTempDir("vmh-serve-incus-", "")
    let tokenFile = work / "token"
    let portFile = work / "port"
    let token = "incus-test-bearer-77aa"
    writeFile(tokenFile, token)
    let jobName = "vmh-serve-rt-" & $getCurrentProcessId()

    let daemon = startProcess(getAppFilename(),
      args = @["__serve", "127.0.0.1", "0", tokenFile, portFile],
      options = {poParentStreams})
    var port = 0
    try:
      port = waitForPort(portFile)
    except CatchableError:
      daemon.terminate(); raise
    let client = newServeClient("127.0.0.1:" & $port, token)

    test "remote ephemeral incus run: launch -> probe -> destroy, no residue":
      var logs: seq[string]
      let code = client.execStream(
        @["run", "--ephemeral", "--backend", "incus",
          "--baseline", jobName, "--base-image", baseImage,
          "--timeout-sec", "90", "--", "true"],
        proc(ev: ExecEvent) =
          if ev.kind == ekLog: logs.add(ev.line))
      check code == 0
      check logs.len > 0
      # No residue: the per-job container is gone after the remote cycle.
      check not incusHas(jobName)

    test "graceful shutdown stops the daemon":
      client.shutdown()
      check daemon.waitForExit(timeout = 8000) == 0

    if daemon.running:
      daemon.terminate()
      discard daemon.waitForExit(timeout = 3000)
    daemon.close()
    # Best-effort residue cleanup in case the run aborted mid-flight.
    if incusHas(jobName):
      discard execCmdEx(getEnv("VMH_INCUS_CMD", "incus") &
                        " delete --force " & jobName)
    removeDir(work)
