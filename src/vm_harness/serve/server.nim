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

import std/[json, net, osproc, os, streams, strutils, tables, times,
            locks, atomics, tempfiles]
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
    serveThreads*: int            ## accept-loop worker threads; 0 ⇒ auto
                                  ## (``max(4, countProcessors())`` capped at
                                  ## ``MaxServeThreads``). See ``runServe``.

  ServeContext = ref object
    ## Shared across every accept-loop thread by reference. ``cfg``,
    ## ``enrollSecret`` and ``keyId`` are written ONCE at startup and read-only
    ## thereafter, so they are safe to share unsynchronized. ``running`` and
    ## ``activeThreads`` are the only mutable-after-startup fields and are
    ## therefore ``Atomic`` (see ``runServe`` for the shutdown protocol).
    cfg: ServeConfig
    running: Atomic[bool]         ## cleared by /v1/shutdown; polled by workers
    activeThreads: Atomic[int]    ## workers still inside their accept loop
    enrollSecret: string          ## resolved once at startup (may = "")
    keyId: string                 ## derived from the secret; "" if none

const MaxServeThreads = 32
  ## Ceiling on the auto-sized accept-loop pool. Each worker only parks in
  ## ``accept`` or forwards to an isolated child process, so the pool exists to
  ## overlap request *latency* (a long-running exec must not stall unrelated
  ## connections), not to saturate CPU — a modest ceiling is plenty.

var serveLogLock: Lock
  ## Serializes ``daemonLog`` stderr writes so whole access-log lines from
  ## concurrent accept-loop threads do not interleave. Initialized in
  ## ``runServe`` before any worker is spawned.

proc daemonLog(ctx: ServeContext, msg: string) {.gcsafe.} =
  ## Emit one access-log line to stderr. Callable from every accept-loop
  ## thread. ``{.gcsafe.}`` is asserted because the body touches only the
  ## passed-in ``ctx``, the process-global (thread-safe) ``stderr`` handle, and
  ## a plain, non-GC ``Lock`` — no GC-managed globals.
  if ctx.cfg.quiet:
    return
  {.cast(gcsafe).}:
    withLock serveLogLock:
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

proc userDataTempDir(): string =
  ## Daemon-owned directory holding per-request user-data seed files. Created
  ## lazily; individual files are unique (``createTempFile``) and removed as
  ## soon as their worker exits, so this only ever holds in-flight seeds.
  getTempDir() / "vm-harness-serve" / "userdata"

