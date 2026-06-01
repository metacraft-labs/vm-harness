## vm-harness CLI dispatcher.
##
## Subcommands per design doc §6:
##
## - ``provision``: ensure a baseline image exists.
## - ``run``: revert, exec, harvest, cleanup — the one-shot gate runner.
## - ``probe``: print available backends (capability detection).
## - ``shell``: interactive shell against a baseline (debug aid).
## - ``backends``: tabular listing of every backend the library knows about.
##
## ``--backend auto`` resolves to the dispatch table in
## ``auto.autoSelectBackendId``. When a real backend isn't registered the
## CLI falls back to NoopBackend if ``--allow-noop-fallback`` is set
## (used by the M0 selection test on hosts without real hypervisors).

import std/[json, os, sequtils, strformat, strutils, tables, terminal]
import ./types, ./output, ./auto, ./orchestrator
# Import every backend module so its registerBackend bootstrap runs.
# Each import is a static side-effect: the backend's factory lands in
# auto.factoryRegistry at module-init time. The CLI itself only ever
# touches the registry through ``newBackend(id)`` / ``newBackendForGuest``,
# so the imports themselves look "unused" to the compiler — silence the
# warning with ``{.warning[UnusedImport]: off.}`` for this block.
{.push warning[UnusedImport]: off.}
import ./backends/noop
import ./backends/hyperv
import ./backends/wsl
import ./backends/tart
{.pop.}

type
  LogFormat* = enum
    lfHuman = "human"
    lfJson = "json"

  CliOpts* = object
    subcommand*: string
    backend*: string             ## raw flag value; "auto" for dispatch
    guest*: GuestOs
    guestSet*: bool
    baseline*: string
    sourceImage*: string
    cpus*: int
    memoryMB*: int
    diskGB*: int
    outputDir*: string
    envPairs*: Table[string, string]
    copyTo*: seq[tuple[host: string, guest: string]]
    copyFrom*: seq[tuple[guest: string, host: string]]
    shims*: seq[ArgvTraceShim]
    cmd*: seq[string]
    logFormat*: LogFormat
    allowNoopFallback*: bool
    timeoutSec*: int

const HelpText = """
vm-harness <subcommand> [flags]

Subcommands:
  provision    Ensure a baseline image exists (idempotent).
  run          One-shot revert + exec + harvest + cleanup.
  probe        Print available backends as JSON.
  shell        (placeholder) Open an interactive shell into a baseline.
  backends     Tabular listing of every known backend.

Common flags:
  --backend <auto|noop|hyperv|wsl|tart-macos|tart-linux-arm|
             utm-windows-arm|libvirt|lima>
  --guest <linux|windows|macos>   Required when --backend auto.
  --baseline <name>
  --source-image <ref>
  --cpus <int>
  --memory-mb <int>
  --disk-gb <int>
  --output-dir <path>
  --env KEY=VAL                   (repeatable)
  --copy-to host:guest            (repeatable)
  --copy-from guest:host          (repeatable)
  --install-shim binary:logpath   (repeatable)
  --timeout-sec <int>
  --log-format <human|json>
  --allow-noop-fallback           Use NoopBackend if the real one isn't installed.
  --                              End of flags; remainder is the gate command.
"""

proc parseEnvPair(s: string): tuple[k: string, v: string] =
  let idx = s.find('=')
  if idx < 0:
    raise newException(ValueError, &"--env expects KEY=VAL, got '{s}'")
  (k: s[0 ..< idx], v: s[idx + 1 .. ^1])

proc parsePathPair(flag: string, s: string): tuple[a: string, b: string] =
  let idx = s.find(':')
  if idx < 0:
    raise newException(ValueError, &"{flag} expects A:B, got '{s}'")
  (a: s[0 ..< idx], b: s[idx + 1 .. ^1])

proc parseGuest(s: string): GuestOs =
  for g in GuestOs:
    if $g == s.toLowerAscii: return g
  raise newException(ValueError, &"Unknown guest OS: '{s}'")

