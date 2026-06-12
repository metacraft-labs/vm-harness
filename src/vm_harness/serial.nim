## Shared serial-stream line buffer + regex matcher used by every
## backend's ``captureSerial`` / ``expectLine`` implementation.
##
## Backends push raw bytes via ``feed``; ``expectLineImpl`` scans forward
## for a Perl-flavoured regex match and advances a cursor so subsequent
## calls don't re-match the same line. This is the Nim port of the
## reprobuild boot-harness's ``lib/assertions.LineBuffer`` (Python).
##
## The buffer also tees writes to ``logPath`` so a post-mortem of the raw
## serial stream survives the harness process. Logging is best-effort —
## a failed write does not abort the assertion.
##
## Concrete backends embed a ``SerialLineBuffer`` in their own
## ``SerialStream`` subtype and forward the ``expectLine`` /
## ``serialSend`` methods to it (with a backend-specific "feed more bytes
## from the pipe / pump" callback when the buffer is exhausted).

import std/[os, locks, re, streams, times]
import ./types

type
  SerialLineBuffer* = ref object
    ## Backend-agnostic serial accumulator. Producer-side ``feed`` may
    ## run from a reader thread; consumer-side ``expectLineImpl`` reads
    ## from the main thread. A Lock serialises access to ``text`` /
    ## ``cursor`` / ``history``.
    text*: string                  ## bytes received so far (concatenated)
    cursor*: int                   ## index past the last matched line
    history*: seq[string]          ## per-match captured text (for capture_until)
    logPath*: string               ## host-side raw-bytes log (optional)
    logFile: File                  ## opened log file, nil if logPath = ""
    lock*: Lock                    ## guards text/cursor/history mutations

proc newSerialLineBuffer*(logPath: string = ""): SerialLineBuffer =
  ## Construct a fresh buffer. When ``logPath`` is non-empty the file is
  ## opened immediately in fmWrite mode; failure to open is silent (we
  ## prefer to record nothing rather than abort the boot assertion).
  result = SerialLineBuffer(text: "", cursor: 0,
                            history: @[], logPath: logPath)
  initLock(result.lock)
  if logPath.len > 0:
    try:
      createDir(parentDir(logPath))
      result.logFile = open(logPath, fmWrite)
    except CatchableError:
      result.logFile = nil

proc feed*(b: SerialLineBuffer, bytes: string) =
  ## Append a chunk of newly-arrived bytes. Tees to ``logPath``. Safe
  ## to call from a reader thread; takes the buffer's lock.
  if bytes.len == 0: return
  withLock(b.lock):
    b.text.add(bytes)
    if b.logFile != nil:
      try:
        b.logFile.write(bytes)
        b.logFile.flushFile()
      except CatchableError:
        discard

proc close*(b: SerialLineBuffer) =
  ## Close the underlying log file. Safe in finally blocks.
  withLock(b.lock):
    if b.logFile != nil:
      try: b.logFile.close()
      except CatchableError: discard
      b.logFile = nil

proc expectLineImpl*(b: SerialLineBuffer, pattern: string,
                    timeoutMs: int, pollMs: int = 100,
                    feedMore: proc() {.closure.} = nil): SerialMatch =
  ## Block until ``pattern`` matches a line in the accumulated text, or
  ## the timeout expires. The match advances ``b.cursor`` past the
  ## matched substring so a subsequent ``expectLineImpl`` call starts
  ## scanning after it.
  ##
  ## ``feedMore`` is the backend's "pump more bytes from the serial
  ## pipe/process into ``b.text``" callback. When nil, we just poll and
  ## hope the producer is feeding the buffer from another thread.
  ##
  ## ``pattern`` uses Nim's std/re (PCRE-flavoured) with multi-line + dot-
  ## matches-newline flags off. The caller can pre-anchor with ``^`` /
  ## ``$`` if they want strict line semantics.
  let rx = re(pattern, {})
  let start = epochTime()
  let deadlineSec = start + (timeoutMs.float / 1000.0)
  result = SerialMatch(matched: false, matchedText: "",
                       elapsedMs: 0, timedOut: false)
  while true:
    if feedMore != nil: feedMore()
    var matched = false
    withLock(b.lock):
      let bounds = findBounds(b.text, rx, b.cursor)
      if bounds.first >= 0:
        let matchStart = bounds.first
        let matchEnd = bounds.last + 1
        let captured = b.text[b.cursor ..< matchEnd]
        b.history.add(captured)
        let only = b.text[matchStart ..< matchEnd]
        b.cursor = matchEnd
        result.matched = true
        result.matchedText = only
        result.elapsedMs = int((epochTime() - start) * 1000)
        matched = true
    if matched: return
    if epochTime() >= deadlineSec:
      result.timedOut = true
      result.elapsedMs = int((epochTime() - start) * 1000)
      # Include the last 400 chars of unconsumed tail for post-mortem.
      withLock(b.lock):
        let tailStart = max(b.cursor, b.text.len - 400)
        if tailStart < b.text.len:
          result.matchedText = b.text[tailStart ..< b.text.len]
      return
    sleep(pollMs)