proc applyUserData*(argv: seq[string], userData: string,
                    dir: string): tuple[argv: seq[string], path: string] =
  ## Bridge the wire ``userData`` bytes to the local ``--user-data <path>`` CLI
  ## contract without a new backend-specific code path:
  ##
  ##   * When ``userData`` is empty, or ``argv`` ALREADY carries a
  ##     ``--user-data`` flag (the caller pinned its own file), the argv is
  ##     returned unchanged and ``path`` is "" (nothing to clean up).
  ##   * Otherwise the bytes are written to a fresh ``0600`` file under ``dir``
  ##     and ``--user-data <path>`` is appended. The returned ``path`` MUST be
  ##     deleted by the caller once the worker has exited.
  ##
  ## The contents are treated as a secret (they may carry a runner registration
  ## token): the file is owner-only and the bytes are never logged. Only the
  ## resulting PATH ever appears in the argv (and therefore in the access log).
  if userData.len == 0 or "--user-data" in argv:
    return (argv, "")
  createDir(dir)
  let (f, path) = createTempFile("seed-", ".userdata", dir)
  try:
    try:
      f.write(userData)
    finally:
      f.close()
  except CatchableError:
    # A write/close failure must not leave a partial, token-bearing seed file
    # behind: the path is never returned to the caller, so it could not be
    # cleaned up otherwise. Delete it before re-raising.
    try: removeFile(path) except CatchableError: discard
    raise
  when defined(posix):
    # createTempFile already uses an owner-only mode on POSIX; assert it
    # explicitly so the contract holds regardless of the umask/stdlib version.
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  (argv & @["--user-data", path], path)

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
  # Materialize optional cloud-init user-data (e.g. GARM's rendered runner
  # bootstrap) to a per-request 0600 temp file and append ``--user-data
  # <path>`` so the worker reuses the local ``run --ephemeral --user-data``
  # path unchanged. ``userDataPath`` is "" when nothing was materialized.
  var args = ctx.cfg.workerArgPrefix & parsed.argv
  var userDataPath = ""
  try:
    let applied = applyUserData(args, parsed.userData, userDataTempDir())
    args = applied.argv
    userDataPath = applied.path
  except CatchableError as e:
    client.beginChunked()
    client.writeChunk(errorEvent("failed to stage user-data: " & e.msg) & "\n")
    client.writeChunk(exitEvent(127) & "\n")
    client.endChunked()
    return
  # NB: ``args`` may now end in ``--user-data <path>`` — the PATH is safe to
  # log; the user-data CONTENTS are never logged.
  daemonLog(ctx, "exec " & exe & " " & args.join(" "))

  client.beginChunked()
  var p: Process
  try:
    p = startProcess(exe, workingDir = ctx.cfg.workDir, args = args,
                     options = {poStdErrToStdOut})
  except CatchableError as e:
    if userDataPath.len > 0:
      try: removeFile(userDataPath) except CatchableError: discard
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
    # Delete the user-data seed as soon as the worker exits: the backend has
    # already read it (incus copies it into ``cloud-init.user-data``), so the
    # token-bearing file must not linger on disk.
    if userDataPath.len > 0:
      try: removeFile(userDataPath) except CatchableError: discard
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
      ctx.running.store(false)
      daemonLog(ctx, "shutdown requested")
  else:
    client.sendResponse(404, $(%*{"error": "unknown path", "path": req.path}))

type
  Acceptor = object
    ## Immutable bundle handed (by ``ptr``) to every accept-loop thread. A
    ## SINGLE instance is shared by all workers: ``ctx`` is a ref whose mutable
    ## fields are atomic, and ``server`` is the ONE listening socket every
    ## worker calls ``accept`` on concurrently (see ``acceptLoop``).
    ctx: ServeContext
    server: Socket

proc resolveThreadCount(cfg: ServeConfig): int =
  ## The accept-loop pool size. An explicit ``--serve-threads`` wins (clamped
  ## to ``MaxServeThreads``); otherwise auto-size to ``max(4, countProcessors())``
  ## capped at ``MaxServeThreads``. Four is a floor so even a single-core host
  ## can overlap a slow exec with unrelated short requests.
  if cfg.serveThreads > 0:
    return min(cfg.serveThreads, MaxServeThreads)
  result = max(4, countProcessors())
  if result > MaxServeThreads:
    result = MaxServeThreads

proc acceptLoop(arg: ptr Acceptor) {.thread.} =
  ## One worker's accept loop, run by every thread in the pool against the
  ## SAME listening socket. Concurrency safety:
  ##
  ## * ``accept(2)`` on one listening fd is safe to call from multiple threads
  ##   — the kernel hands each a distinct connected socket. Nim's ``Socket``
  ##   read/write buffering only ever touches the per-connection ``client``
  ##   socket (owned by this thread), never the shared listening socket, so
  ##   sharing the ``server`` object is sound.
  ## * ``handleConnection``/``handleExec`` use only local variables, the
  ##   thread-owned ``client`` socket, an isolated child PROCESS, and read-only
  ##   ``ctx`` fields — no shared mutable state between connections.
  ## * ``ctx.running`` (atomic) is polled so a ``/v1/shutdown`` on any thread
  ##   drains all of them.
  ##
  ## The ``{.cast(gcsafe).}`` covers the read-only-after-startup backend
  ## registry (``/v1/info`` / ``/v1/manifest``) whose closure table Nim
  ## conservatively flags; the reasoning above is the justification.
  let ctx = arg.ctx
  let server = arg.server
  {.cast(gcsafe).}:
    while ctx.running.load():
      var client: Socket
      var accepted = false
      try:
        server.accept(client)
        accepted = true
      except CatchableError:
        discard
      if not accepted:
        continue
      # A shutdown may have landed while we were parked in accept (including a
      # self-connect wakeup, below). Drop the connection without dispatch.
      if not ctx.running.load():
        try: client.close() except CatchableError: discard
        break
      try:
        handleConnection(ctx, client)
      except CatchableError as e:
        daemonLog(ctx, "connection error: " & e.msg)
      finally:
        try: client.close() except CatchableError: discard
    discard ctx.activeThreads.fetchSub(1)

