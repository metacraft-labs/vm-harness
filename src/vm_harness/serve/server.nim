## vm-harness serve — the DAEMON.
##
## A small authenticated network front-end over the EXISTING vm-harness CLI
## backend code. It is intentionally NOT a reimplementation: every VM
## operation is executed by spawning the SAME ``vm-harness`` binary the CLI
## runs (its own ``getAppFilename`` by default) with the client-supplied
## argv, and streaming that worker's output back. This guarantees the remote
## ``provision``/``run``/``boot``/``snapshot``/``prune``/``ephemeral-destroy``
## paths are byte-for-byte the local ones — the daemon adds only the network
## endpoint, the auth check, and the output stream framing.
##
## Endpoints (all under ``/v1``, all requiring ``Authorization: Bearer``):
##   * ``GET  /v1/info``     — protocol version + advertised backend
##                             capabilities (the RA6 manifest seed).
##   * ``POST /v1/exec``     — run a forwarded CLI invocation, STREAM output
##                             as chunked NDJSON, terminate with an exit
##                             event.
##   * ``POST /v1/shutdown`` — graceful stop.
##
## Transport rationale + the TLS/NetBird posture are documented in
## ``protocol.nim`` and ``docs/serve.md``. Over a NetBird overlay the bearer
## token is carried inside WireGuard; an optional ``-d:ssl`` TLS wrap is a
## documented follow-up hook.

import std/[json, net, osproc, os, streams, strutils, tables]
import ./protocol, ./http
import ../types, ../auto

# Import the backend modules so ``registeredBackends`` / ``newBackend`` see
# them for the ``/v1/info`` capability report. Module-init registration is
# idempotent, so importing here (in addition to ``cli.nim``) is harmless.
{.push warning[UnusedImport]: off.}
import ../backends/noop
import ../backends/hyperv
import ../backends/wsl
import ../backends/tart
import ../backends/utm
import ../backends/qemu_windows_arm
import ../backends/lima
import ../backends/libvirt
import ../backends/incus
{.pop.}

type
  ServeConfig* = object
    listenHost*: string           ## bind address (e.g. "127.0.0.1", "::",
                                  ## or a NetBird overlay IP). NEVER a public
                                  ## interface in production.
    listenPort*: int              ## 0 ⇒ ephemeral port (reported via portFile)
    token*: string                ## required bearer token (non-empty)
    workerExe*: string            ## vm-harness binary to exec; "" ⇒ self
    workerArgPrefix*: seq[string] ## prepended to every forwarded argv
    workDir*: string              ## worker cwd; "" ⇒ inherit
    portFile*: string             ## if set, the bound port is written here
                                  ## (readiness signal for tests + ops)
    tlsCertFile*: string          ## optional (only honored under -d:ssl)
    tlsKeyFile*: string
    quiet*: bool                  ## suppress daemon stderr access logs

  ServeContext = ref object
    cfg: ServeConfig
    running: bool

proc daemonLog(ctx: ServeContext, msg: string) =
  if not ctx.cfg.quiet:
    stderr.writeLine("[vm-harness serve] " & msg)

proc infoJson(): JsonNode =
  ## Build the ``/v1/info`` capability report: the protocol version, the
  ## host platform, and every registered backend with a probed
  ## availability flag + its supported guests. This is the seed the RA6
  ## capability manifest grows from.
  let host = try: $detectHostPlatform() except CatchableError: "unknown"
  var backends = newJArray()
  for id in registeredBackends():
    var available = false
    var guests: seq[string] = @[]
    try:
      let b = newBackend(id)
      available = (try: b.probeAvailability() except CatchableError: false)
      for g in b.supportedGuests: guests.add($g)
    except CatchableError:
      discard
    backends.add(%*{"id": $id, "available": available, "guests": guests})
  result = %*{
    "service": ServiceName,
    "protocol": ProtocolVersion,
    "host": host,
    "backends": backends}

proc authorized(ctx: ServeContext, req: HttpRequest): bool =
  ## Constant-time bearer-token check. A missing header, wrong scheme, or
  ## wrong token all fail identically.
  let header = req.headers.getOrDefault(AuthHeader, "")
  let presented = parseBearer(header)
  # constantTimeEq still runs on an empty presented token, so a missing
  # Authorization header is rejected in (near) constant time too.
  constantTimeEq(ctx.cfg.token, presented)

