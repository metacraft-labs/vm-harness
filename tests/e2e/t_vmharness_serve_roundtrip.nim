## t_vmharness_serve_roundtrip — RA1 gate.
##
## A REMOTE ``vm-harness`` client drives a full provision → run(exec probe)
## → destroy cycle against a ``vm-harness serve`` daemon over the
## authenticated HTTP/JSON endpoint, and:
##
##   (a) the run leaves NO residue and is byte-equivalent to the local
##       ``vm-harness run`` path (the envelope the daemon writes is compared,
##       normalized for timings, against a locally-produced one for the
##       identical argv);
##   (b) an unauthenticated / wrong-credential client is REJECTED (HTTP 401,
##       surfaced as ``ServeAuthError``) before any work runs.
##
## Mock policy (design doc §9.1): the ONLY mock is ``NoopBackend`` — the
## sanctioned test fixture — used so the roundtrip is hermetic (no real
## hypervisor). The daemon, the client, the TCP transport, the HTTP framing,
## and the bearer-token auth are all REAL. The incus-backed variant that
## exercises a real backend over the same endpoint lives behind
## ``just test-host`` (``t_vmharness_serve_roundtrip_incus``).
##
## Test topology (no threads): the compiled test binary re-execs ITSELF in
## two auxiliary roles so a genuine cross-process remote roundtrip runs with
## no external binary dependency:
##   * ``<binary> __serve <host> <port> <tokenFile> <portFile>`` runs the
##     daemon (worker = this same binary in ``__vmh_cli`` mode);
##   * ``<binary> __vmh_cli <argv...>`` runs the real vm-harness CLI.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/cli   # runCli — the local dispatch the daemon worker re-runs

# ---------------------------------------------------------------------------
# Auxiliary self-exec roles. Checked BEFORE the unittest runner so a re-exec
# never re-enters the suite.

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

proc normalizeEnvelope(s: string): string =
  ## Strip the non-deterministic parts of an output-envelope file (per-step
  ## ``elapsed_ms`` values and ISO-8601 log timestamps) so two runs of the
  ## identical argv can be compared for byte-equivalence.
  for line in s.splitLines():
    var l = line
    let ei = l.find("elapsed_ms:")
    if ei >= 0:
      l = l[0 ..< ei] & "elapsed_ms: N"
    if l.len >= 20 and l[4] == '-' and l[7] == '-' and l[10] == 'T' and
       l[19] == 'Z':
      let sp = l.find(' ')
      if sp > 0:
        l = "TS" & l[sp .. ^1]
    result.add(l & "\n")

proc waitForPort(portFile: string, timeoutSec = 10.0): int =
  ## Poll the daemon's port-file until it reports its bound port.
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    if fileExists(portFile):
      let raw = readFile(portFile).strip()
      if raw.len > 0:
        try: return parseInt(raw)
        except ValueError: discard
    sleep(50)
  raise newException(IOError, "daemon did not report a port within timeout")

suite "t_vmharness_serve_roundtrip":
  # Shared daemon fixture for the whole suite.
  let work = createTempDir("vmh-serve-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let token = "unit-test-bearer-3f9a2c"
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
    expect ServeAuthError:
      discard bad.execStream(@["probe"], proc(ev: ExecEvent) = discard)
    # An empty token is likewise rejected.
    let empty = newServeClient(addr0, "")
    expect ServeAuthError:
      discard empty.info()

  test "authenticated info advertises the noop backend (capability seed)":
    let ni = client.info()
    check ni["protocol"].getStr == ProtocolVersion
    check ni["service"].getStr == ServiceName
    var sawNoop = false
    for b in ni["backends"]:
      if b["id"].getStr == "noop":
        sawNoop = true
        check b["available"].getBool
    check sawNoop

  test "remote provision -> run(exec probe) -> destroy, no residue, " &
       "byte-equivalent to local":
    let remoteOut = work / "remote-out"
    let localOut = work / "local-out"
    let runArgv = @["run", "--backend", "noop", "--baseline", "rt",
                    "--output-dir", remoteOut, "--", "/bin/echo", "hello"]

    # 1. provision over RPC.
    var provLog: seq[string]
    let provCode = client.execStream(
      @["provision", "--backend", "noop", "--baseline", "rt"],
      proc(ev: ExecEvent) =
        if ev.kind == ekLog: provLog.add(ev.line))
    check provCode == 0

    # 2. run (revert -> exec probe -> cleanup/destroy) over RPC, streaming.
    var runLog: seq[string]
    let runCode = client.execStream(runArgv, proc(ev: ExecEvent) =
      if ev.kind == ekLog: runLog.add(ev.line))
    check runCode == 0
    # The stream actually carried live log lines from the daemon worker.
    check runLog.len > 0

    # 3. The daemon wrote a complete envelope (shared FS on loopback).
    check fileExists(remoteOut / "DONE")
    check readFile(remoteOut / "DONE").strip == "PASS"
    let remoteResult = readFile(remoteOut / "RESULT.txt")
    check "verdict: PASS" in remoteResult
    # "destroy / no residue" evidence: the per-gate cleanup step ran ok.
    check "step: cleanup  status: ok" in remoteResult

    # 4. Byte-equivalence: run the identical argv LOCALLY and compare the
    #    envelope (normalized for timings). Same binary, same backend code.
    var localArgv = runArgv
    localArgv[localArgv.find(remoteOut)] = localOut
    check runCli(localArgv) == 0

    check normalizeEnvelope(readFile(remoteOut / "RESULT.txt")) ==
          normalizeEnvelope(readFile(localOut / "RESULT.txt"))
    check readFile(remoteOut / "DONE") == readFile(localOut / "DONE")
    # The per-command artifact (02-echo-run.txt) is identical too.
    proc runArtifact(dir: string): string =
      for kind, path in walkDir(dir):
        if kind == pcFile and "02-echo" in extractFilename(path):
          return readFile(path)
      ""
    let remoteArt = runArtifact(remoteOut)
    let localArt = runArtifact(localOut)
    check remoteArt.len > 0
    check normalizeEnvelope(remoteArt) == normalizeEnvelope(localArt)

  test "graceful shutdown stops the daemon":
    client.shutdown()
    check daemon.waitForExit(timeout = 5000) == 0

  # Fixture teardown: make sure the daemon is gone and the temp dir removed.
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
