## t_vmharness_serve_macos_tart — RA5 gate, REAL-backend variant.
##
## The tart-backed companion to ``t_vmharness_serve_roundtrip`` /
## ``t_vmharness_serve_roundtrip_incus``. Here a REMOTE client drives a
## genuine per-job ephemeral **tart** guest through a ``vm-harness serve``
## daemon — the access point tart lacks natively, proving the "network
## access point where native remote is missing" case from the campaign.
##
## The remote path clones the tart golden into a uniquely-prefixed
## ephemeral, boots it, runs an in-guest probe, and tears it down, leaving
## NO residual tart VM (``tart list`` no longer reports the prefix). The
## argv mirrors what ``garm-provider-vmharness`` actually sends for a tart
## instance (``run --backend <tart> --guest linux --baseline <image>
## --ephemeral-prefix <p> …``), so the serve-driven path is byte-equivalent
## to the local GARM-driven one.
##
## Host-gated (``just test-host``): needs a macOS/Apple-silicon host with a
## usable ``tart`` + ``sshpass`` (i.e. m3 — the campaign's macOS/tart host).
## Self-skips cleanly on any other host. Defaults to the CHEAP Linux-ARM
## golden (the campaign gate accepts "macOS OR Linux-ARM tart VM"); set
## ``VMH_TART_SERVE_MACOS=1`` to exercise the (multi-GB) macOS golden
## instead, and ``VMH_TART_SERVE_IMAGE`` to override the source image.
##
## Same no-threads self-exec topology as the other serve gates: the test
## binary re-execs itself as the daemon (``__serve``) and as the CLI worker
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

when not defined(macosx):
  echo "[skip] t_vmharness_serve_macos_tart: macOS (Apple-silicon m3) host required"
  quit(0)

let useMacos = getEnv("VMH_TART_SERVE_MACOS", "") == "1"
let guestOs = if useMacos: goMacos else: goLinux
# The `--backend` argv value is the CLI id STRING (not the `$BackendId` enum
# symbol) — the same value garm-provider-vmharness sends.
let backendId = if useMacos: "tart-macos" else: "tart-linux-arm"

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

proc tartHasPrefix(prefix: string): bool =
  ## True iff any tart VM name starts with ``prefix`` (residue check).
  let cmd = getEnv("VMH_TART_CMD", "tart")
  let (outp, code) = execCmdEx(cmd & " list --format csv")
  if code != 0: return false
  for line in outp.splitLines():
    for field in line.split(','):
      if field.strip().startsWith(prefix): return true
  false

suite "t_vmharness_serve_macos_tart":
  # Availability gate first: skip cleanly unless tart + sshpass are usable.
  let b = newTartBackend(guestOs = guestOs)
  if not b.probeAvailability():
    test "tart usable (else skip)":
      echo "[skip] tart or sshpass missing on PATH; install via " &
           "`nix profile install nixpkgs#tart nixpkgs#sshpass`"
      skip()
  elif useMacos and getEnv("VMH_TART_SKIP_MACOS", "") == "1":
    test "macOS golden opted out (skip)":
      echo "[skip] VMH_TART_SKIP_MACOS=1 set; the macOS golden pull is multi-GB"
      skip()
  else:
    let sourceImage =
      block:
        let e = getEnv("VMH_TART_SERVE_IMAGE")
        if e.len > 0: e else: b.goldenImage
    let work = createTempDir("vmh-serve-tart-", "")
    let tokenFile = work / "token"
    let portFile = work / "port"
    let outDir = work / "out"
    let token = "tart-serve-bearer-91ce"
    writeFile(tokenFile, token)
    # A per-run ephemeral prefix so the residue check is scoped to THIS job.
    let prefix = "vmh-serve-tart-" & $getCurrentProcessId()

    let daemon = startProcess(getAppFilename(),
      args = @["__serve", "127.0.0.1", "0", tokenFile, portFile],
      options = {poParentStreams})
    var port = 0
    try:
      port = waitForPort(portFile)
    except CatchableError:
      daemon.terminate(); raise
    let client = newServeClient("127.0.0.1:" & $port, token)

    test "remote ephemeral tart run: clone -> boot -> probe -> destroy, no residue":
      var logs: seq[string]
      # Mirror the provider's tart argv: baseline (golden) + ephemeral-prefix
      # drive the per-job clone; the in-guest probe stands in for the JIT
      # runner bootstrap. The macOS golden pull is slow on first run, so the
      # timeout is generous.
      let code = client.execStream(
        @["run", "--backend", backendId, "--guest",
          (if useMacos: "macos" else: "linux"),
          "--baseline", sourceImage,
          "--ephemeral-prefix", prefix,
          "--output-dir", outDir,
          "--timeout-sec", "900", "--", "true"],
        proc(ev: ExecEvent) =
          if ev.kind == ekLog: logs.add(ev.line))
      check code == 0
      check logs.len > 0
      # No residue: the per-job ephemeral clone is gone after the remote cycle.
      check not tartHasPrefix(prefix)

    test "graceful shutdown stops the daemon":
      client.shutdown()
      check daemon.waitForExit(timeout = 8000) == 0

    if daemon.running:
      daemon.terminate()
      discard daemon.waitForExit(timeout = 3000)
    daemon.close()
    # Best-effort residue cleanup in case the run aborted mid-flight.
    if tartHasPrefix(prefix):
      discard execCmdEx(getEnv("VMH_TART_CMD", "tart") & " prune")
    removeDir(work)
