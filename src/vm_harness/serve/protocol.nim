## vm-harness serve — RPC PROTOCOL (v1).
##
## RA1 of the *Runner-Fleet-Capability-Pools-And-Remote-Driving* campaign.
## This module defines the STABLE, VERSIONED wire contract between a
## ``vm-harness serve`` daemon and a remote ``vm-harness`` client (or the
## ``garm-provider-vmharness`` RPC client, RB1). It is transport-agnostic in
## the sense that everything here is pure value logic (constants + JSON
## shapes + a constant-time token comparison) — the actual socket framing
## lives in ``http.nim``, the server in ``server.nim``, the client in
## ``client.nim``.
##
## Design decision (documented in ``docs/serve.md``): the transport is
## **HTTP/1.1 + JSON**, not gRPC. Rationale:
##
##   * vm-harness is a dependency-light Nim project (``vm_harness.nimble``
##     requires only ``nim``); gRPC would add protobuf tooling + a Nim gRPC
##     library to every build. HTTP/JSON needs only ``std/net`` + ``std/json``
##     which are already used across the CLI and backends.
##   * The Go ``garm-provider-vmharness`` (RB1) speaks HTTP/JSON trivially
##     with the stdlib.
##   * Study of Agent Harbor's ``ah-remote-exec`` confirmed the useful shape
##     is (a) an auth-method abstraction (key-file / password / agent), and
##     (b) capability *tags* on a remote host. We fold both in: bearer-token
##     auth (the AH "password"-shaped method, the sanctioned choice for a
##     private NetBird overlay) and a capability list on ``/v1/info`` (the
##     seed of the RA6 capability manifest). AH itself drives hosts over
##     **system SSH**; vm-harness deliberately ships its OWN daemon so a
##     single protocol front-ends every backend uniformly (the operator
##     directive that supersedes the design doc's "use AH's orchestrator").
##
## The surface is deliberately TINY and uniform so it is a *thin network
## front-end, not a reimplementation*:
##
##   * ``GET  /v1/info``     — protocol version + advertised backends
##                             (capability seed). Auth required.
##   * ``POST /v1/exec``     — run a vm-harness CLI invocation on the daemon
##                             host and STREAM its output. Body carries the
##                             forwarded argv; the daemon runs the SAME CLI
##                             binary (its own ``getAppFilename`` by default),
##                             so the executed backend code is byte-for-byte
##                             the local ``vm-harness`` code path. Response is
##                             a chunked NDJSON event stream. Auth required.
##   * ``POST /v1/shutdown`` — graceful stop. Auth required.
##
## Everything under ``/v1`` requires ``Authorization: Bearer <token>``; a
## missing or wrong token is rejected with ``401`` BEFORE any work is done.
## Over a NetBird (WireGuard) overlay the bearer token travels encrypted at
## the network layer; an optional TLS wrap is a compile-time (``-d:ssl``)
## follow-up hook (see ``docs/serve.md``).

import std/[json, strutils]

const
  ProtocolVersion* = "1"
    ## Bumped on any breaking change to the wire contract. Exposed both in
    ## the URL prefix (``/v1``) and the ``v`` field of every message so a
    ## client can detect a mismatch before interpreting a payload.

  ApiPrefix* = "/v" & ProtocolVersion
  PathInfo* = ApiPrefix & "/info"
  PathExec* = ApiPrefix & "/exec"
  PathShutdown* = ApiPrefix & "/shutdown"

  AuthHeader* = "authorization"       ## lower-cased for case-insensitive lookup
  AuthScheme* = "Bearer "
  ServiceName* = "vm-harness-serve"

type
  EventKind* = enum
    ## NDJSON event kinds streamed from ``POST /v1/exec``.
    ekLog = "log"       ## one merged stdout/stderr line from the worker
    ekExit = "exit"     ## terminal event carrying the worker exit code
    ekError = "error"   ## terminal event: the daemon failed to run the worker

  ExecRequest* = object
    ## Body of ``POST /v1/exec``. ``argv`` is a full vm-harness CLI
    ## invocation *without* the program name (e.g.
    ## ``@["run", "--backend", "noop", "--baseline", "rt", ...]``). The
    ## daemon prepends its configured worker executable + arg-prefix and
    ## runs it, so the executed code is the identical local CLI path.
    v*: string                 ## must equal ``ProtocolVersion``
    argv*: seq[string]
    stdin*: string             ## optional stdin fed to the worker
    timeoutSec*: int           ## 0 ⇒ no daemon-side timeout

