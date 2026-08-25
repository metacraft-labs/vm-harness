## vm-harness CLI dispatcher.
##
## Subcommands per design doc §6:
##
## - ``provision``: ensure a baseline image exists.
## - ``boot``: boot a transient VM directly from ISO, QCOW2, or VHDX media.
## - ``run``: revert, exec, harvest, cleanup — the one-shot gate runner.
## - ``probe``: print available backends (capability detection).
## - ``shell``: interactive shell against a baseline (debug aid).
## - ``backends``: tabular listing of every backend the library knows about.
##
## ``--backend auto`` resolves to the dispatch table in
## ``auto.autoSelectBackendId``. When a real backend isn't registered the
## CLI falls back to NoopBackend if ``--allow-noop-fallback`` is set
## (used by the M0 selection test on hosts without real hypervisors).

import std/[json, options, os, osproc, sequtils, strformat, strutils, tables,
            terminal, times]
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
import ./backends/qemu_windows_arm
import ./backends/lima
import ./backends/libvirt
import ./backends/incus
{.pop.}
import ./prune

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
    secondaryIsoPath*: string
    targetDiskPath*: string
    mediaKind*: string
    expectPattern*: string
    generation*: int
    graphics*: string
    videoModel*: string
    viewer*: bool
    screenshotPath*: string
    screenshotDelaySec*: int
    sshForwardPort*: int
    sshUser*: string
    sshPasswordEnv*: string
    sshPrivateKey*: string
    cpus*: int
    memoryMB*: int
    diskGB*: int
    outputDir*: string
    ephemeralPrefix*: string
    envPairs*: Table[string, string]
    copyTo*: seq[tuple[host: string, guest: string]]
    copyFrom*: seq[tuple[guest: string, host: string]]
    shims*: seq[ArgvTraceShim]
    cmd*: seq[string]
    logFormat*: LogFormat
    allowNoopFallback*: bool
    timeoutSec*: int
    waitForShutdown*: bool
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
    imagePoolDir*: string        ## ``--image-pool-dir <dir>`` — libvirt-only
                                 ## override for the directory the domain's
                                 ## qcow2 disk is written to (disk lands at
                                 ## ``<dir>/<name>.qcow2``). Empty ⇒ backend
                                 ## default (``/var/lib/libvirt/images``).
    firstBootScript*: string     ## ``--first-boot-script <path>`` — file the
                                 ## recipe's build-autounattend-iso.sh wraps
                                 ## into the per-VM autounattend ISO.
    provisionScripts*: seq[string] ## ``--provision-script <path>`` (repeatable)
                                 ## — lima-only: each file's CONTENTS is read at
                                 ## parse time and baked into the generated Lima
                                 ## template's ``provision:`` block so every
                                 ## per-gate ephemeral boots already provisioned.
                                 ## Empty ⇒ no ``provision:`` block.
    ephemeral*: bool             ## ``--ephemeral`` — libvirt-only: run one
                                 ## per-job CoW-clone VM (fresh overlay from
                                 ## ``--golden-image``, boot, then destroy +
                                 ## remove overlay). This is the M2 per-job
                                 ## reset the GARM provider drives.
    keepEphemeral*: bool         ## ``--keep`` — libvirt-only (M3): with
                                 ## ``--ephemeral``, clone + attach the
                                 ## config-drive + boot (UEFI) and RETURN
                                 ## LEAVING THE DOMAIN RUNNING (no probe, no
                                 ## teardown). The caller drives an in-guest
                                 ## probe (e.g. SSH the Windows JIT bootstrap)
                                 ## then reclaims the VM via the
                                 ## ``ephemeral-destroy`` subcommand. Without
                                 ## ``--keep`` the M2 boot→probe→destroy
                                 ## lifecycle is unchanged.
    goldenImage*: string         ## ``--golden-image <path>`` — golden qcow2 the
                                 ## ephemeral overlay is CoW-cloned from.
    baseImage*: string           ## ``--base-image <alias>`` — incus-only: the
                                 ## base image alias/fingerprint the ephemeral
                                 ## per-job container is launched from. Empty ⇒
                                 ## the IncusBackend default (``vmh-base``).
    kernel*: string              ## ``--kernel <path>`` — optional direct-kernel
                                 ## boot bzImage for the ephemeral clone (the
                                 ## tiny Linux golden). Omit for a disk-bootable
                                 ## golden (firmware boots the overlay).
    initrd*: string              ## ``--initrd <path>`` — optional initramfs for
                                 ## the direct-kernel ephemeral boot.
    kernelCmdline*: string       ## ``--kernel-cmdline <str>`` — optional kernel
                                 ## cmdline for the direct-kernel ephemeral boot.
    userDataFile*: string        ## ``--user-data <path>`` — libvirt-only (M3):
                                 ## a file whose contents become the config-drive
                                 ## ``openstack/latest/user_data`` (the rendered
                                 ## GARM bootstrap). vm-harness builds a
                                 ## ``config-2``-labelled ISO and attaches it so
                                 ## cloudbase-init runs it on first boot.
    metaDataFile*: string        ## ``--meta-data <path>`` — optional override for
                                 ## the config-drive ``meta_data.json``.
    uefiLoader*: string          ## ``--uefi-loader <path>`` — OVMF code fd; when
                                 ## set the ephemeral clone boots UEFI (Windows).
    uefiNvramTemplate*: string   ## ``--uefi-nvram-template <path>`` — OVMF vars
                                 ## template donor for the per-job nvram copy.
    controllerPubKey*: string    ## ``--controller-pubkey <path>`` — SSH public
                                 ## key (``id_ed25519.pub`` or similar) that
                                 ## the recipe's build-autounattend-iso.sh
                                 ## wraps into the per-VM autounattend ISO so
                                 ## the guest's FirstLogonCommands can install
                                 ## it in ``authorized_keys`` before the
                                 ## controller first reaches out over SSH.
    stateDir*: string            ## ``--state-dir <dir>`` — ``prune`` scope for
                                 ## the qemu-windows-arm state directory.
    olderThanSec*: int           ## ``--older-than <sec>`` — ``prune`` age guard.
    olderThanSet*: bool          ## whether ``--older-than`` was supplied.
    dryRun*: bool                ## ``--dry-run`` — ``prune`` reports only.
    sweepTmp*: bool              ## ``--sweep-tmp`` — also age-sweep transient
                                 ## ``/tmp`` scratch files during ``prune``.

