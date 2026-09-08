## vm-harness serve — the CLIENT library.
##
## The counterpart to ``server.nim``. Used by:
##   * the ``vm-harness --remote <addr>`` CLI flag (this milestone), which
##     forwards the local subcommand argv to a remote daemon and relays its
##     streamed output + exit code; and
##   * (later, RB1) the ``garm-provider-vmharness`` remote-target mode — a
##     thin RPC client driving CreateInstance/DeleteInstance against a
##     remote ``vm-harness serve``.
##
## Auth is a bearer token (``Authorization: Bearer <token>``). A ``401`` is
## surfaced as ``ServeAuthError`` so callers can distinguish "rejected
## credentials" from a transport failure.

import std/[json, net, strutils]
import ./protocol, ./http

type
  ServeClient* = object
    host*: string
    port*: int
    token*: string

  ServeAuthError* = object of CatchableError
    ## Raised when the daemon rejects the credential (HTTP 401).

  ServeError* = object of CatchableError
    ## Raised on a protocol/transport error talking to the daemon.

proc parseAddr*(address: string): tuple[host: string, port: int] =
  ## Parse ``host:port`` (IPv4 / hostname). Raises ``ValueError`` on a
  ## missing or non-numeric port.
  let idx = address.rfind(':')
  if idx <= 0 or idx == address.len - 1:
    raise newException(ValueError,
      "--remote expects host:port, got '" & address & "'")
  result.host = address[0 ..< idx]
  result.port = try: parseInt(address[idx + 1 .. ^1])
                except ValueError:
                  raise newException(ValueError,
                    "--remote: non-numeric port in '" & address & "'")

proc newServeClient*(address, token: string): ServeClient =
  let (h, p) = parseAddr(address)
  ServeClient(host: h, port: p, token: token)

proc authHeaders(c: ServeClient): seq[(string, string)] =
  @[("Authorization", AuthScheme & c.token)]

proc info*(c: ServeClient): JsonNode =
  ## ``GET /v1/info`` — the daemon's capability report. Raises
  ## ``ServeAuthError`` on 401.
  let resp = httpRequest(c.host, c.port, "GET", PathInfo, c.authHeaders())
  if resp.status == 401:
    raise newException(ServeAuthError, "daemon rejected credentials (401)")
  if resp.status != 200:
    raise newException(ServeError,
      "info: unexpected status " & $resp.status & ": " & resp.body)
  parseJson(resp.body)

proc shutdown*(c: ServeClient) =
  ## ``POST /v1/shutdown`` — ask the daemon to stop. Raises
  ## ``ServeAuthError`` on 401.
  let resp = httpRequest(c.host, c.port, "POST", PathShutdown,
                         c.authHeaders(), "{}")
  if resp.status == 401:
    raise newException(ServeAuthError, "daemon rejected credentials (401)")
  if resp.status != 200:
    raise newException(ServeError,
      "shutdown: unexpected status " & $resp.status & ": " & resp.body)

proc execStream*(c: ServeClient, argv: seq[string],
                 onEvent: proc(ev: ExecEvent) {.closure.},
                 stdin = "", timeoutSec = 0): int =
  ## ``POST /v1/exec`` — run ``argv`` as a vm-harness CLI invocation on the
  ## daemon host and STREAM its output. ``onEvent`` is called for each
  ## decoded event as it arrives (``ekLog`` lines in real time). Returns the
  ## worker's exit code (from the terminal ``ekExit`` event). Raises
  ## ``ServeAuthError`` on 401 and ``ServeError`` if the stream ends without
  ## an exit event.
  let body = $toJson(ExecRequest(v: ProtocolVersion, argv: argv,
                                 stdin: stdin, timeoutSec: timeoutSec))
  var sock = newSocket()
  var exitCode = -1
  var sawExit = false
  var errMsg = ""
  try:
    sock.connect(c.host, Port(c.port))
    sock.sendRequest("POST", PathExec, c.host & ":" & $c.port,
                     c.authHeaders() & @[("Content-Type", "application/json")],
                     body)
    let head = sock.readResponseHead()
    if head.status == 401:
      raise newException(ServeAuthError, "daemon rejected credentials (401)")
    if head.status != 200:
      let errBody = sock.readBodyByLength(head.headers)
      raise newException(ServeError,
        "exec: unexpected status " & $head.status & ": " & errBody)
    for chunk in sock.readChunks():
      for lineRaw in chunk.splitLines():
        let line = lineRaw.strip()
        if line.len == 0: continue
        let ev = parseEvent(line)
        onEvent(ev)
        case ev.kind
        of ekExit:
          exitCode = ev.code
          sawExit = true
        of ekError:
          errMsg = ev.message
        else: discard
  finally:
    sock.close()
  if not sawExit:
    raise newException(ServeError,
      "exec: stream ended without an exit event" &
      (if errMsg.len > 0: " (" & errMsg & ")" else: ""))
  exitCode

proc execRelay*(c: ServeClient, argv: seq[string],
                sink: proc(line: string) {.closure.},
                stdin = "", timeoutSec = 0): int =
  ## Convenience wrapper over ``execStream`` that relays every ``log`` line
  ## to ``sink`` (typically prints to the client's stderr) and returns the
  ## exit code. This is what ``vm-harness --remote`` uses so a remote run
  ## looks like a local one.
  c.execStream(argv, proc(ev: ExecEvent) =
    case ev.kind
    of ekLog: sink(ev.line)
    of ekError: sink("[remote error] " & ev.message)
    else: discard
  , stdin, timeoutSec)
