## Bounded POSIX process capture, draining both outputs while feeding stdin.
import std/tables
import ./types
when defined(posix):
  import std/[os, osproc, streams, strtabs, times, posix]

proc captureCommand*(cmd: seq[string], cwd = "", timeoutSec = 0,
                     env = initTable[string, string](), stdinData = "",
                     mergeStderr = true): ExecResult =
  when defined(posix):
    if cmd.len == 0: raise newException(ValueError, "empty process argv")
    var childEnv = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): childEnv[k] = v
    for k, v in env: childEnv[k] = v
    let started = epochTime()
    let p = startProcess(cmd[0], workingDir = cwd, args = cmd[1..^1],
      env = childEnv, options = {poUsePath})
    defer:
      if p.running:
        p.kill()
        discard p.waitForExit()
      p.close()
    let outFd = cint(p.outputHandle)
    let errFd = cint(p.errorHandle)
    let inFd = cint(p.inputHandle)
    for fd in [outFd, errFd, inFd]:
      let flags = fcntl(fd, F_GETFL)
      if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
        raiseOSError(osLastError())
    var sent = 0
    var inputClosed = false
    var outputClosed, errorClosed: bool
    proc drain(fd: cint, dest: var string, closed: var bool) =
      var bytes: array[8192, char]
      let n = posix.read(fd, addr bytes[0], bytes.len)
      if n > 0:
        for i in 0..<int(n): dest.add(bytes[i])
      elif n == 0: closed = true
      elif errno notin [EAGAIN, EINTR]: raiseOSError(osLastError())
    while true:
      if not outputClosed: drain(outFd, result.stdout, outputClosed)
      if not errorClosed:
        if mergeStderr: drain(errFd, result.stdout, errorClosed)
        else: drain(errFd, result.stderr, errorClosed)
      if not inputClosed:
        if sent < stdinData.len and p.running:
          let n = posix.write(inFd, unsafeAddr stdinData[sent],
                              min(8192, stdinData.len - sent))
          if n > 0: sent += int(n)
          elif n < 0 and errno notin [EAGAIN, EINTR, EPIPE]:
            raiseOSError(osLastError())
          elif n < 0 and errno == EPIPE: sent = stdinData.len
        if sent == stdinData.len or not p.running:
          # Close through the stream so osproc does not later close a reused fd.
          p.inputStream.close()
          inputClosed = true
      if outputClosed and errorClosed and not p.running: break
      if timeoutSec > 0 and epochTime() - started >= float(timeoutSec):
        p.kill()
        discard p.waitForExit()
        result.exitCode = 124
        result.stderr.add("vm-harness: process timed out\n")
        result.elapsedMs = int((epochTime() - started) * 1000)
        return
      sleep(5)
    result.exitCode = p.waitForExit()
    result.elapsedMs = int((epochTime() - started) * 1000)
  else:
    raise newException(BackendUnavailableError,
      "bounded process capture currently requires POSIX")