proc handleExec(ctx: ServeContext, client: Socket, req: HttpRequest) =
  ## Parse the forwarded argv, spawn the worker (the same vm-harness
  ## binary), and stream its merged stdout/stderr as NDJSON ``log`` events
  ## followed by a terminal ``exit`` event.
  var parsed: ExecRequest
  try:
    parsed = parseExecRequest(req.body)
  except ValueError as e:
    client.sendResponse(400, $(%*{"error": e.msg}))
    return

  let exe = if ctx.cfg.workerExe.len > 0: ctx.cfg.workerExe
            else: getAppFilename()
  let args = ctx.cfg.workerArgPrefix & parsed.argv
  daemonLog(ctx, "exec " & exe & " " & args.join(" "))

  client.beginChunked()
  var p: Process
  try:
    p = startProcess(exe, workingDir = ctx.cfg.workDir, args = args,
                     options = {poStdErrToStdOut})
  except CatchableError as e:
    client.writeChunk(errorEvent("failed to start worker: " & e.msg) & "\n")
    client.writeChunk(exitEvent(127) & "\n")
    client.endChunked()
    return

  try:
    # Feed optional stdin, then close it so stdin-reading workers don't hang.
    if parsed.stdin.len > 0:
      p.inputStream.write(parsed.stdin)
    p.inputStream.close()
    let outStream = p.outputStream
    var line = ""
    while outStream.readLine(line):
      client.writeChunk(logEvent(line) & "\n")
    let code = p.waitForExit()
    client.writeChunk(exitEvent(code) & "\n")
  except CatchableError as e:
    client.writeChunk(errorEvent("worker stream error: " & e.msg) & "\n")
    client.writeChunk(exitEvent(1) & "\n")
  finally:
    try: p.close() except CatchableError: discard
    client.endChunked()

proc handleConnection(ctx: ServeContext, client: Socket) =
  var req: HttpRequest
  try:
    req = client.readRequest()
  except CatchableError:
    return                        # malformed / dropped — drop silently
  # Auth gate for every /v1 route. Reject BEFORE any dispatch or work.
  if not authorized(ctx, req):
    daemonLog(ctx, "401 " & req.httpMethod & " " & req.path)
    client.sendResponse(401, $(%*{"error": "unauthorized"}))
    return
  case req.path
  of PathInfo:
    if req.httpMethod != "GET":
      client.sendResponse(405, $(%*{"error": "use GET"}))
    else:
      client.sendResponse(200, $infoJson())
  of PathExec:
    if req.httpMethod != "POST":
      client.sendResponse(405, $(%*{"error": "use POST"}))
    else:
      handleExec(ctx, client, req)
  of PathShutdown:
    if req.httpMethod != "POST":
      client.sendResponse(405, $(%*{"error": "use POST"}))
    else:
      client.sendResponse(200, $(%*{"ok": true}))
      ctx.running = false
      daemonLog(ctx, "shutdown requested")
  else:
    client.sendResponse(404, $(%*{"error": "unknown path", "path": req.path}))

proc runServe*(cfg: ServeConfig) =
  ## Bind, listen, and serve connections until a ``/v1/shutdown`` is
  ## received. One connection is handled at a time (a control daemon drives
  ## long-running, host-mutating VM ops; serial handling avoids interleaved
  ## host mutations — coordinated placement is the central GARM's job, not
  ## this daemon's).
  if cfg.token.len == 0:
    raise newException(ValueError,
      "vm-harness serve: a non-empty auth token is required " &
      "(--auth-token / --auth-token-file / $VMH_SERVE_TOKEN)")
  let ctx = ServeContext(cfg: cfg, running: true)
  var server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  let host = if cfg.listenHost.len > 0: cfg.listenHost else: "127.0.0.1"
  server.bindAddr(Port(cfg.listenPort), host)
  server.listen()
  let (_, boundPort) = server.getLocalAddr()
  if cfg.portFile.len > 0:
    writeFile(cfg.portFile, $(boundPort.int))
  daemonLog(ctx, "listening on " & host & ":" & $(boundPort.int) &
            " (worker " &
            (if cfg.workerExe.len > 0: cfg.workerExe else: "self") & ")")
  when defined(ssl):
    if cfg.tlsCertFile.len > 0 and cfg.tlsKeyFile.len > 0:
      # Optional TLS wrap (compile with -d:ssl). Over NetBird the WireGuard
      # tunnel already encrypts; this is for deployments without an overlay.
      let sslCtx = newContext(certFile = cfg.tlsCertFile,
                              keyFile = cfg.tlsKeyFile)
      wrapSocket(sslCtx, server)
  while ctx.running:
    var client: Socket
    try:
      server.accept(client)
    except CatchableError:
      continue
    try:
      handleConnection(ctx, client)
    except CatchableError as e:
      daemonLog(ctx, "connection error: " & e.msg)
    finally:
      try: client.close() except CatchableError: discard
  server.close()
  daemonLog(ctx, "stopped")