proc constantTimeEq*(a, b: string): bool =
  ## Length-independent, data-independent comparison used for the bearer
  ## token so a network attacker cannot recover the secret from response
  ## timing. Always compares a fixed number of bytes derived from ``a``.
  ## Returns false immediately-in-value (not in-time) on a length mismatch
  ## while still touching every byte of ``a``.
  var diff = a.len xor b.len
  for i in 0 ..< a.len:
    # ``b[i mod b.len]`` keeps the loop bound tied to ``a`` only; the
    # length xor above already forces a mismatch when the lengths differ.
    let bc = if b.len > 0: b[i mod b.len] else: '\0'
    diff = diff or (int(a[i]) xor int(bc))
  diff == 0

proc parseBearer*(headerValue: string): string =
  ## Extract the token from an ``Authorization: Bearer <token>`` value.
  ## Returns "" when the scheme is absent or malformed.
  let v = headerValue.strip()
  if v.len >= AuthScheme.len and
     v[0 ..< AuthScheme.len].toLowerAscii == AuthScheme.toLowerAscii:
    v[AuthScheme.len .. ^1].strip()
  else:
    ""

# ---------------------------------------------------------------------------
# JSON (de)serialization. Kept explicit (no marshal magic) so the schema is
# auditable and stable — this is the contract the Go provider mirrors.

proc toJson*(req: ExecRequest): JsonNode =
  result = %*{
    "v": req.v,
    "argv": req.argv,
    "stdin": req.stdin,
    "timeoutSec": req.timeoutSec}

proc parseExecRequest*(body: string): ExecRequest =
  ## Parse + validate an ``/v1/exec`` body. Raises ``ValueError`` on a
  ## malformed payload or a protocol-version mismatch.
  let node =
    try: parseJson(body)
    except CatchableError as e:
      raise newException(ValueError, "exec: invalid JSON body: " & e.msg)
  if node.kind != JObject:
    raise newException(ValueError, "exec: body must be a JSON object")
  result.v = node{"v"}.getStr(ProtocolVersion)
  if result.v != ProtocolVersion:
    raise newException(ValueError,
      "exec: protocol version mismatch (client " & result.v &
      " != server " & ProtocolVersion & ")")
  if not node.hasKey("argv") or node["argv"].kind != JArray:
    raise newException(ValueError, "exec: 'argv' must be a JSON array")
  for a in node["argv"]:
    result.argv.add(a.getStr())
  result.stdin = node{"stdin"}.getStr("")
  result.timeoutSec = node{"timeoutSec"}.getInt(0)

proc logEvent*(line: string): string =
  ## Serialize a single ``log`` NDJSON event (without the trailing newline
  ## the framing layer appends).
  $(%*{"v": ProtocolVersion, "type": $ekLog, "line": line})

proc exitEvent*(code: int): string =
  $(%*{"v": ProtocolVersion, "type": $ekExit, "code": code})

proc errorEvent*(msg: string): string =
  $(%*{"v": ProtocolVersion, "type": $ekError, "message": msg})

type
  ExecEvent* = object
    ## Decoded NDJSON event on the client side.
    kind*: EventKind
    line*: string      ## for ekLog
    code*: int         ## for ekExit
    message*: string   ## for ekError

proc parseEvent*(jsonLine: string): ExecEvent =
  ## Decode one NDJSON event line streamed by the daemon. Unknown ``type``
  ## values raise ``ValueError`` so a forward-incompatible server surfaces
  ## loudly rather than silently dropping terminal events.
  let node = parseJson(jsonLine)
  let t = node{"type"}.getStr("")
  case t
  of $ekLog:
    ExecEvent(kind: ekLog, line: node{"line"}.getStr(""))
  of $ekExit:
    ExecEvent(kind: ekExit, code: node{"code"}.getInt(0))
  of $ekError:
    ExecEvent(kind: ekError, message: node{"message"}.getStr(""))
  else:
    raise newException(ValueError, "exec: unknown event type '" & t & "'")