const HelpText = """
vm-harness <subcommand> [flags]

Subcommands:
  provision               Ensure a baseline image exists (idempotent).
  boot                    Boot ISO/QCOW2/VHDX media in a transient VM.
                          Use --keep to leave it running, or --expect REGEX
                          to assert a serial boot marker and clean it up.
  install                 Boot an ISO into a caller-owned target disk, require
                          a serial success marker and clean guest shutdown,
                          then remove the transient VM but preserve the disk.
  run                     One-shot revert + exec + harvest + cleanup.
  ephemeral-destroy       libvirt/incus: reclaim an ephemeral instance left
                          running by `run --ephemeral --keep` (destroy +
                          undefine --nvram + remove overlay/config-drive/
                          nvram — no residue). Requires --baseline.
  instance wait <name>    Wait for an existing Incus container to accept exec.
  instance exec <name> -- <command...>
                          Execute argv in an existing Incus container.
  instance copy-to <name> <host-path> <guest-path>
  instance copy-from <name> <guest-path> <host-path>
                          Transfer a file or directory through the backend.
  instance start <name>   Start and await an existing Incus container.
  instance stop <name>    Stop an existing Incus container without deleting it.
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
  prune --ephemeral-prefix <p> [--backend all|tart|qemu-windows-arm]
        [--state-dir <dir>] [--older-than <sec>] [--sweep-tmp] [--dry-run]
                          Reclaim ephemeral instances/clones leaked by
                          hard-killed launchers, scoped to --ephemeral-prefix.
                          A running instance (advisory lock held, or creator
                          PID alive) is never removed. --older-than guards the
                          PID-fallback path (default 3600s; 0 disables).
                          --sweep-tmp also age-removes transient /tmp scratch
                          files (SSH password files, mount-share scripts).
                          --dry-run reports what would be reclaimed.

Common flags:
  --backend <auto|noop|hyperv|wsl|tart-macos|tart-linux-arm|
             utm-windows-arm|qemu-windows-arm|libvirt|lima>
  --guest <linux|windows|macos>   Required when --backend auto.
  --baseline <name>               Logical baseline tag (== libvirt domain name).
  --name <vm>                     Alias for --baseline (canonical libvirt M4
                                  command shape; see docs/m4-libvirt.md).
  --recipe <id>                   Selects guest-recipes/<id>/ as the source of
                                  per-baseline artifacts (autounattend.xml,
                                  build-autounattend-iso.sh, ...). Required by
                                  backends that consume recipe-shaped inputs.
  --source-image <ref>
  --secondary-iso <path>          `boot`/`install`: attach a second read-only ISO.
  --target-disk <path>            `install`: create and preserve this blank disk.
  --kind <auto|iso|qcow2|vhdx|rootfs-tar>
                                  Media kind for `boot` (default: extension).
  --expect <regex>                `boot`: wait for a serial-console match.
  --wait-for-shutdown             `boot`: require a clean guest poweroff after
                                  the serial assertion before cleanup.
  --generation <1|2>             `boot`: legacy BIOS or UEFI (default: 2).
  --graphics <none|vnc|spice>    `boot`: graphical console (default: none).
  --video <model>                `boot`: video model (default: virtio).
  --viewer                       `boot`: open virt-viewer for libvirt and
                                  clean up when the window closes.
  --screenshot <path>            `boot`: capture the graphical console after
                                  --expect succeeds, then clean up by default.
  --screenshot-delay-sec <int>   `boot`: settle time after --expect before
                                  capture (default: 0).
  --ssh-forward-port <port|auto> `boot`: forward a loopback host port to
                                  guest TCP 22 (`auto` selects a free port).
  --ssh-user <name>              `boot`: SSH user for a command after `--`.
  --ssh-password-env <name>      `boot`: environment variable containing the
                                  SSH password; the value is never put in argv.
  --ssh-private-key <path>       `boot`: private key for key-only SSH.
  --cpus <int>                    Backend default applies when omitted.
  --vcpu <int>                    Alias for --cpus (canonical libvirt M4 shape).
  --memory-mb <int>
  --memory-gb <int>               Alias for --memory-mb, expressed in GiB.
  --disk-gb <int>
  --network-bridge <name>         libvirt-only: host bridge for the guest NIC
                                  (default: backend's configured value, e.g.
                                  virbr0). Ignored by other backends.
  --image-pool-dir <dir>          libvirt-only: directory the domain's qcow2
                                  disk is written to; the disk lands at
                                  <dir>/<name>.qcow2. Use it when your storage
                                  lives outside the default
                                  /var/lib/libvirt/images (e.g. a ZFS pool at
                                  /storage). Ignored by other backends.
  --first-boot-script <path>      libvirt-only: host path to a script the
                                  recipe wraps into the per-VM autounattend
                                  ISO. Requires --recipe.
  --provision-script <path>       lima-only (repeatable): host path to a shell
                                  script baked into the generated Lima
                                  template's provision: block so every per-gate
                                  ephemeral boots already provisioned.
  --controller-pubkey <path>      libvirt-only: SSH public key the recipe
                                  bakes into the autounattend ISO so the
                                  guest's FirstLogonCommands installs it in
                                  authorized_keys before first boot.
                                  Requires --recipe.
  --ephemeral                     libvirt-only: run ONE per-job CoW-clone VM
                                  (fresh overlay from --golden-image, boot on
                                  KVM, then destroy + remove overlay — no
                                  residue). The M2 per-job reset the GARM
                                  provider drives. A positional arg after --
                                  is treated as an expected serial boot marker.
  --keep                          Leave a `boot` VM running, or keep a libvirt
                                  ephemeral clone after startup.
  --golden-image <path>           libvirt-only: golden qcow2 the ephemeral
                                  overlay is CoW-cloned from. Requires
                                  --ephemeral.
  --kernel <path>                 libvirt-only: optional direct-kernel-boot
                                  bzImage for --ephemeral (tiny Linux golden).
  --initrd <path>                 libvirt-only: optional initramfs for the
                                  direct-kernel ephemeral boot.
  --kernel-cmdline <str>          libvirt-only: optional kernel cmdline for the
                                  direct-kernel ephemeral boot.
  --output-dir <path>
  --ephemeral-prefix <prefix>     Backend-specific prefix for ephemeral VMs.
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
  result.generation = 2
  result.graphics = "none"
  result.videoModel = "virtio"
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
    of "--secondary-iso":
      inc i; result.secondaryIsoPath = args[i]; inc i
    of "--target-disk":
      inc i; result.targetDiskPath = args[i]; inc i
    of "--kind":
      inc i; result.mediaKind = args[i]; inc i
    of "--expect":
      inc i; result.expectPattern = args[i]; inc i
    of "--generation":
      inc i
      result.generation = parseInt(args[i])
      if result.generation notin [1, 2]:
        raise newException(ValueError, "--generation expects 1 or 2")
      inc i
    of "--graphics":
      inc i
      result.graphics = args[i].toLowerAscii()
      if result.graphics notin ["none", "vnc", "spice"]:
        raise newException(ValueError,
          "--graphics expects none, vnc, or spice")
      inc i
    of "--video":
      inc i; result.videoModel = args[i]; inc i
    of "--viewer":
      result.viewer = true
      inc i
    of "--screenshot":
      inc i; result.screenshotPath = args[i]; inc i
    of "--screenshot-delay-sec":
      inc i
      result.screenshotDelaySec = parseInt(args[i])
      if result.screenshotDelaySec < 0:
        raise newException(ValueError,
          "--screenshot-delay-sec expects a non-negative integer")
      inc i
    of "--ssh-forward-port":
      inc i
      if args[i] == "auto":
        result.sshForwardPort = -1
      else:
        result.sshForwardPort = parseInt(args[i])
        if result.sshForwardPort notin 1 .. 65535:
          raise newException(ValueError,
            "--ssh-forward-port expects auto or a TCP port from 1 to 65535")
      inc i
    of "--ssh-user":
      inc i; result.sshUser = args[i]; inc i
    of "--ssh-password-env":
      inc i; result.sshPasswordEnv = args[i]; inc i
    of "--ssh-private-key":
      inc i; result.sshPrivateKey = args[i]; inc i
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
    of "--image-pool-dir":
      inc i; result.imagePoolDir = args[i]; inc i
    of "--first-boot-script":
      inc i; result.firstBootScript = args[i]; inc i
    of "--provision-script":
      inc i
      let p = args[i]
      if not fileExists(p):
        raise newException(ValueError,
          &"--provision-script '{p}': file not found")
      result.provisionScripts.add(readFile(p))
      inc i
    of "--controller-pubkey":
      inc i; result.controllerPubKey = args[i]; inc i
    of "--ephemeral":
      result.ephemeral = true
      inc i
    of "--keep":
      result.keepEphemeral = true
      inc i
    of "--golden-image":
      inc i; result.goldenImage = args[i]; inc i
    of "--base-image":
      inc i; result.baseImage = args[i]; inc i
    of "--kernel":
      inc i; result.kernel = args[i]; inc i
    of "--initrd":
      inc i; result.initrd = args[i]; inc i
    of "--kernel-cmdline":
      inc i; result.kernelCmdline = args[i]; inc i
    of "--user-data":
      inc i; result.userDataFile = args[i]; inc i
    of "--meta-data":
      inc i; result.metaDataFile = args[i]; inc i
    of "--uefi-loader":
      inc i; result.uefiLoader = args[i]; inc i
    of "--uefi-nvram-template":
      inc i; result.uefiNvramTemplate = args[i]; inc i
    of "--output-dir":
      inc i; result.outputDir = args[i]; inc i
    of "--ephemeral-prefix":
      inc i; result.ephemeralPrefix = args[i]; inc i
    of "--timeout-sec":
      inc i; result.timeoutSec = parseInt(args[i]); inc i
    of "--wait-for-shutdown":
      result.waitForShutdown = true
      inc i
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
    of "--state-dir":
      inc i; result.stateDir = args[i]; inc i
    of "--older-than":
      inc i; result.olderThanSec = parseInt(args[i]); result.olderThanSet = true
      inc i
    of "--dry-run":
      result.dryRun = true
      inc i
    of "--sweep-tmp":
      result.sweepTmp = true
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
  if result.sshPasswordEnv.len > 0 and result.sshPrivateKey.len > 0:
    raise newException(ValueError,
      "--ssh-password-env and --ssh-private-key are mutually exclusive")
  if result.sshPrivateKey.len > 0 and not fileExists(result.sshPrivateKey):
    raise newException(ValueError,
      &"--ssh-private-key '{result.sshPrivateKey}': file not found")

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

proc resolveBootMediaPath*(sourceImage: string): string =
  ## Accept either one media file or a recipe output directory. Directory
  ## selection is useful for content-addressed outputs whose filename embeds
  ## the image digest.
  if sourceImage.len == 0:
    raise newException(ValueError, "boot: --source-image is required")
  if fileExists(sourceImage):
    return absolutePath(sourceImage)
  if not dirExists(sourceImage):
    raise newException(ValueError,
      "boot: source image does not exist: " & sourceImage)

  var newestPath = ""
  var newestTime = fromUnix(0)
  for kind, path in walkDir(sourceImage):
    if kind != pcFile:
      continue
    let ext = splitFile(path).ext.toLowerAscii()
    if ext notin [".iso", ".qcow2", ".vhdx"]:
      continue
    let modified = getLastModificationTime(path)
    if newestPath.len == 0 or modified > newestTime or
        (modified == newestTime and path < newestPath):
      newestPath = path
      newestTime = modified
  if newestPath.len == 0:
    raise newException(ValueError,
      "boot: no .iso, .qcow2, or .vhdx media found in " & sourceImage)
  absolutePath(newestPath)

proc parseBootMediaKind*(value, mediaPath: string): BootMediaKind =
  let normalized = value.toLowerAscii()
  case normalized
  of "", "auto":
    case splitFile(mediaPath).ext.toLowerAscii()
    of ".iso": bmkIso
    of ".qcow2": bmkQcow2
    of ".vhdx": bmkVhdx
    else:
      raise newException(ValueError,
        "boot: cannot infer media kind from: " & mediaPath &
        "; pass --kind iso|qcow2|vhdx|rootfs-tar")
  of "iso": bmkIso
  of "qcow2": bmkQcow2
  of "vhdx": bmkVhdx
  of "rootfs-tar": bmkRootfsTar
  else:
    raise newException(ValueError,
      "boot: --kind expects auto|iso|qcow2|vhdx|rootfs-tar, got '" &
      value & "'")

proc resolveBootBackendId*(opts: CliOpts; mediaKind: BootMediaKind;
                           host: HostPlatform): BackendId =
  if opts.backend.len > 0 and opts.backend != "auto":
    return parseBackendId(opts.backend)
  case host
  of hpWindows:
    if mediaKind == bmkRootfsTar: biWsl else: biHyperv
  of hpLinux:
    if mediaKind == bmkRootfsTar:
      raise newException(ValueError,
        "boot: rootfs tar media is supported by the Windows WSL backend only")
    biLibvirt
  of hpMacosArm:
    raise newException(ValueError,
      "boot: no macOS backend currently implements bootFromMedia; " &
      "pass an explicit backend after adding that capability")

proc probeBackendIds*(opts: CliOpts): seq[BackendId] =
  if opts.backend == "" or opts.backend == "auto":
    registeredBackends()
  else:
    @[parseBackendId(opts.backend)]

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
  spec.provisionScripts = opts.provisionScripts
  spec.controllerPubKey = opts.controllerPubKey
  spec.networkBridge = opts.networkBridge
  spec.imagePoolDir = opts.imagePoolDir
  spec.backendOptions = initTable[string, string]()
  if opts.ephemeralPrefix.len > 0:
    spec.backendOptions["ephemeralPrefix"] = opts.ephemeralPrefix

proc resolveBootOutputDir*(requested: string;
                           processId = getCurrentProcessId()): string =
  ## Separate default boot artifacts for concurrent CLI invocations. Explicit
  ## output directories remain caller-owned and intentionally reusable.
  if requested.len > 0:
    absolutePath(requested)
  else:
    getTempDir() / ("vm-harness-boot-" & $processId)

proc cmdBoot(opts: CliOpts; installMode = false): int =
  if installMode:
    if opts.targetDiskPath.len == 0:
      raise newException(ValueError,
        "install: --target-disk is required")
    if opts.expectPattern.len == 0:
      raise newException(ValueError,
        "install: --expect is required so a failed installer poweroff cannot " &
        "be accepted as success")
    if opts.keepEphemeral or opts.viewer or opts.screenshotPath.len > 0 or
        opts.cmd.len > 0:
      raise newException(ValueError,
        "install: viewer, screenshot, SSH command, and --keep modes are not " &
        "valid during target-disk installation")
  if not installMode and not opts.keepEphemeral and opts.expectPattern.len == 0 and
      not opts.viewer and opts.screenshotPath.len == 0 and opts.cmd.len == 0:
    raise newException(ValueError,
      "boot: pass --keep to leave the VM running, --viewer for manual " &
      "inspection, --expect <regex> for a self-cleaning assertion, or " &
      "--screenshot <path> or an SSH command after -- for a self-cleaning " &
      "assertion")
  if opts.screenshotPath.len > 0 and opts.expectPattern.len == 0:
    raise newException(ValueError,
      "boot --screenshot requires --expect so capture has a readiness gate")
  if opts.screenshotPath.len == 0 and opts.screenshotDelaySec > 0:
    raise newException(ValueError,
      "boot --screenshot-delay-sec requires --screenshot")
  if opts.screenshotPath.len > 0 and opts.graphics == "none" and not opts.viewer:
    raise newException(ValueError,
      "boot --screenshot requires --graphics vnc or --graphics spice")

  let mediaPath = resolveBootMediaPath(opts.sourceImage)
  let mediaKind = parseBootMediaKind(opts.mediaKind, mediaPath)
  if opts.targetDiskPath.len > 0 and mediaKind != bmkIso:
    raise newException(ValueError,
      "--target-disk is valid only when booting installer ISO media")
  let id = resolveBootBackendId(opts, mediaKind, detectHostPlatform())
  let backend = newBackend(id, noopFallback = opts.allowNoopFallback)
  if not backend.probeAvailability():
    raise newException(BackendUnavailableError,
      "boot: backend is not available: " & $id)

  var sshForwardPort = opts.sshForwardPort
  if sshForwardPort == -1:
    sshForwardPort = pickTcpPort(0)
  if sshForwardPort != 0 and id != biLibvirt:
    raise newException(BackendUnavailableError,
      "boot: --ssh-forward-port is currently supported by libvirt")
  if opts.cmd.len > 0:
    if id != biLibvirt:
      raise newException(BackendUnavailableError,
        "boot: an SSH guest command is currently supported by libvirt")
    if sshForwardPort == 0:
      raise newException(ValueError,
        "boot: a guest command requires --ssh-forward-port")
    if opts.sshUser.len == 0:
      raise newException(ValueError,
        "boot: a guest command requires --ssh-user")
    if opts.sshPasswordEnv.len == 0 and opts.sshPrivateKey.len == 0:
      raise newException(ValueError,
        "boot: a guest command requires --ssh-password-env or " &
        "--ssh-private-key")
    let lb = LibvirtBackend(backend)
    lb.sshPort = sshForwardPort
    lb.sshUser = opts.sshUser
    if opts.sshPrivateKey.len > 0:
      lb.sshPassword = ""
      lb.sshKeyPath = absolutePath(opts.sshPrivateKey)
    else:
      let password = getEnv(opts.sshPasswordEnv)
      if password.len == 0:
        raise newException(ValueError,
          "boot: SSH password environment variable is unset or empty: " &
          opts.sshPasswordEnv)
      lb.sshPassword = password
      lb.sshKeyPath = ""
    if opts.guestSet:
      lb.sshGuestOs = opts.guest

  let outputDir = resolveBootOutputDir(opts.outputDir)
  createDir(outputDir)
  var extra = initTable[string, string]()
  if opts.uefiLoader.len > 0:
    extra["uefiLoader"] = absolutePath(opts.uefiLoader)
  if opts.uefiNvramTemplate.len > 0:
    extra["uefiNvramTemplate"] = absolutePath(opts.uefiNvramTemplate)
  let requestedGraphics =
    if opts.viewer and opts.graphics == "none": "vnc" else: opts.graphics
  let graphics = case requestedGraphics
    of "vnc": bgVnc
    of "spice": bgSpice
    else: bgNone
  let spec = BootMediaSpec(
    name: "",
    kind: mediaKind,
    mediaPath: mediaPath,
    secondaryIsoPath: (if opts.secondaryIsoPath.len > 0:
                         absolutePath(opts.secondaryIsoPath)
                       else: ""),
    targetDiskPath: (if opts.targetDiskPath.len > 0:
                       absolutePath(opts.targetDiskPath)
                     else: ""),
    cpus: (if opts.cpus > 0: opts.cpus else: 2),
    memoryMB: (if opts.memoryMB > 0: opts.memoryMB else: 4096),
    generation: opts.generation,
    secureBootEnabled: false,
    graphics: graphics,
    videoModel: opts.videoModel,
    sshForwardPort: sshForwardPort,
    diskGB: (if opts.diskGB > 0: opts.diskGB else: 8),
    serialPipeName: "",
    serialLogPath: outputDir / "boot.serial.log",
    extra: extra)

  logEvent(opts.logFormat, "info", "booting media",
           {"backend": $id, "media": mediaPath, "kind": $mediaKind})
  var vm: VmHandle
  var serial: SerialStream
  try:
    vm = backend.bootFromMedia(spec)

    # Hyper-V creates the VM in the Off state; captureSerial starts it while
    # wiring COM1. Libvirt starts the domain during bootFromMedia.
    if id == biHyperv or opts.expectPattern.len > 0:
      serial = backend.captureSerial(vm)

    if opts.expectPattern.len > 0:
      let timeout = if opts.timeoutSec > 0: opts.timeoutSec
                    elif installMode: 1800
                    else: 180
      let match = backend.expectLine(serial, opts.expectPattern, timeout)
      if not match.matched:
        logEvent(opts.logFormat, "error", "boot marker not observed",
                 {"vm": vm.name, "pattern": opts.expectPattern,
                  "serialLog": serial.logPath})
        return 1
      logEvent(opts.logFormat, "info", "boot marker observed",
               {"vm": vm.name, "match": match.matchedText.strip(),
                "serialLog": serial.logPath})
    elif id == biHyperv:
      # Let Start-VM leave the PowerShell launcher before closing its serial
      # reader. Closing the reader does not stop the VM.
      sleep(1000)

    if installMode or opts.waitForShutdown:
      let shutdownTimeout = if opts.timeoutSec > 0: opts.timeoutSec
                            elif installMode: 1800
                            else: 180
      if not backend.waitForShutdown(vm, shutdownTimeout):
        logEvent(opts.logFormat, "error", "clean guest shutdown not observed",
                 {"vm": vm.name, "serialLog": serial.logPath})
        return 1
      logEvent(opts.logFormat, "info", "clean guest shutdown observed",
               {"vm": vm.name})

    if opts.screenshotPath.len > 0:
      if opts.screenshotDelaySec > 0:
        sleep(opts.screenshotDelaySec * 1000)
      let screenshotPath = absolutePath(opts.screenshotPath)
      backend.captureScreenshot(vm, screenshotPath)
      logEvent(opts.logFormat, "info", "graphical console captured",
               {"backend": $id, "vm": vm.name,
                "screenshot": screenshotPath})

    if opts.cmd.len > 0:
      let timeout = if opts.timeoutSec > 0: opts.timeoutSec else: 180
      backend.startAndAwaitReady(vm, timeout)
      let execution = backend.execInGuest(
        vm, opts.envPairs, opts.cmd, timeoutSec = timeout)
      if execution.stdout.len > 0:
        stdout.write(execution.stdout)
      if execution.stderr.len > 0:
        stderr.write(execution.stderr)
      if execution.exitCode != 0:
        return execution.exitCode

    if opts.viewer:
      if id != biLibvirt:
        raise newException(BackendUnavailableError,
          "boot --viewer is currently supported by the libvirt backend")
      let viewer = findExe("virt-viewer")
      if viewer.len == 0:
        raise newException(BackendUnavailableError,
          "boot --viewer requires virt-viewer on PATH")
      let lb = LibvirtBackend(backend)
      logEvent(opts.logFormat, "info", "opening graphical console",
               {"backend": $id, "vm": vm.name})
      let viewerProcess = startProcess(viewer,
        args = @["--connect", lb.libvirtUri, "--wait", vm.name],
        options = {poUsePath, poParentStreams})
      let viewerExit = viewerProcess.waitForExit()
      viewerProcess.close()
      if viewerExit != 0:
        raise newException(VmHarnessError,
          "virt-viewer exited with status " & $viewerExit)

    if opts.keepEphemeral:
      logEvent(opts.logFormat, "info", "VM left running",
               {"backend": $id, "vm": vm.name})
      echo vm.name
    0
  finally:
    if serial != nil:
      backend.closeSerial(serial)
    if vm != nil and not opts.keepEphemeral:
      backend.stopAndCleanup(vm, deleteVm = true)

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

proc cmdRunEphemeralIncus(opts: CliOpts): int =
  ## Incus per-job ephemeral CONTAINER: launch a FRESH container from the
  ## base image, run an exec probe, then destroy it (``incus delete
  ## --force``) leaving NO residue. The container analog of the libvirt
  ## CoW-clone path — the same create→probe→destroy lifecycle the GARM
  ## provider's CreateInstance/DeleteInstance drive, but far cheaper (no
  ## /dev/kvm, sub-second launch).
  ##
  ## ``--baseline`` names the per-job container; ``--base-image`` the image
  ## to launch from (default ``vmh-base``). ``--user-data`` (when set)
  ## injects cloud-init user-data — the IM2 JIT seam. Args after ``--`` are
  ## the in-guest probe command (default ``true``).
  let backend = newBackend(biIncus)
  if opts.baseline.len == 0:
    raise newException(ValueError,
      "run --ephemeral --backend incus: --baseline (container name) is required")
  let ib = IncusBackend(backend)
  var userData = ""
  if opts.userDataFile.len > 0:
    if not fileExists(opts.userDataFile):
      raise newException(ValueError,
        "run --ephemeral: --user-data file not found: " & opts.userDataFile)
    userData = readFile(opts.userDataFile)
  let spec = EphemeralIncusSpec(
    name: opts.baseline,
    baseImage: opts.baseImage,
    ephemeral: false,
    userData: userData,
    config: initTable[string, string]())
  logEvent(opts.logFormat, "info", "ephemeral container: launch",
           {"backend": $biIncus, "name": opts.baseline,
            "base": (if opts.baseImage.len > 0: opts.baseImage else: ib.baseImage)})
  var vm = ib.provisionEphemeralClone(spec)
  if opts.keepEphemeral:
    logEvent(opts.logFormat, "info", "ephemeral container: kept running",
             {"name": opts.baseline})
    echo opts.baseline
    return 0
  var verdict = 2
  try:
    let readyTimeout = if opts.timeoutSec > 0: opts.timeoutSec else: 60
    ib.startAndAwaitReady(vm, readyTimeout)
    let probeCmd = if opts.cmd.len > 0: opts.cmd else: @["true"]
    let r = ib.execInGuest(vm, initTable[string, string](), probeCmd,
                           timeoutSec = readyTimeout)
    if r.exitCode == 0:
      logEvent(opts.logFormat, "info", "ephemeral probe: ok",
               {"cmd": probeCmd.join(" "), "stdout": r.stdout.strip()})
      verdict = 0
    else:
      logEvent(opts.logFormat, "error", "ephemeral probe: FAILED",
               {"cmd": probeCmd.join(" "), "exit": $r.exitCode,
                "stdout": r.stdout.strip()})
      verdict = 1
    if opts.outputDir.len > 0:
      try:
        createDir(opts.outputDir)
        writeFile(opts.outputDir / "probe.log", r.stdout)
      except CatchableError: discard
  finally:
    ib.stopAndCleanup(vm, deleteVm = true)
    logEvent(opts.logFormat, "info", "ephemeral container: destroyed",
             {"name": opts.baseline})
  verdict

proc cmdRunEphemeral(opts: CliOpts): int =
  ## M2 per-job ephemeral CoW clone: clone a fresh overlay from the
  ## golden, boot it on KVM, harvest the serial console (boot-marker
  ## probe), then destroy the domain + remove the overlay (no residue).
  ## This is the exact create→boot→probe→destroy lifecycle the GARM
  ## provider's CreateInstance/DeleteInstance will drive (M4).
  ##
  ## The probe is a serial boot marker rather than an in-guest exec
  ## because the OS-agnostic tiny golden self-terminates
  ## (``poweroff -f``); a real Windows/Linux golden that stays up would
  ## instead use the SSH ``execInGuest`` path. When ``--`` supplies an
  ## argument it is treated as the expected serial marker substring.
  ##
  ## The Incus container path is a separate lifecycle (no serial console,
  ## an in-guest exec probe instead) — dispatch to it when the backend is
  ## ``incus``.
  if opts.backend == $biIncus:
    return cmdRunEphemeralIncus(opts)
  let id = biLibvirt
  let backend = newBackend(id)
  if opts.baseline.len == 0:
    raise newException(ValueError, "run --ephemeral: --baseline is required")
  if opts.goldenImage.len == 0:
    raise newException(ValueError,
      "run --ephemeral: --golden-image is required")
  let lb = LibvirtBackend(backend)
  # M3: build the config-drive ISO from --user-data so cloudbase-init runs
  # the injected bootstrap on first boot. Per-job artifacts (ISO + nvram)
  # live next to the overlay and are removed on teardown.
  var configDriveIso = ""
  if opts.userDataFile.len > 0:
    if not fileExists(opts.userDataFile):
      raise newException(ValueError,
        "run --ephemeral: --user-data file not found: " & opts.userDataFile)
    let userData = readFile(opts.userDataFile)
    var metaData = ""
    if opts.metaDataFile.len > 0 and fileExists(opts.metaDataFile):
      metaData = readFile(opts.metaDataFile)
    configDriveIso = lb.configDriveIsoPathFor(opts.baseline)
    discard buildConfigDriveIso(configDriveIso, userData, metaData)
  var uefiNvram = ""
  if opts.uefiLoader.len > 0:
    uefiNvram = lb.imagePoolDir / (opts.baseline & "_VARS.fd")
  let spec = EphemeralCloneSpec(
    name: opts.baseline,
    goldenImage: opts.goldenImage,
    cpus: (if opts.cpus > 0: opts.cpus else: 2),
    memoryMB: (if opts.memoryMB > 0: opts.memoryMB else: 1024),
    kernel: opts.kernel,
    initrd: opts.initrd,
    cmdline: opts.kernelCmdline,
    configDriveIso: configDriveIso,
    uefiLoader: opts.uefiLoader,
    uefiNvramTemplate: opts.uefiNvramTemplate,
    uefiNvram: uefiNvram)
  let expectMarker = if opts.cmd.len > 0: opts.cmd[0] else: ""
  let timeoutSec = if opts.timeoutSec > 0: opts.timeoutSec else: 120
  logEvent(opts.logFormat, "info", "ephemeral clone: boot",
           {"backend": $id, "name": opts.baseline,
            "golden": opts.goldenImage})
  var vm = lb.provisionEphemeralClone(spec)

  # --keep: leave the domain RUNNING for an out-of-band in-guest probe
  # (e.g. the Windows JIT gate SSHes in and drives the bootstrap). The
  # caller reclaims the VM via the ``ephemeral-destroy`` subcommand,
  # which runs the very same ephemeral ``stopAndCleanup`` teardown. This
  # is the real CLI path the M3 gate exercises for a long-lived Windows
  # golden that stays up (as opposed to the M2 tiny golden that
  # self-terminates and is probed via the serial marker below).
  if opts.keepEphemeral:
    logEvent(opts.logFormat, "info", "ephemeral clone: kept running",
             {"name": opts.baseline,
              "overlay": vm.extra.getOrDefault("overlayPath", ""),
              "config_drive": vm.extra.getOrDefault("configDriveIso", ""),
              "uefi_nvram": vm.extra.getOrDefault("uefiNvram", "")})
    # Emit the domain name on stdout so a shell caller can capture it.
    echo opts.baseline
    return 0

  var verdict = 2
  try:
    # Poll for self-poweroff (tiny golden) or timeout.
    let serialLog = vm.extra.getOrDefault("serialLogPath", "")
    let deadline = epochTime() + timeoutSec.float
    var poweredOff = false
    while epochTime() < deadline:
      if lb.domainState(opts.baseline) == "shut off":
        poweredOff = true
        break
      sleep(500)
    var serial = ""
    if serialLog.len > 0 and fileExists(serialLog):
      serial = readFile(serialLog)
    if expectMarker.len > 0:
      if expectMarker in serial:
        logEvent(opts.logFormat, "info", "ephemeral probe: marker found",
                 {"marker": expectMarker, "powered_off": $poweredOff})
        verdict = 0
      else:
        logEvent(opts.logFormat, "error",
                 "ephemeral probe: marker NOT found",
                 {"marker": expectMarker})
        verdict = 1
    else:
      # No expected marker: success == the domain booted and reached
      # power-off within the deadline.
      verdict = if poweredOff: 0 else: 1
    if opts.outputDir.len > 0 and serial.len > 0:
      try:
        createDir(opts.outputDir)
        writeFile(opts.outputDir / "serial.log", serial)
      except CatchableError: discard
  finally:
    lb.stopAndCleanup(vm, deleteVm = true)
    logEvent(opts.logFormat, "info", "ephemeral clone: destroyed",
             {"name": opts.baseline})
  verdict

proc cmdEphemeralDestroy(opts: CliOpts): int =
  ## Reclaim an ephemeral clone left running by ``run --ephemeral --keep``.
  ## Reconstructs the per-job VmHandle (the ephemeral artifact paths are
  ## deterministic from ``--baseline``) and runs the SAME ephemeral
  ## ``stopAndCleanup(deleteVm=true)`` teardown the non-keep path runs:
  ## ``virsh destroy`` + ``virsh undefine --nvram`` + remove the CoW
  ## overlay + the injected config-drive ISO + the per-job OVMF nvram —
  ## leaving NO residue. The golden + the OVMF template are never touched.
  if opts.baseline.len == 0:
    raise newException(ValueError,
      "ephemeral-destroy: --baseline is required")

  if opts.backend.toLowerAscii() == "incus":
    let ib = IncusBackend(newBackend(biIncus))
    var extra = initTable[string, string]()
    extra["container"] = opts.baseline
    extra["ephemeral"] = "true"
    extra["baseImage"] = opts.baseImage
    extra["storagePool"] = ib.storagePool
    let vm = VmHandle(
      backend: ib,
      name: opts.baseline,
      baseline: opts.baseImage,
      ipAddress: none(string),
      sshPort: 0,
      sshUser: ib.execUser,
      sshAuth: SshAuth(kind: saNone),
      extra: extra)
    ib.stopAndCleanup(vm, deleteVm = true)
    logEvent(opts.logFormat, "info", "ephemeral container: destroyed",
             {"name": opts.baseline})
    return 0

  let backend = newBackend(biLibvirt)
  let lb = LibvirtBackend(backend)
  var extra = initTable[string, string]()
  extra["libvirtUri"] = lb.libvirtUri
  extra["domain"] = opts.baseline
  extra["ephemeral"] = "true"
  extra["overlayPath"] = lb.overlayPathFor(opts.baseline)
  # The config-drive ISO + per-job OVMF nvram are per-job artifacts named
  # after the domain; point stopAndCleanup at their deterministic paths so
  # they are removed only if present (a tiny-Linux clone has neither).
  extra["configDriveIso"] = lb.configDriveIsoPathFor(opts.baseline)
  extra["uefiNvram"] = lb.imagePoolDir / (opts.baseline & "_VARS.fd")
  let vm = VmHandle(
    backend: lb,
    name: opts.baseline,
    baseline: opts.goldenImage,
    ipAddress: none(string),
    sshPort: lb.sshPort,
    sshUser: lb.sshUser,
    sshAuth: SshAuth(kind: saNone),
    extra: extra)
  lb.stopAndCleanup(vm, deleteVm = true)
  logEvent(opts.logFormat, "info", "ephemeral clone: destroyed",
           {"name": opts.baseline})
  0

proc cmdRun(opts: CliOpts): int =
  if opts.ephemeral:
    return cmdRunEphemeral(opts)
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
  for id in probeBackendIds(opts):
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
               of biTartMacos, biTartLinuxArm, biUtmWindowsArm,
                  biQemuWindowsArm: "macos-arm"
               of biLibvirt, biLima: "linux/macos"
               of biIncus: "linux"
    let guests = case id
                 of biNoop: "any"
                 of biHyperv: "linux,windows"
                 of biWsl: "linux"
                 of biTartMacos: "macos"
                 of biTartLinuxArm: "linux"
                 of biUtmWindowsArm, biQemuWindowsArm: "windows"
                 of biLibvirt: "linux,windows"
                 of biLima: "linux"
                 of biIncus: "linux"
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

proc existingIncusHandle(opts: CliOpts, name: string):
    tuple[backend: IncusBackend, vm: VmHandle] =
  if opts.backend.toLowerAscii() != "incus":
    raise newException(ValueError,
      "instance operations currently require --backend incus")
  if name.len == 0:
    raise newException(ValueError, "instance operation requires a name")
  let backend = IncusBackend(newBackend(biIncus))
  var extra = initTable[string, string]()
  extra["container"] = name
  extra["storagePool"] = backend.storagePool
  let vm = VmHandle(
    backend: backend,
    name: name,
    baseline: backend.baseImage,
    ipAddress: none(string),
    sshPort: 0,
    sshUser: backend.execUser,
    sshAuth: SshAuth(kind: saNone),
    extra: extra)
  (backend: backend, vm: vm)

proc cmdInstance(opts: CliOpts): int =
  if opts.cmd.len < 2:
    raise newException(ValueError,
      "instance requires <wait|exec|copy-to|copy-from|start|stop> <name>")
  let action = opts.cmd[0]
  let name = opts.cmd[1]
  let (backend, vm) = existingIncusHandle(opts, name)
  let timeout = if opts.timeoutSec > 0: opts.timeoutSec else: 120

  case action
  of "wait":
    if opts.cmd.len != 2:
      raise newException(ValueError, "instance wait accepts only <name>")
    backend.startAndAwaitReady(vm, timeout)
  of "exec":
    if opts.cmd.len < 3:
      raise newException(ValueError,
        "instance exec requires a command after <name>")
    backend.startAndAwaitReady(vm, timeout)
    let r = backend.execInGuest(vm, opts.envPairs, opts.cmd[2 .. ^1],
                                timeoutSec = timeout)
    stdout.write(r.stdout)
    stderr.write(r.stderr)
    return r.exitCode
  of "copy-to":
    if opts.cmd.len != 4:
      raise newException(ValueError,
        "instance copy-to requires <name> <host-path> <guest-path>")
    backend.startAndAwaitReady(vm, timeout)
    backend.copyToGuest(vm, opts.cmd[2], opts.cmd[3])
  of "copy-from":
    if opts.cmd.len != 4:
      raise newException(ValueError,
        "instance copy-from requires <name> <guest-path> <host-path>")
    backend.startAndAwaitReady(vm, timeout)
    backend.copyFromGuest(vm, opts.cmd[2], opts.cmd[3])
  of "start":
    if opts.cmd.len != 2:
      raise newException(ValueError, "instance start accepts only <name>")
    backend.startContainer(name)
    backend.startAndAwaitReady(vm, timeout)
  of "stop":
    if opts.cmd.len != 2:
      raise newException(ValueError, "instance stop accepts only <name>")
    backend.stopContainer(name)
  else:
    raise newException(ValueError, "unknown instance action: " & action)

  logEvent(opts.logFormat, "info", "instance operation complete",
           {"backend": $biIncus, "action": action, "name": name})
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

proc cmdPrune(opts: CliOpts): int =
  ## Reclaim ephemeral resources leaked by hard-killed launchers, scoped to a
  ## project's ``--ephemeral-prefix``. Never touches anything outside that
  ## scope and never removes an instance whose owner is still alive.
  if opts.ephemeralPrefix.len == 0:
    stderr.writeLine(
      "vm-harness prune: --ephemeral-prefix is required (project scope)")
    return 2
  var backend = opts.backend
  if backend.len == 0 or backend == "auto":
    backend = "all"
  if backend notin ["all", "tart", "qemu-windows-arm"]:
    stderr.writeLine(
      "vm-harness prune: --backend must be all|tart|qemu-windows-arm")
    return 2
  let scope = PruneScope(
    ephemeralPrefix: opts.ephemeralPrefix,
    stateDir: opts.stateDir,
    olderThanSec: (if opts.olderThanSet: opts.olderThanSec else: DefaultPruneAgeSec),
    dryRun: opts.dryRun,
    backend: backend,
    sweepTmp: opts.sweepTmp)
  let rep = runPrune(scope)
  let mib = rep.bytesReclaimed.float / (1024.0 * 1024.0)
  if opts.logFormat == lfJson:
    echo $(%*{
      "event": "prune",
      "dryRun": opts.dryRun,
      "ephemeralPrefix": opts.ephemeralPrefix,
      "backend": backend,
      "olderThanSec": scope.olderThanSec,
      "removedInstanceDirs": rep.removedInstanceDirs,
      "liveInstanceDirs": rep.liveInstanceDirs,
      "freshInstanceDirs": rep.freshInstanceDirs,
      "removedTartClones": rep.removedTartClones,
      "liveTartClones": rep.liveTartClones,
      "removedTmpFiles": rep.removedTmpFiles,
      "bytesReclaimed": rep.bytesReclaimed})
  else:
    let verb = if opts.dryRun: "would reclaim" else: "reclaimed"
    echo &"vm-harness prune ({backend}, prefix '{opts.ephemeralPrefix}'): " &
         &"{verb} {rep.removedInstanceDirs.len} instance dir(s), " &
         &"{rep.removedTartClones.len} tart clone(s), " &
         &"{rep.removedTmpFiles.len} tmp file(s) " &
         &"(~{mib:.1f} MiB); kept {rep.liveInstanceDirs.len} live + " &
         &"{rep.freshInstanceDirs.len} fresh instance dir(s), " &
         &"{rep.liveTartClones.len} live tart clone(s)."
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
  of "boot":      return cmdBoot(opts)
  of "install":   return cmdBoot(opts, installMode = true)
  of "run":       return cmdRun(opts)
  of "ephemeral-destroy": return cmdEphemeralDestroy(opts)
  of "probe":     return cmdProbe(opts)
  of "backends":  return cmdBackends(opts)
  of "shell":     return cmdShell(opts)
  of "instance":  return cmdInstance(opts)
  of "snapshot":  return cmdSnapshot(opts)
  of "baseline":  return cmdBaseline(opts)
  of "prune":     return cmdPrune(opts)
  else:
    stderr.writeLine("vm-harness: unknown subcommand '" & opts.subcommand & "'")
    stderr.writeLine(HelpText)
    return 2

when isMainModule:
  quit(runCli(commandLineParams()))
