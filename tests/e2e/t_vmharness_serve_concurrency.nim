## t_vmharness_serve_concurrency — the concurrent-serve gate.
##
## Proves that ``vm-harness serve`` handles connections CONCURRENTLY: a single
## slow ``/v1/exec`` must NOT block unrelated connections. This is the
## behaviour the central-GARM driver depends on — it fires many simultaneous
## create/delete/retry calls, and a serially-handled daemon times those out
## (``net/http: timeout awaiting response headers``) so no runner registers.
##
## Falsifiability: this test is written to FAIL against the previous SERIAL
## accept loop and PASS against the thread-pool loop. With the serial loop a
## slow exec occupies the one accept loop for its whole duration, so a batch of
## fast execs issued after it queues in the listen backlog and only completes
## once the slow exec finishes (≈ slowSec). With the concurrent loop the fast
## batch completes in milliseconds while the slow exec is still in flight. The
## timing threshold (``elapsed < 2.5``) sits far below ``slowSec = 5`` so the
## two regimes are cleanly separated.
##
## Mock policy (design doc §9.1): NO backends are exercised at all — the daemon
## worker is this same test binary re-execed in a trivial ``__work`` role
## (``sleep``/``quick``) so the test measures ONLY the serve dispatch
## concurrency, hermetically and with no hypervisor. The daemon, the TCP
## transport, the HTTP/NDJSON framing, and the bearer auth are all REAL.
##
## Test topology (processes, no in-test threads — mirrors the roundtrip gate):
## the compiled binary re-execs ITSELF in three auxiliary roles:
##   * ``<binary> __serve <host> <port> <tokenFile> <portFile> <threads>``
##     runs the daemon (worker = this same binary in the ``__work`` role);
##   * ``<binary> __work quick`` prints a line and exits 0;
##   * ``<binary> __work sleep <sec>`` sleeps then exits 0 (the slow worker);
##   * ``<binary> __slowreq <host> <port> <tokenFile> <sec> <doneFile>`` is a
##     standalone client that fires one slow exec and records its exit code —
##     run as a separate PROCESS so it genuinely occupies a worker thread for
##     the whole ``sleep`` duration.

import std/[os, osproc, strutils, tempfiles, times, unittest]
import vm_harness

# ---------------------------------------------------------------------------
# Auxiliary self-exec roles. Checked BEFORE the unittest runner so a re-exec
# never re-enters the suite.

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == "__work":
    if params[1] == "sleep" and params.len >= 3:
      stdout.writeLine("slow-start")
      stdout.flushFile()
      sleep(parseInt(params[2]) * 1000)
      stdout.writeLine("slow-done")
      quit(0)
    else:
      stdout.writeLine("quick-ok")
      quit(0)
  elif params.len >= 6 and params[0] == "__serve":
    let cfg = ServeConfig(
      listenHost: params[1],
      listenPort: parseInt(params[2]),
      token: readFile(params[3]).strip(),
      workerExe: getAppFilename(),
      workerArgPrefix: @["__work"],
      portFile: params[4],
      serveThreads: parseInt(params[5]),
      quiet: true)
    runServe(cfg)
    quit(0)
  elif params.len >= 6 and params[0] == "__slowreq":
    # host port tokenFile sleepSec doneFile
    let addr0 = params[1] & ":" & params[2]
    let cl = newServeClient(addr0, readFile(params[3]).strip())
    let code = cl.execStream(@["sleep", params[4]],
                             proc(ev: ExecEvent) = discard)
    writeFile(params[5], $code)
    quit(0)

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

suite "t_vmharness_serve_concurrency":
  let work = createTempDir("vmh-conc-", "")
  let tokenFile = work / "token"
  let portFile = work / "port"
  let doneFile = work / "slow-done"
  let token = "conc-test-bearer-8ac1"
  writeFile(tokenFile, token)

  # Four accept-loop threads: one is occupied by the slow exec, three remain
  # free for the fast batch. (Even a single free thread would suffice.)
  #
  # Falsifiability seam: ``VMH_CONC_TEST_THREADS=1`` forces a ONE-thread pool,
  # which makes the new loop behave EXACTLY like the old serial accept loop —
  # the fast batch then queues behind the slow exec and the timing assertions
  # below fail. That is how this test was confirmed to discriminate the fix
  # from the regression; the default (4) is what CI runs.
  let threadArg = getEnv("VMH_CONC_TEST_THREADS", "4")
  let daemon = startProcess(
    getAppFilename(),
    args = @["__serve", "127.0.0.1", "0", tokenFile, portFile, threadArg],
    options = {poParentStreams})
  var port = 0
  try:
    port = waitForPort(portFile)
  except CatchableError:
    daemon.terminate()
    raise

  let addr0 = "127.0.0.1:" & $port
  let client = newServeClient(addr0, token)

  test "a slow exec does not serialize concurrent fast execs":
    const slowSec = 5

    # 1. Fire a slow request in a SEPARATE PROCESS so it genuinely holds a
    #    worker for slowSec seconds.
    let slow = startProcess(
      getAppFilename(),
      args = @["__slowreq", "127.0.0.1", $port, tokenFile, $slowSec, doneFile],
      options = {poParentStreams})
    # Let it connect and occupy a worker before we time the fast batch.
    sleep(1200)
    check slow.running
    check not fileExists(doneFile)          # slow request still in flight

    # 2. Time a batch of fast execs. Serial loop ⇒ these queue behind the slow
    #    exec (≈ slowSec); concurrent loop ⇒ they finish in milliseconds.
    let t0 = epochTime()
    for k in 0 ..< 5:
      var got = ""
      let code = client.execStream(@["quick"], proc(ev: ExecEvent) =
        if ev.kind == ekLog: got.add(ev.line))
      check code == 0
      check "quick-ok" in got
    let elapsed = epochTime() - t0

    # The batch completed well within the slow request's lifetime — proof it
    # was NOT serialized behind it. Threshold sits far below slowSec = 5.
    check elapsed < 2.5
    # The slow request is genuinely still running at this point.
    check not fileExists(doneFile)
    check slow.running

    # 3. Let the slow request finish cleanly and confirm its exit code.
    discard slow.waitForExit(timeout = (slowSec + 10) * 1000)
    check fileExists(doneFile)
    check readFile(doneFile).strip == "0"
    slow.close()

  test "graceful shutdown stops the daemon":
    client.shutdown()
    check daemon.waitForExit(timeout = 8000) == 0

  # Fixture teardown.
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(timeout = 3000)
  daemon.close()
  removeDir(work)