proc parseCliOpts*(args: seq[string]): CliOpts =
  ## Minimal hand-rolled parser. Keeps the binary dependency-free.
  result.logFormat = lfHuman
  result.cpus = 0
  result.memoryMB = 0
  result.diskGB = 0
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    result.subcommand = "help"
    return
  result.subcommand = args[0]
  var i = 1
  var afterDoubleDash = false
  while i < args.len:
    let a = args[i]
    if afterDoubleDash:
      result.cmd.add(a)
      inc i
      continue
    case a
    of "--":
      afterDoubleDash = true
      inc i
    of "--backend":
      inc i; result.backend = args[i]; inc i
    of "--guest":
      inc i; result.guest = parseGuest(args[i]); result.guestSet = true; inc i
    of "--baseline":
      inc i; result.baseline = args[i]; inc i
    of "--source-image":
      inc i; result.sourceImage = args[i]; inc i
    of "--cpus":
      inc i; result.cpus = parseInt(args[i]); inc i
    of "--memory-mb":
      inc i; result.memoryMB = parseInt(args[i]); inc i
    of "--disk-gb":
      inc i; result.diskGB = parseInt(args[i]); inc i
    of "--output-dir":
      inc i; result.outputDir = args[i]; inc i
    of "--timeout-sec":
      inc i; result.timeoutSec = parseInt(args[i]); inc i
    of "--env":
      inc i
      let p = parseEnvPair(args[i])
      result.envPairs[p.k] = p.v
      inc i
    of "--copy-to":
      inc i
      let p = parsePathPair("--copy-to", args[i])
      result.copyTo.add((host: p.a, guest: p.b))
      inc i
    of "--copy-from":
      inc i
      let p = parsePathPair("--copy-from", args[i])
      result.copyFrom.add((guest: p.a, host: p.b))
      inc i
    of "--install-shim":
      inc i
      let p = parsePathPair("--install-shim", args[i])
      result.shims.add(ArgvTraceShim(wrappedBinaryName: p.a,
                                    traceLogPath: p.b))
      inc i
    of "--log-format":
      inc i
      case args[i]
      of "human": result.logFormat = lfHuman
      of "json": result.logFormat = lfJson
      else: raise newException(ValueError,
                              &"--log-format expects human|json, got '{args[i]}'")
      inc i
    of "--allow-noop-fallback":
      result.allowNoopFallback = true
      inc i
    of "-h", "--help":
      result.subcommand = "help"
      inc i
    else:
      if a.startsWith("-"):
        raise newException(ValueError, &"Unknown flag: '{a}'")
      else:
        # First positional after subcommand is treated as part of cmd.
        result.cmd.add(a)
        inc i

proc logEvent*(format: LogFormat, level: string, msg: string,
              fields: openArray[(string, string)] = []) =
  case format
  of lfHuman:
    let useColor = isatty(stderr)
    let prefix = case level
                 of "error": (if useColor: "\e[31m" else: "") & "[ERR] " &
                              (if useColor: "\e[0m" else: "")
                 of "warn":  (if useColor: "\e[33m" else: "") & "[WRN] " &
                              (if useColor: "\e[0m" else: "")
                 else:        "[" & level & "] "
    stderr.writeLine(prefix & msg)
    for (k, v) in fields:
      stderr.writeLine("    " & k & ": " & v)
  of lfJson:
    var obj = %*{"level": level, "msg": msg}
    for (k, v) in fields:
      obj[k] = %v
    stderr.writeLine($obj)

proc resolveBackend(opts: CliOpts): tuple[id: BackendId, backend: VmBackend] =
  if opts.backend == "" or opts.backend == "auto":
    if not opts.guestSet:
      raise newException(ValueError,
        "--backend auto requires --guest <linux|windows|macos>")
    let id = autoSelectBackendId(detectHostPlatform(), opts.guest)
    let b = newBackend(id, noopFallback = opts.allowNoopFallback)
    (id: id, backend: b)
  else:
    let id = parseBackendId(opts.backend)
    let b = newBackend(id, noopFallback = opts.allowNoopFallback)
    (id: id, backend: b)

proc applyDefaults(spec: var BaselineSpec, opts: CliOpts) =
  spec.name = opts.baseline
  spec.sourceImage = opts.sourceImage
  spec.cpus = if opts.cpus > 0: opts.cpus else: 2
  spec.memoryMB = if opts.memoryMB > 0: opts.memoryMB else: 4096
  spec.diskGB = if opts.diskGB > 0: opts.diskGB else: 50
  if opts.guestSet:
    spec.guestOs = opts.guest

proc cmdProvision(opts: CliOpts): int =
  let (id, backend) = resolveBackend(opts)
  if opts.baseline.len == 0:
    raise newException(ValueError, "provision: --baseline is required")
  var spec: BaselineSpec
  applyDefaults(spec, opts)
  logEvent(opts.logFormat, "info",
           "provisioning baseline",
           {"backend": $id, "baseline": opts.baseline})
  backend.provisionBaseline(spec)
  logEvent(opts.logFormat, "info", "provision complete",
           {"backend": $id, "baseline": opts.baseline})
  0

