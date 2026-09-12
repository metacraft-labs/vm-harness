## vm-harness serve — minimal HTTP/1.1 framing over ``std/net``.
##
## A deliberately small, hand-rolled HTTP/1.1 subset shared by the daemon
## (``server.nim``) and the client (``client.nim``). We do NOT pull in
## ``std/asynchttpserver`` because (a) it is async-only while the vm-harness
## core is synchronous by design (design doc §12.4), and (b) we need precise
## control over CHUNKED streaming to carry the NDJSON exec-event stream with
## incremental flushes. Both ends are ours, so only the subset we use is
## implemented: request line + headers + ``Content-Length`` body on the
## request side; status line + headers + (buffered OR chunked) body on the
## response side.
##
## Line reads are done byte-at-a-time (headers are tiny) to avoid the
## ``recvLine`` empty-line/closed-connection ambiguity; bodies and chunks use
## sized ``recv``.

import std/[net, strutils, tables]

type
  HttpRequest* = object
    httpMethod*: string
    path*: string
    headers*: Table[string, string]   ## keys lower-cased
    body*: string

  HttpResponse* = object
    status*: int
    headers*: Table[string, string]   ## keys lower-cased
    body*: string

  HttpError* = object of CatchableError

proc recvLineRaw(sock: Socket): tuple[line: string, closed: bool] =
  ## Read one CRLF- (or LF-) terminated line. Returns ``closed=true`` when
  ## the peer closed the connection before any newline. The trailing
  ## ``\r`` / ``\n`` is stripped from ``line``.
  var line = ""
  while true:
    var ch = ""
    let n = sock.recv(ch, 1)
    if n <= 0:
      return (line: line, closed: line.len == 0)
    if ch == "\n":
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      return (line: line, closed: false)
    line.add(ch)

proc recvExactly(sock: Socket, n: int): string =
  ## Read exactly ``n`` bytes (blocking). Raises ``HttpError`` on early EOF.
  result = newStringOfCap(n)
  var remaining = n
  while remaining > 0:
    var buf = ""
    let got = sock.recv(buf, remaining)
    if got <= 0:
      raise newException(HttpError,
        "unexpected EOF: wanted " & $n & " bytes, got " & $result.len)
    result.add(buf)
    remaining -= got

proc parseHeaderLine(line: string, headers: var Table[string, string]) =
  let idx = line.find(':')
  if idx <= 0:
    return
  let key = line[0 ..< idx].strip().toLowerAscii()
  let val = line[idx + 1 .. ^1].strip()
  headers[key] = val

# ---------------------------------------------------------------------------
# Server side.

proc readRequest*(client: Socket): HttpRequest =
  ## Read a complete request: request line, headers, and a
  ## ``Content-Length``-delimited body (the only body framing the daemon
  ## accepts). Raises ``HttpError`` on a malformed request line.
  result.headers = initTable[string, string]()
  let (reqLine, closed) = recvLineRaw(client)
  if closed and reqLine.len == 0:
    raise newException(HttpError, "connection closed before request line")
  let parts = reqLine.splitWhitespace()
  if parts.len < 2:
    raise newException(HttpError, "malformed request line: " & reqLine)
  result.httpMethod = parts[0].toUpperAscii()
  result.path = parts[1]
  while true:
    let (h, hClosed) = recvLineRaw(client)
    if h.len == 0:
      break                       # blank line terminates headers
    if hClosed:
      break
    parseHeaderLine(h, result.headers)
  let clen = result.headers.getOrDefault("content-length", "0")
  let n = try: parseInt(clen) except ValueError: 0
  if n > 0:
    result.body = recvExactly(client, n)

proc sendResponse*(client: Socket, status: int, body: string,
                   contentType = "application/json") =
  ## Send a buffered response with an explicit ``Content-Length``.
  let reason = case status
               of 200: "OK"
               of 400: "Bad Request"
               of 401: "Unauthorized"
               of 404: "Not Found"
               of 405: "Method Not Allowed"
               of 500: "Internal Server Error"
               else: "Status"
  var msg = "HTTP/1.1 " & $status & " " & reason & "\r\n"
  msg.add("Content-Type: " & contentType & "\r\n")
  msg.add("Content-Length: " & $body.len & "\r\n")
  msg.add("Connection: close\r\n")
  if status == 401:
    msg.add("WWW-Authenticate: Bearer\r\n")
  msg.add("\r\n")
  msg.add(body)
  client.send(msg)

