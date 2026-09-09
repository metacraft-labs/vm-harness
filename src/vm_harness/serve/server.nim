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

import std/[json, net, osproc, os, streams, strutils, tables, times]
import ./protocol, ./http, ./capability, ./enrollment
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
    # RA6 enrollment / signed capability manifest.
    enrollSecret*: string         ## per-host enrollment secret (prefer file)
    enrollSecretFile*: string     ## agenix / LoadCredential friendly
    stateDir*: string             ## where a self-bootstrapped secret persists
    identityTtlSec*: int          ## signed-identity lifetime; 0 ⇒ TTL default
    hostId*: string               ## identity ``host`` label; "" ⇒ hostname

  ServeContext = ref object
    cfg: ServeConfig
    running: bool
    enrollSecret: string          ## resolved once at startup (may be "")
    keyId: string                 ## derived from the secret; "" if none

proc daemonLog(ctx: ServeContext, msg: string) =
  if not ctx.cfg.quiet:
    stderr.writeLine("[vm-harness serve] " & msg)

proc hostnameOrUnknown(): string =
  ## Best-effort host name for the identity ``host`` label. Nim's stdlib has no
  ## portable ``getHostname``; try ``$HOSTNAME``, then ``/proc/sys/kernel/hostname``
  ## (Linux) / ``/etc/hostname``, else "unknown".
  let env = getEnv("HOSTNAME").strip()
  if env.len > 0: return env
  for p in ["/proc/sys/kernel/hostname", "/etc/hostname"]:
    try:
      if fileExists(p):
        let h = readFile(p).strip()
        if h.len > 0: return h
    except CatchableError: discard
  "unknown"

proc probeHypervisors(): seq[tuple[id: string, available: bool,
                                   guests: seq[string]]] =
  ## Probe every registered backend once: id, availability, supported guests.
  ## Shared by the ``/v1/info`` seed and the RA6 ``/v1/manifest`` (so both
  ## report the SAME hypervisor set this daemon can drive).
  for id in registeredBackends():
    var available = false
    var guests: seq[string] = @[]
    try:
      let b = newBackend(id)
      available = (try: b.probeAvailability() except CatchableError: false)
      for g in b.supportedGuests: guests.add($g)
    except CatchableError:
      discard
    result.add((id: $id, available: available, guests: guests))

proc infoJson(): JsonNode =
  ## Build the ``/v1/info`` capability report: the protocol version, the
  ## host platform, and every registered backend with a probed
  ## availability flag + its supported guests. This is the seed the RA6
  ## capability manifest grows from (the FULL, signed manifest is
  ## ``/v1/manifest``).
  let host = try: $detectHostPlatform() except CatchableError: "unknown"
  var backends = newJArray()
  for h in probeHypervisors():
    backends.add(%*{"id": h.id, "available": h.available, "guests": h.guests})
  result = %*{
    "service": ServiceName,
    "protocol": ProtocolVersion,
    "host": host,
    "backends": backends}

proc hostCapabilityManifest*(): JsonNode =
  ## THIS host's UNSIGNED capability manifest (the ``manifest`` payload the
  ## signed identity carries). Exposed for ``vm-harness manifest`` (local
  ## introspection + the RC1 label-derivation source) without needing a
  ## running daemon or an enrollment secret.
  toJson(detectHostCapabilities(probeHypervisors()))

proc manifestJson(ctx: ServeContext): JsonNode =
  ## Build the RA6 signed identity + capability manifest served by
  ## ``GET /v1/manifest``. The capability manifest is self-reported from the
  ## host (``capability.detectHostCapabilities``); the identity is signed with
  ## the host's enrollment secret (``enrollment.sign``) and is SHORT-LIVED
  ## (``identityTtlSec``) so a controller re-fetches after expiry.
  let caps = detectHostCapabilities(probeHypervisors())
  let host = if ctx.cfg.hostId.len > 0: ctx.cfg.hostId
             else: hostnameOrUnknown()
  let ttl = if ctx.cfg.identityTtlSec > 0: ctx.cfg.identityTtlSec
            else: DefaultIdentityTtlSec
  let id = buildIdentity(ctx.enrollSecret, host, toJson(caps),
                         getTime().toUnix(), ttl)
  toJson(sign(ctx.enrollSecret, id))

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
  of PathManifest:
    if req.httpMethod != "GET":
      client.sendResponse(405, $(%*{"error": "use GET"}))
    elif ctx.enrollSecret.len == 0:
      # No enrollment material ⇒ the daemon cannot present a signed identity.
      client.sendResponse(503, $(%*{"error":
        "serve daemon has no enrollment secret; " &
        "provide --enroll-secret-file / --enroll-secret / $VMH_ENROLL_SECRET"}))
    else:
      client.sendResponse(200, $manifestJson(ctx))
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
  # Resolve the enrollment secret ONCE at startup so the daemon's identity is
  # stable for its lifetime. Missing material is non-fatal: /v1/exec + /v1/info
  # still work (RA1 back-compat); only /v1/manifest requires it (503 otherwise).
  ctx.enrollSecret =
    try:
      resolveEnrollmentSecret(cfg.enrollSecret, cfg.enrollSecretFile, cfg.stateDir)
    except CatchableError as e:
      raise newException(ValueError, "vm-harness serve: " & e.msg)
  if ctx.enrollSecret.len > 0:
    ctx.keyId = keyIdFor(ctx.enrollSecret)
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
  if ctx.keyId.len > 0:
    # The keyId is the non-secret identity to ENROLL centrally (operator step).
    daemonLog(ctx, "identity keyId " & ctx.keyId &
              " (enroll this keyId on the controller)")
  else:
    daemonLog(ctx, "no enrollment secret — /v1/manifest disabled")
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