proc captureUntilImpl*(b: SerialLineBuffer, pattern: string,
                      timeoutMs: int, pollMs: int = 100,
                      feedMore: proc() {.closure.} = nil): string =
  ## Like ``expectLineImpl`` but returns the captured text from the
  ## previous cursor up to and including the matched line. Useful for
  ## the consumer that wants the full block of output the guest emitted
  ## between two markers.
  discard expectLineImpl(b, pattern, timeoutMs, pollMs, feedMore)
  if b.history.len > 0:
    return b.history[^1]
  return ""

# ---------------------------------------------------------------------------
# Concrete SerialStream subtype that backends can extend or use directly.
# Most backends will subclass to attach their own pipe handle / process
# state, but the line-buffer logic is reusable.

type
  BufferedSerialStream* = ref object of SerialStream
    buf*: SerialLineBuffer
    feedMore*: proc() {.closure.}      ## backend-supplied "pump" callback
    onSend*: proc(text: string) {.closure.} ## backend-supplied input writer
    onClose*: proc() {.closure.}            ## backend-supplied teardown

proc newBufferedSerialStream*(vm: VmHandle, logPath: string,
                             feedMore: proc() {.closure.} = nil,
                             onSend: proc(text: string) {.closure.} = nil,
                             onClose: proc() {.closure.} = nil
                             ): BufferedSerialStream =
  result = BufferedSerialStream(
    vm: vm,
    logPath: logPath,
    buf: newSerialLineBuffer(logPath),
    feedMore: feedMore,
    onSend: onSend,
    onClose: onClose)

proc expectLineBuffered*(s: BufferedSerialStream, pattern: string,
                        timeoutSec: int): SerialMatch =
  expectLineImpl(s.buf, pattern, timeoutSec * 1000, 100, s.feedMore)

proc serialSendBuffered*(s: BufferedSerialStream, text: string) =
  if s.onSend != nil:
    s.onSend(text)

proc closeBuffered*(s: BufferedSerialStream) =
  if s.onClose != nil:
    try: s.onClose()
    except CatchableError: discard
  s.buf.close()

# ---------------------------------------------------------------------------
# Reader-thread pattern for backends that pump bytes from a child
# process's stdout into a SerialLineBuffer. The reader runs on its own
# Nim thread, blocks in readData(), and lets the main thread poll the
# buffer via expectLineImpl without ever blocking the harness loop.

import std/osproc

type
  PipeReaderState* = ref object
    ## Heap-allocated state shared between the main thread and the
    ## reader thread. Using a ref ensures the stopFlag's address is
    ## stable across moves.
    proc1*: Process
    buf*: SerialLineBuffer
    stopFlag*: bool
    chunkSize*: int

  PipeReader* = ref object
    thread*: ptr Thread[PipeReaderState]
    state*: PipeReaderState

proc pipeReaderProc(state: PipeReaderState) {.thread.} =
  ## Thread proc: blocks in readData() until the child closes the pipe
  ## or stopFlag flips. The blocking is OK because we run on a
  ## dedicated thread; the main thread's expectLine polls the buffer
  ## without ever entering readData() itself.
  if state == nil: return
  let outStream = state.proc1.outputStream
  if outStream == nil: return
  var chunk = newString(state.chunkSize)
  while true:
    if state.stopFlag: break
    var n = 0
    try:
      n = outStream.readData(addr chunk[0], chunk.len)
    except CatchableError:
      break
    if n <= 0: break
    var slice = newString(n)
    for i in 0 ..< n: slice[i] = chunk[i]
    state.buf.feed(slice)

proc startPipeReader*(p: Process, buf: SerialLineBuffer,
                     chunkSize: int = 4096): PipeReader =
  ## Spawn a reader thread that pumps the child process's stdout into
  ## the supplied buffer. The returned PipeReader keeps the thread + the
  ## state alive; call ``stopPipeReader`` from the close path.
  let state = PipeReaderState(
    proc1: p, buf: buf, stopFlag: false, chunkSize: chunkSize)
  let th = cast[ptr Thread[PipeReaderState]](
    alloc0(sizeof(Thread[PipeReaderState])))
  createThread(th[], pipeReaderProc, state)
  result = PipeReader(thread: th, state: state)

proc stopPipeReader*(r: PipeReader) =
  ## Signal the reader thread to exit and join it. Safe in finally
  ## blocks; never raises. The caller is responsible for terminating
  ## the underlying Process first (which will close the pipe and let
  ## the reader fall out of readData()).
  if r == nil or r.state == nil: return
  r.state.stopFlag = true
  if r.thread != nil:
    try: joinThread(r.thread[])
    except CatchableError: discard
    try: dealloc(r.thread)
    except CatchableError: discard
    r.thread = nil