proc beginChunked*(client: Socket, status = 200,
                   contentType = "application/x-ndjson") =
  ## Start a chunked response (used for the exec NDJSON stream).
  var msg = "HTTP/1.1 " & $status & " OK\r\n"
  msg.add("Content-Type: " & contentType & "\r\n")
  msg.add("Transfer-Encoding: chunked\r\n")
  msg.add("Connection: close\r\n")
  msg.add("\r\n")
  client.send(msg)

proc chunkSizeHex*(n: int): string =
  ## The HTTP/1.1 chunk-size token for a body of ``n`` bytes: minimal
  ## lower-case hex with no leading zeros.
  ##
  ## `toHex` left-pads to a fixed width, so the leading zeros must be stripped —
  ## but `strip` defaults ``trailing = true``, and stripping the trailing zeros
  ## too corrupts every size that is a multiple of 16 (e.g. 0x40 -> "4", 0x70 ->
  ## "7"). The header then understates the body length, the reader desyncs, and
  ## the client reports "malformed chunked encoding" / a truncated NDJSON event.
  ## Strip ONLY the leading padding.
  if n <= 0:
    return "0"
  n.toHex.strip(leading = true, trailing = false, chars = {'0'}).toLowerAscii

proc writeChunk*(client: Socket, data: string) =
  ## Write one chunk. Empty ``data`` is ignored (a zero-length chunk would
  ## be misread as the terminator).
  if data.len == 0:
    return
  client.send(chunkSizeHex(data.len) & "\r\n")
  client.send(data)
  client.send("\r\n")

proc endChunked*(client: Socket) =
  client.send("0\r\n\r\n")

# ---------------------------------------------------------------------------
# Client side.

proc sendRequest*(sock: Socket, httpMethod, path, host: string,
                  headers: openArray[(string, string)] = [],
                  body = "") =
  ## Send a request with a ``Content-Length`` body.
  var msg = httpMethod & " " & path & " HTTP/1.1\r\n"
  msg.add("Host: " & host & "\r\n")
  for (k, v) in headers:
    msg.add(k & ": " & v & "\r\n")
  msg.add("Content-Length: " & $body.len & "\r\n")
  msg.add("Connection: close\r\n")
  msg.add("\r\n")
  msg.add(body)
  sock.send(msg)

proc readResponseHead*(sock: Socket): tuple[status: int,
                       headers: Table[string, string]] =
  ## Read the status line + headers, leaving the socket positioned at the
  ## start of the body (buffered or chunked).
  result.headers = initTable[string, string]()
  let (statusLine, closed) = recvLineRaw(sock)
  if closed and statusLine.len == 0:
    raise newException(HttpError, "connection closed before status line")
  let parts = statusLine.splitWhitespace()
  if parts.len < 2 or not parts[0].startsWith("HTTP/"):
    raise newException(HttpError, "malformed status line: " & statusLine)
  result.status = try: parseInt(parts[1])
                  except ValueError:
                    raise newException(HttpError,
                      "non-numeric status: " & statusLine)
  while true:
    let (h, _) = recvLineRaw(sock)
    if h.len == 0:
      break
    parseHeaderLine(h, result.headers)

proc readBodyByLength*(sock: Socket, headers: Table[string, string]): string =
  let clen = headers.getOrDefault("content-length", "")
  if clen.len == 0:
    return ""
  let n = try: parseInt(clen) except ValueError: 0
  if n > 0:
    result = recvExactly(sock, n)

proc httpRequest*(host: string, port: int, httpMethod, path: string,
                  headers: openArray[(string, string)] = [],
                  body = ""): HttpResponse =
  ## One-shot buffered request/response (``/v1/info``, ``/v1/shutdown``).
  var sock = newSocket()
  try:
    sock.connect(host, Port(port))
    sock.sendRequest(httpMethod, path, host & ":" & $port, headers, body)
    let head = sock.readResponseHead()
    result.status = head.status
    result.headers = head.headers
    result.body = sock.readBodyByLength(head.headers)
  finally:
    sock.close()

iterator readChunks*(sock: Socket): string =
  ## Yield the payload of each HTTP chunk until the terminating 0-chunk.
  ## Each yielded string is the raw chunk data (which, for the exec stream,
  ## is exactly one ``json\n`` NDJSON event).
  while true:
    let (sizeLine, closed) = recvLineRaw(sock)
    if closed and sizeLine.len == 0:
      break
    # A chunk-size line may carry ``;ext`` extensions — ignore them.
    let hexPart = sizeLine.split(';')[0].strip()
    if hexPart.len == 0:
      continue
    let size = try: parseHexInt(hexPart)
               except ValueError:
                 raise newException(HttpError, "bad chunk size: " & sizeLine)
    if size == 0:
      break
    let data = recvExactly(sock, size)
    discard recvLineRaw(sock)     # trailing CRLF after the chunk data
    yield data
