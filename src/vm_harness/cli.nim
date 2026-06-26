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
import ./backends/utm
import ./backends/lima
import ./backends/libvirt
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
    running*: bool               ## `--running` flag for `snapshot create`.
    # M4 libvirt-slice canonical-command flags. See
    # docs/m4-libvirt.md → "Operator command examples" for the
    # invocation these wire up.
    recipe*: string              ## ``--recipe <id>`` — selects a recipe
                                 ## directory under ``guest-recipes/<id>/``.
                                 ## Resolved to ``recipeDir`` in CliOpts and
                                 ## threaded into ``BaselineSpec.recipeDir``.
    recipeDir*: string           ## resolved absolute path to the recipe dir
                                 ## (parseCliOpts performs the lookup so the
                                 ## error surfaces at parse time).
    recipeBuildDir*: string      ## ``--recipe-build-dir <path>`` — writable
                                 ## location for the recipe's ``build/`` outputs
                                 ## (autounattend.iso, virtio-win.iso symlink,
                                 ## Win11_*.iso symlink). When unset the backend
                                 ## falls back to ``<recipeDir>/build`` which is
                                 ## read-only when the recipe is shipped under
                                 ## /nix/store.
    name*: string                ## ``--name <vm>`` — alias for ``--baseline``
                                 ## per the canonical libvirt M4 command.
                                 ## When both are passed the values must match.
    networkBridge*: string       ## ``--network-bridge <name>`` — libvirt-only
                                 ## override for the guest's primary NIC.
    firstBootScript*: string     ## ``--first-boot-script <path>`` — file the
                                 ## recipe's build-autounattend-iso.sh wraps
                                 ## into the per-VM autounattend ISO.
    controllerPubKey*: string    ## ``--controller-pubkey <path>`` — SSH public
                                 ## key (``id_ed25519.pub`` or similar) that
                                 ## the recipe's build-autounattend-iso.sh
                                 ## wraps into the per-VM autounattend ISO so
                                 ## the guest's FirstLogonCommands can install
                                 ## it in ``authorized_keys`` before the
                                 ## controller first reaches out over SSH.

