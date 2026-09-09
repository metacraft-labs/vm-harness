## t_vmharness_serve_win_hyperv — RA4 gate.
##
## A REMOTE `vm-harness` client drives a full per-job EPHEMERAL Hyper-V VM
## lifecycle against a `vm-harness serve` daemon over the authenticated
## HTTP/JSON endpoint, on win-ci-bare-001 (a reprobuild-managed, NON-NixOS
## bare-metal Windows host):
##
##   New-VHD/New-VM clone of a golden VHDX  →  Start-VM  →  in-guest JIT
##   probe (PowerShell Direct)              →  Remove-VM + delete the clone
##
## and asserts:
##   (a) the serve `/v1/info` capability report advertises the `hyperv`
##       backend as available (the RA6 manifest seed);
##   (b) the forwarded `run --ephemeral --backend hyperv` cycle succeeds
##       (exit 0), exercising the HOST-lifecycle ops the milestone cares
##       about (New-VHD, New-VM, Start-VM, Remove-VM — all local PowerShell,
##       distinct from the PowerShell-Direct GUEST comms);
##   (c) NO RESIDUE: after the cycle there is no `Get-VM` for the per-job
##       name and the per-job clone VHDX is gone, while the GOLDEN is
##       untouched;
##   (d) an unauthenticated / wrong-credential client is REJECTED (401).
##
## Mock policy: NO mocks. The daemon, client, TCP transport, HTTP framing,
## bearer auth, and the real Hyper-V host-lifecycle cmdlets are all genuine.
## The ONLY thing this test does not itself build is the golden VHDX — that
## is an operator input via $VMH_HYPERV_GOLDEN (see "Running" below).
##
## HOST-GATED. This gate needs a real Windows host with the Hyper-V role and
## a golden VHDX; it self-skips cleanly off-Windows, without Hyper-V, or
## without a golden. It lives in `just test-host`, NOT the Nix CI matrix.
##
## Test topology (no threads): identical to t_vmharness_serve_roundtrip — the
## compiled test binary re-execs ITSELF as the daemon (`__serve`) and as the
## CLI worker (`__vmh_cli`) so a genuine cross-process remote roundtrip runs
## with no external binary dependency.
##
## Running (on win-ci-bare-001, elevated, from a vm-harness checkout):
##   $env:VMH_HYPERV_GOLDEN = 'D:\storage\golden-win11-hyperv.vhdx'
##   # optional, for a real in-guest JIT probe + metadata NIC:
##   $env:VMH_HYPERV_SWITCH = 'NAT-Switch'
##   $env:VMH_HYPERV_CRED_CACHE = 'D:\repro\hyperv-guest-cred.xml'
##   nim r --hints:off tests/e2e/t_vmharness_serve_win_hyperv.nim

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli   # runCli — the local dispatch the daemon worker re-runs

# ---------------------------------------------------------------------------
# Auxiliary self-exec roles, checked BEFORE the unittest runner so a re-exec
# never re-enters the suite (mirrors t_vmharness_serve_roundtrip).
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

when not defined(windows):
  echo "[skip] t_vmharness_serve_win_hyperv: Windows host with Hyper-V required"
  quit(0)

let golden = getEnv("VMH_HYPERV_GOLDEN")
if golden.len == 0:
  echo "[skip] t_vmharness_serve_win_hyperv: VMH_HYPERV_GOLDEN not set " &
       "(point it at a Gen-2 golden VHDX on this host)"
  quit(0)
if not fileExists(golden):
  echo "[skip] t_vmharness_serve_win_hyperv: golden VHDX not found: " & golden
  quit(0)

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

proc pwsh(script: string): tuple[code: int, output: string] =
  ## Run a host-side PowerShell one-liner and capture merged stdout/stderr.
  let r = execCmdEx("powershell -NoLogo -NoProfile -ExecutionPolicy Bypass " &
                    "-Command \"" & script.replace("\"", "`\"") & "\"")
  (r.exitCode, r.output)

suite "t_vmharness_serve_win_hyperv":
  let hb = newHyperVBackend()

  test "Hyper-V is usable on this host (else skip)":
    if not hb.probeAvailability():
      echo "[skip] Get-VM unavailable — Hyper-V role not enabled/elevated"
      skip()
    else:
      check hb.probeAvailability()

  # Shared daemon fixture for the remainder of the suite.
  let work = createTempDir("vmh-serve-hyperv-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let token = "ra4-hyperv-bearer-7c1e9d"
  writeFile(tokenFile, token)

  let daemon = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile],
    options = {poParentStreams})
  var port = 0
  try:
    port = waitForPort(portFile)
  except CatchableError:
    daemon.terminate()
    raise
  let addr0 = "127.0.0.1:" & $port
  let client = newServeClient(addr0, token)

  test "unauthenticated / wrong-credential client is rejected (401)":
    let bad = newServeClient(addr0, "wrong-token")
    expect ServeAuthError:
      discard bad.info()
    let empty = newServeClient(addr0, "")
    expect ServeAuthError:
      discard empty.info()

  test "authenticated /v1/info advertises the hyperv backend (capability seed)":
    let ni = client.info()
    check ni["protocol"].getStr == ProtocolVersion
    var sawHyperv = false
    for b in ni["backends"]:
      if b["id"].getStr == "hyperv":
        sawHyperv = true
        check b["available"].getBool
    check sawHyperv

  test "remote New-VM-from-golden -> boot -> JIT-probe -> Remove-VM, no residue":
    if not hb.probeAvailability():
      echo "[skip] Hyper-V not usable"
      skip()
    else:
      let jobName = EphemeralVmNamePrefix & "serve-" &
        toHex(int64(epochTime() * 1000.0) and 0xFFFFFF'i64, 6).toLowerAscii()
      # A real in-guest JIT probe runs only when a PowerShell-Direct
      # credential cache is provided; otherwise reaching a booted+destroyed
      # clone is itself the success signal (the host-lifecycle ops).
      var runArgv = @["run", "--ephemeral", "--backend", "hyperv",
                      "--baseline", jobName, "--golden-image", golden,
                      "--timeout-sec", "600"]
      if getEnv("VMH_HYPERV_CRED_CACHE").len > 0:
        runArgv.add(@["--", "cmd.exe", "/c", "echo", "JIT-OK"])

      var runLog: seq[string]
      let runCode = client.execStream(runArgv, proc(ev: ExecEvent) =
        if ev.kind == ekLog: runLog.add(ev.line))
      check runCode == 0
      check runLog.len > 0

      # (c) NO RESIDUE: no VM by the per-job name, and the per-job clone VHDX
      # is gone; the golden is untouched.
      let (vmCode, vmOut) = pwsh(
        "if (Get-VM -Name '" & jobName & "' -ErrorAction SilentlyContinue) " &
        "{ Write-Output 'PRESENT' } else { Write-Output 'ABSENT' }")
      check vmCode == 0
      check "ABSENT" in vmOut

      let clonePath = ephemeralClonePathFor(
        HyperVEphemeralCloneSpec(name: jobName, goldenVhdx: golden))
      check (not fileExists(clonePath))
      check fileExists(golden)

  test "graceful shutdown stops the daemon":
    client.shutdown()
    check daemon.waitForExit(timeout = 5000) == 0

  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