proc cmdRun(opts: CliOpts): int =
  let (id, backend) = resolveBackend(opts)
  if opts.baseline.len == 0:
    raise newException(ValueError, "run: --baseline is required")
  if opts.outputDir.len == 0:
    raise newException(ValueError, "run: --output-dir is required")
  if opts.cmd.len == 0:
    raise newException(ValueError, "run: no command supplied after `--`")
  # Provision is idempotent — safe to call before every run.
  var spec: BaselineSpec
  applyDefaults(spec, opts)
  backend.provisionBaseline(spec)
  let envelope = newOutputEnvelope(opts.outputDir)
  envelope.logProvision(&"backend={id} baseline={opts.baseline}")
  let gate = GateSpec(
    name: extractFilename(opts.cmd[0]),
    baseline: opts.baseline,
    env: opts.envPairs,
    cmd: opts.cmd,
    copyTo: opts.copyTo,
    copyFrom: opts.copyFrom,
    shims: opts.shims,
    timeoutSec: opts.timeoutSec)
  let r = runGate(backend, gate, envelope)
  logEvent(opts.logFormat, "info", "gate complete",
           {"verdict": $r.verdict, "elapsed_ms": $r.elapsedMs})
  case r.verdict
  of vPass: 0
  of vFail: 1
  of vError: 2
  of vIncomplete: 130

proc cmdProbe(opts: CliOpts): int =
  let host = detectHostPlatform()
  var arr = newJArray()
  for id in registeredBackends():
    var backend: VmBackend
    try:
      backend = newBackend(id, noopFallback = opts.allowNoopFallback)
    except CatchableError:
      arr.add(%*{"id": $id, "available": false, "reason": "construction failed"})
      continue
    let avail =
      try: backend.probeAvailability()
      except CatchableError: false
    arr.add(%*{
      "id": $id,
      "available": avail,
      "host": $host,
      "supported_guests": toSeq(backend.supportedGuests).map(proc(g: GuestOs): string = $g)
    })
  echo($arr)
  0

proc cmdBackends(opts: CliOpts): int =
  echo("ID                  HOST          GUESTS")
  for id in BackendId:
    let registered = factoryRegistry[id] != nil
    let host = case id
               of biNoop: "any"
               of biHyperv, biWsl: "windows"
               of biTartMacos, biTartLinuxArm, biUtmWindowsArm: "macos-arm"
               of biLibvirt, biLima: "linux/macos"
    let guests = case id
                 of biNoop: "any"
                 of biHyperv: "linux,windows"
                 of biWsl: "linux"
                 of biTartMacos: "macos"
                 of biTartLinuxArm: "linux"
                 of biUtmWindowsArm: "windows"
                 of biLibvirt: "linux,windows"
                 of biLima: "linux"
    let marker = if registered: "*" else: " "
    echo($id & marker & " ".repeat(max(1, 20 - len($id) - 1)) & host &
         " ".repeat(max(1, 14 - host.len)) & guests)
  echo("\n* = registered on this host")
  0

proc cmdShell(opts: CliOpts): int =
  # M0 ships a placeholder; M1-M5 backends implement the real interactive
  # transport (SSH, PowerShell Direct). The placeholder documents the
  # invocation shape and exits 0 so the verification probe can compose it.
  logEvent(opts.logFormat, "warn",
           "shell subcommand is a placeholder in M0",
           {"backend": opts.backend, "baseline": opts.baseline})
  0

proc runCli*(args: seq[string]): int =
  var opts: CliOpts
  try:
    opts = parseCliOpts(args)
  except ValueError as e:
    stderr.writeLine("vm-harness: " & e.msg)
    stderr.writeLine(HelpText)
    return 2

  case opts.subcommand
  of "help":
    echo(HelpText)
    return 0
  of "provision": return cmdProvision(opts)
  of "run":       return cmdRun(opts)
  of "probe":     return cmdProbe(opts)
  of "backends":  return cmdBackends(opts)
  of "shell":     return cmdShell(opts)
  else:
    stderr.writeLine("vm-harness: unknown subcommand '" & opts.subcommand & "'")
    stderr.writeLine(HelpText)
    return 2

when isMainModule:
  quit(runCli(commandLineParams()))