proc selfConnectHost(listenHost: string): string =
  ## The address to connect to in order to wake a parked ``accept`` on THIS
  ## daemon's listening socket. Wildcard binds are reached via loopback.
  case listenHost
  of "", "0.0.0.0": "127.0.0.1"
  of "::", "[::]": "::1"
  else: listenHost

proc wakeOnce(host: string, port: int) =
  ## Open and immediately close one connection to unblock a worker parked in
  ## ``accept``. Best-effort: any failure is ignored (the worker may already
  ## have left its loop).
  try:
    let s = dial(host, Port(port))
    s.close()
  except CatchableError:
    discard

proc runServe*(cfg: ServeConfig) =
  ## Bind, listen, and serve connections until a ``/v1/shutdown`` is received.
  ##
  ## Connections are handled CONCURRENTLY by a small pool of accept-loop
  ## threads (``resolveThreadCount``), each looping ``accept`` → ``handle`` →
  ## ``close`` on the shared listening socket. This is required by the control
  ## driver (a central GARM) which fires many concurrent create/delete/retry
  ## calls: a single long-running ``/v1/exec`` must not stall unrelated
  ## connections past the client's response-header timeout. Per-host mutation
  ## ordering is the driver's concern, not this daemon's — each request already
  ## runs in an isolated child process.
  ##
  ## Shutdown protocol: the ``/v1/shutdown`` handler clears the atomic
  ## ``running`` flag. The main thread polls it, then wakes any workers still
  ## parked in ``accept`` by self-connecting once per still-active worker until
  ## the pool drains, and finally joins. Shutdown is prompt but not
  ## instantaneous — a worker mid-exec finishes that exec first.
  if cfg.token.len == 0:
    raise newException(ValueError,
      "vm-harness serve: a non-empty auth token is required " &
      "(--auth-token / --auth-token-file / $VMH_SERVE_TOKEN)")
  let ctx = ServeContext(cfg: cfg)
  ctx.running.store(true)
  initLock(serveLogLock)
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

  # Spawn the accept-loop pool. All workers share the one ``Acceptor`` (and
  # thus the one listening socket + ctx); ``acc`` outlives them because we join
  # before returning.
  let threadCount = resolveThreadCount(cfg)
  daemonLog(ctx, "accept-loop pool: " & $threadCount & " threads")
  ctx.activeThreads.store(threadCount)
  var acc = Acceptor(ctx: ctx, server: server)
  var threads = newSeq[Thread[ptr Acceptor]](threadCount)
  for i in 0 ..< threadCount:
    createThread(threads[i], acceptLoop, addr acc)

  # Wait for a /v1/shutdown (which clears ``running`` on some worker thread).
  while ctx.running.load():
    sleep(100)

  # Unblock workers still parked in ``accept``: self-connect once per active
  # worker, repeatedly, until the pool drains. A worker mid-exec finishes it
  # first, then observes ``running == false`` and leaves without accepting.
  let wakeHost = selfConnectHost(host)
  while ctx.activeThreads.load() > 0:
    wakeOnce(wakeHost, boundPort.int)
    sleep(20)

  for t in threads.mitems:
    joinThread(t)
  server.close()
  daemonLog(ctx, "stopped")