const HelpText = """
vm-harness <subcommand> [flags]

Subcommands:
  provision               Ensure a baseline image exists (idempotent).
  run                     One-shot revert + exec + harvest + cleanup.
  probe                   Print available backends as JSON.
  shell                   (placeholder) Open an interactive shell into a baseline.
  backends                Tabular listing of every known backend.
  snapshot create [--running] <vm> <name>
                          Take a named snapshot of <vm>. With --running, the
                          snapshot includes memory + CPU + device state and
                          restore is a memory load rather than a fresh boot
                          (Hyper-V: Standard Checkpoint; Tart: tart suspend
                          — planned).
  snapshot restore <vm> <name>
                          Restore <vm> from snapshot <name>.
  snapshot list <vm>      List snapshots for <vm>.
  baseline export <vm> <dest-dir> [--baseline <name>]
                          Export a baseline VM (and its snapshot tree) to
                          <dest-dir> as a self-contained, transferable
                          artifact. --baseline asserts the named snapshot
                          exists before exporting.
  baseline import <src-dir>
                          Import a previously-exported baseline bundle.
                          Prints the snapshot names now available.

Common flags:
  --backend <auto|noop|hyperv|wsl|tart-macos|tart-linux-arm|
             utm-windows-arm|libvirt|lima>
  --guest <linux|windows|macos>   Required when --backend auto.
  --baseline <name>               Logical baseline tag (== libvirt domain name).
  --name <vm>                     Alias for --baseline (canonical libvirt M4
                                  command shape; see docs/m4-libvirt.md).
  --recipe <id>                   Selects guest-recipes/<id>/ as the source of
                                  per-baseline artifacts (autounattend.xml,
                                  build-autounattend-iso.sh, ...). Required by
                                  backends that consume recipe-shaped inputs.
  --source-image <ref>
  --cpus <int>                    Backend default applies when omitted.
  --vcpu <int>                    Alias for --cpus (canonical libvirt M4 shape).
  --memory-mb <int>
  --memory-gb <int>               Alias for --memory-mb, expressed in GiB.
  --disk-gb <int>
  --network-bridge <name>         libvirt-only: host bridge for the guest NIC
                                  (default: backend's configured value, e.g.
                                  virbr0). Ignored by other backends.
  --first-boot-script <path>      libvirt-only: host path to a script the
                                  recipe wraps into the per-VM autounattend
                                  ISO. Requires --recipe.
  --controller-pubkey <path>      libvirt-only: SSH public key the recipe
                                  bakes into the autounattend ISO so the
                                  guest's FirstLogonCommands installs it in
                                  authorized_keys before first boot.
                                  Requires --recipe.
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

proc resolveRecipeDir*(recipeId: string): string =
  ## Resolve ``--recipe <id>`` to an absolute directory under
  ## ``guest-recipes/<id>/``. The search order is:
  ##
  ##   1. ``$VMH_RECIPES_DIR/<id>``        (operator escape hatch)
  ##   2. ``<cwd>/guest-recipes/<id>``     (running from a repo checkout)
  ##   3. ``<exe-dir>/../guest-recipes/<id>``
  ##   4. ``<exe-dir>/../../guest-recipes/<id>``
  ##                                       (installed binary under build/bin/)
  ##   5. ``<exe-dir>/../share/vm-harness/guest-recipes/<id>``
  ##                                       (Nix-packaged binary; matches
  ##                                       the flake's installPhase).
  ##
  ## Raises ``ValueError`` when the directory doesn't exist anywhere — the
  ## parse-time error surfaces the typo immediately instead of failing
  ## later inside a backend method.
  if recipeId.len == 0:
    raise newException(ValueError, "--recipe requires a non-empty id")
  # No path separators allowed — the id picks one directory by name, not
  # a relative path that could escape guest-recipes/.
  if '/' in recipeId or '\\' in recipeId or recipeId.startsWith("."):
    raise newException(ValueError,
      &"--recipe expects a bare id (e.g. 'windows-x64-base'), got '{recipeId}'")
  var candidates: seq[string] = @[]
  let envOverride = getEnv("VMH_RECIPES_DIR")
  if envOverride.len > 0:
    candidates.add(envOverride / recipeId)
  candidates.add(getCurrentDir() / "guest-recipes" / recipeId)
  let exeDir = getAppDir()
  candidates.add(exeDir / ".." / "guest-recipes" / recipeId)
  candidates.add(exeDir / ".." / ".." / "guest-recipes" / recipeId)
  candidates.add(
    exeDir / ".." / "share" / "vm-harness" / "guest-recipes" / recipeId)
  for c in candidates:
    if dirExists(c):
      return absolutePath(c)
  raise newException(ValueError,
    &"--recipe '{recipeId}': directory not found. Searched: " &
    candidates.join(", "))

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
    of "--name":
      # Canonical libvirt-M4 alias for --baseline. The dispatch code
      # resolves precedence in ``parseCliOpts``'s post-loop block so
      # both can be passed (they must agree) and `applyDefaults`
      # always sees a single source of truth.
      inc i; result.name = args[i]; inc i
    of "--recipe":
      inc i
      result.recipe = args[i]
      result.recipeDir = resolveRecipeDir(args[i])
      inc i
    of "--recipe-build-dir":
      inc i; result.recipeBuildDir = args[i]; inc i
    of "--source-image":
      inc i; result.sourceImage = args[i]; inc i
    of "--cpus", "--vcpu":
      # ``--vcpu`` is the canonical libvirt M4 spelling; ``--cpus`` is
      # the historical vm-harness spelling. Both produce the same
      # internal field. We deliberately accept either without a
      # deprecation warning because both spellings show up in active
      # docs (design.md uses --cpus; m4-libvirt.md uses --vcpu).
      inc i; result.cpus = parseInt(args[i]); inc i
    of "--memory-mb":
      inc i; result.memoryMB = parseInt(args[i]); inc i
    of "--memory-gb":
      # Convenience: libvirt operators think in GiB, vm-harness's
      # historical surface in MiB. Convert once at parse time.
      inc i; result.memoryMB = parseInt(args[i]) * 1024; inc i
    of "--disk-gb":
      inc i; result.diskGB = parseInt(args[i]); inc i
    of "--network-bridge":
      inc i; result.networkBridge = args[i]; inc i
    of "--first-boot-script":
      inc i; result.firstBootScript = args[i]; inc i
    of "--controller-pubkey":
      inc i; result.controllerPubKey = args[i]; inc i
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
    of "--running":
      result.running = true
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

  # Post-loop reconciliation for the libvirt M4 ``--name`` alias.
  # The canonical command uses ``--name <vm>`` rather than ``--baseline
  # <name>``; downstream code only sees ``baseline``. Resolve precedence
  # here so the rest of the CLI doesn't have to know about the alias.
  if result.name.len > 0:
    if result.baseline.len == 0:
      result.baseline = result.name
    elif result.baseline != result.name:
      raise newException(ValueError,
        &"--name '{result.name}' and --baseline '{result.baseline}' " &
        "must match (they refer to the same logical VM)")
  # --first-boot-script requires --recipe to know which script the
  # recipe's build-autounattend-iso.sh wants. Fail fast at parse time.
  if result.firstBootScript.len > 0 and result.recipeDir.len == 0:
    raise newException(ValueError,
      "--first-boot-script requires --recipe <id>; the script is wrapped " &
      "into the per-VM autounattend ISO by the recipe's " &
      "build-autounattend-iso.sh helper")
  if result.firstBootScript.len > 0 and not fileExists(result.firstBootScript):
    raise newException(ValueError,
      &"--first-boot-script '{result.firstBootScript}': file not found")
  # --controller-pubkey is wrapped into the autounattend ISO the same way as
  # --first-boot-script, so we apply the same gating: it requires --recipe
  # (only recipes that ship build-autounattend-iso.sh can pick it up) and
  # the file must exist on the host.
  if result.controllerPubKey.len > 0 and result.recipeDir.len == 0:
    raise newException(ValueError,
      "--controller-pubkey requires --recipe <id>; the pubkey is wrapped " &
      "into the per-VM autounattend ISO by the recipe's " &
      "build-autounattend-iso.sh helper")
  if result.controllerPubKey.len > 0 and not fileExists(result.controllerPubKey):
    raise newException(ValueError,
      &"--controller-pubkey '{result.controllerPubKey}': file not found")

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
  # M4 libvirt-slice canonical-command extensions. Backends that don't
  # consume these fields ignore them (the contract is intentionally
  # tolerant — see types.nim's BaselineSpec docstrings).
  spec.recipeDir = opts.recipeDir
  spec.recipeBuildDir = opts.recipeBuildDir
  spec.firstBootScript = opts.firstBootScript
  spec.controllerPubKey = opts.controllerPubKey
  spec.networkBridge = opts.networkBridge
  spec.backendOptions = initTable[string, string]()

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

proc cmdSnapshot(opts: CliOpts): int =
  ## M30: dispatch ``snapshot create|restore|list <vm> [<name>]`` to the
  ## resolved backend. Positional args land in ``opts.cmd``.
  if opts.cmd.len < 2:
    stderr.writeLine("vm-harness: snapshot requires <action> <vm> [<name>]")
    stderr.writeLine("  actions: create, restore, list")
    return 2
  let action = opts.cmd[0]
  let vmName = opts.cmd[1]
  let (id, backend) = resolveBackend(opts)
  case action
  of "create":
    if opts.cmd.len < 3:
      stderr.writeLine("vm-harness: snapshot create requires <name>")
      return 2
    let snap = opts.cmd[2]
    let mode = if opts.running: "running" else: "stopped"
    logEvent(opts.logFormat, "info",
             "snapshot create",
             {"backend": $id, "vm": vmName, "name": snap, "mode": mode})
    let returnedId =
      if opts.running: backend.snapshotRunning(vmName, snap)
      else: backend.snapshot(vmName, snap)
    case opts.logFormat
    of lfHuman: echo returnedId
    of lfJson:  echo($(%*{"id": returnedId, "mode": mode}))
    0
  of "restore":
    if opts.cmd.len < 3:
      stderr.writeLine("vm-harness: snapshot restore requires <name>")
      return 2
    let snap = opts.cmd[2]
    logEvent(opts.logFormat, "info",
             "snapshot restore",
             {"backend": $id, "vm": vmName, "name": snap})
    backend.restoreSnapshot(vmName, snap)
    logEvent(opts.logFormat, "info", "snapshot restore complete",
             {"backend": $id, "vm": vmName, "name": snap})
    0
  of "list":
    let snaps = backend.listSnapshots(vmName)
    case opts.logFormat
    of lfHuman:
      for s in snaps: echo s
    of lfJson:
      var arr = newJArray()
      for s in snaps: arr.add(%s)
      echo($arr)
    0
  else:
    stderr.writeLine("vm-harness: unknown snapshot action '" & action & "'")
    stderr.writeLine("  actions: create, restore, list")
    2

proc cmdBaseline(opts: CliOpts): int =
  ## Dispatch `baseline export <vm> <dest-dir> [--baseline <name>]`
  ## or `baseline import <src-dir>` to the resolved backend.
  if opts.cmd.len < 2:
    stderr.writeLine("vm-harness: baseline requires <action> <vm-or-srcdir> [...]")
    stderr.writeLine("  actions: export, import")
    return 2
  let action = opts.cmd[0]
  let (id, backend) = resolveBackend(opts)
  case action
  of "export":
    if opts.cmd.len < 3:
      stderr.writeLine("vm-harness: baseline export requires <vm> <dest-dir>")
      return 2
    let vmName = opts.cmd[1]
    let destDir = opts.cmd[2]
    logEvent(opts.logFormat, "info",
             "baseline export",
             {"backend": $id, "vm": vmName, "dest": destDir,
              "baseline": opts.baseline})
    backend.exportBaseline(vmName, destDir, opts.baseline)
    case opts.logFormat
    of lfHuman: echo destDir
    of lfJson:  echo($(%*{"dest": destDir}))
    0
  of "import":
    let srcDir = opts.cmd[1]
    logEvent(opts.logFormat, "info",
             "baseline import",
             {"backend": $id, "src": srcDir})
    let imported = backend.importBaseline(srcDir)
    case opts.logFormat
    of lfHuman:
      for s in imported: echo s
    of lfJson:
      var arr = newJArray()
      for s in imported: arr.add(%s)
      echo($arr)
    0
  else:
    stderr.writeLine("vm-harness: unknown baseline action '" & action & "'")
    stderr.writeLine("  actions: export, import")
    2

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
  of "snapshot":  return cmdSnapshot(opts)
  of "baseline":  return cmdBaseline(opts)
  else:
    stderr.writeLine("vm-harness: unknown subcommand '" & opts.subcommand & "'")
    stderr.writeLine(HelpText)
    return 2

when isMainModule:
  quit(runCli(commandLineParams()))
