## vm-harness types
##
## Defines the public types of the ``vm-harness`` library:
##
## - ``VmBackend`` ref-object concept with the lifecycle every backend must
##   implement (provisionBaseline, revertToBaseline, startAndAwaitReady,
##   execInGuest, copyToGuest, copyFromGuest, installArgvTraceShim,
##   uninstallArgvTraceShim, stopAndCleanup).
## - Supporting value types (``BaselineSpec``, ``VmHandle``, ``SshAuth``,
##   ``ExecResult``, ``ArgvTraceShim``).
## - The exception hierarchy (``VmHarnessError`` and friends).
## - The host/guest OS enums and the ``selectBackendId`` table that drives
##   ``--backend auto`` dispatch.
##
## See ``docs/design.md`` for the canonical contract; this module is the
## machine-readable mirror of design doc §3.2 + §3.6. Per-backend
## implementations live under ``src/vm_harness/backends/``.

import std/[options, tables]

type
  HostPlatform* = enum
    hpWindows = "windows"
    hpLinux = "linux"
    hpMacosArm = "macos-arm"

  GuestOs* = enum
    goWindows = "windows"
    goLinux = "linux"
    goMacos = "macos"

  GuestArch* = enum
    gaX86_64 = "x86_64"
    gaArm64 = "arm64"

  BackendId* = enum
    biNoop = "noop"
    biHyperv = "hyperv"
    biWsl = "wsl"
    biTartMacos = "tart-macos"
    biTartLinuxArm = "tart-linux-arm"
    biUtmWindowsArm = "utm-windows-arm"
    biQemuWindowsArm = "qemu-windows-arm"
    biLibvirt = "libvirt"
    biLima = "lima"
    biIncus = "incus"

  SshAuthKind* = enum
    saNone, saPassword, saKeyFile

  SshAuth* = object
    case kind*: SshAuthKind
    of saNone: discard
    of saPassword:
      password*: string
    of saKeyFile:
      keyPath*: string

  BaselineSpec* = object
    name*: string                ## human-readable baseline tag (e.g. "base-clean")
    sourceImage*: string         ## backend-specific reference (OCI ref, ISO URL, VHDX path...)
    cpus*: int                   ## defaults to 2 when zero
    memoryMB*: int               ## defaults to 4096 when zero
    diskGB*: int                 ## defaults to 50 when zero
    guestOs*: GuestOs
    guestArch*: GuestArch
    recipeDir*: string           ## resolved path to ``guest-recipes/<id>/`` when
                                 ## the caller passed ``--recipe <id>``; empty
                                 ## when no recipe was supplied. Backends that
                                 ## consume recipes (libvirt windows-x64-base
                                 ## today) read companion artifacts relative to
                                 ## this directory.
    recipeBuildDir*: string      ## optional override for the recipe's per-run
                                 ## ``build/`` directory (autounattend.iso,
                                 ## virtio-win.iso, Win11_*.iso symlink). Empty
                                 ## falls back to ``<recipeDir>/build`` — which
                                 ## is writable for in-tree checkouts but
                                 ## read-only when ``recipeDir`` lives under
                                 ## ``/nix/store``. The CLI exposes this as
                                 ## ``--recipe-build-dir``.
    firstBootScript*: string     ## optional host path to a first-boot script
                                 ## (e.g. ``./bootstrap-windows-runner-001.ps1``)
                                 ## that the recipe wraps into the per-VM
                                 ## autounattend ISO at provision time.
    controllerPubKey*: string    ## optional host path to an SSH public key
                                 ## (typically ``id_ed25519.pub``) that the
                                 ## recipe wraps into the per-VM autounattend
                                 ## ISO. The autounattend's FirstLogonCommands
                                 ## block reads it back inside the guest and
                                 ## writes the key into
                                 ## ``C:\Users\<sshUser>\.ssh\authorized_keys``
                                 ## so the controller can reach the guest over
                                 ## SSH on first boot without a manual paste.
    networkBridge*: string       ## libvirt-specific: name of the host bridge
                                 ## the guest's primary NIC attaches to
                                 ## (``virbr0`` for default NAT, ``br0`` for an
                                 ## L2 bridge). Empty means "use the backend's
                                 ## configured default". Other backends ignore.
    imagePoolDir*: string        ## libvirt-specific: directory the domain's
                                 ## qcow2 disk is written to (the disk lands at
                                 ## ``<imagePoolDir>/<name>.qcow2``). Lets an
                                 ## operator whose storage lives outside the
                                 ## default ``/var/lib/libvirt/images`` (e.g. a
                                 ## large ZFS pool at ``/storage``) place the
                                 ## disk there without abandoning the CLI. Empty
                                 ## means "use the backend's configured default".
                                 ## Other backends ignore.
    provisionScripts*: seq[string]
                                 ## lima-specific: first-boot provisioning
                                 ## scripts (each a full shell-script body) baked
                                 ## into the generated Lima template's
                                 ## ``provision:`` section so every per-gate
                                 ## ephemeral comes up already provisioned,
                                 ## instead of the consumer re-running an
                                 ## in-guest setup script on every run. Empty ⇒
                                 ## no ``provision:`` block (default template
                                 ## unchanged). Other backends ignore.
    backendOptions*: Table[string, string]
                                 ## Free-form per-backend overrides. Used as the
                                 ## escape hatch for backend-specific knobs that
                                 ## haven't earned a typed field yet — callers
                                 ## must namespace keys (``libvirt.<x>``,
                                 ## ``hyperv.<x>``, ...). Unrecognised keys MUST
                                 ## be ignored by the backend, not error.

  VmHandle* = ref object
    ## Live, started VM ready for ``execInGuest``. Backends construct one in
    ## ``revertToBaseline`` and pass it back to the consumer.
    backend*: VmBackend          ## owning backend (cyclic but safe — both
                                 ## live for the duration of one gate).
    name*: string                ## ephemeral name (e.g. ``repro-vm-12345``).
    baseline*: string            ## the baseline this VM was cloned from.
    ipAddress*: Option[string]
    sshPort*: int
    sshUser*: string
    sshAuth*: SshAuth
    extra*: Table[string, string] ## backend-specific scratch (mount paths etc.)

  ExecResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string
    elapsedMs*: int

  ArgvTraceShim* = object
    wrappedBinaryName*: string   ## e.g. "useradd"
    traceLogPath*: string        ## in-guest path where argv lines accumulate

  LifecyclePhase* = enum
    lpProbe = "probe"
    lpProvisioning = "provisioning"
    lpRevert = "revert"
    lpStartup = "startup"
    lpExec = "exec"
    lpCopy = "copy"
    lpShim = "shim"
    lpCleanup = "cleanup"

  VmHarnessError* = object of CatchableError
    backend*: string
    phase*: LifecyclePhase
    cause*: ref Exception

  TimeoutError* = object of VmHarnessError
  BackendUnavailableError* = object of VmHarnessError
  GuestBootFailureError* = object of VmHarnessError
  CommandFailedError* = object of VmHarnessError
    exitCode*: int

  VmBackend* = ref object of RootObj
    id*: BackendId
    hostPlatform*: HostPlatform
    supportedGuests*: set[GuestOs]

  # -------------------------------------------------------------------------
  # M1.5: bootFromMedia + serial-stream primitives.
  #
  # Distinct from the BaselineSpec / revertToBaseline contract: BaselineSpec
  # provisions a long-lived known-good guest and revert spins up a fast clone
  # ready for ``execInGuest``. BootMediaSpec spins up a TRANSIENT VM around
  # a specific bootable artifact (VHDX / ISO / rootfs tarball) to capture
  # serial output during OS bring-up itself — before the guest is "ready"
  # enough for ``execInGuest`` to work. Motivated by ReproOS-MVP R0/R1: the
  # campaign needs to assert on systemd's serial output during a real boot.

  BootMediaKind* = enum
    bmkIso = "iso"             ## boot from CD/DVD (Hyper-V SCSI DVD drive)
    bmkVhdx = "vhdx"           ## boot from existing VHDX/VHD (no baseline)
    bmkQcow2 = "qcow2"         ## boot from qcow2 (libvirt/QEMU)
    bmkRootfsTar = "rootfs-tar" ## boot from tarball rootfs (WSL2)

  BootGraphicsKind* = enum
    bgNone = "none"            ## no graphical console
    bgVnc = "vnc"              ## loopback-only VNC console
    bgSpice = "spice"          ## loopback-only SPICE console

  BootAcceleration* = enum
    baAuto = "auto"            ## backend selects hardware acceleration
    baKvm = "kvm"              ## require Linux KVM acceleration
    baTcg = "tcg"              ## QEMU software emulation

  BootMediaSpec* = object
    ## Direct-boot media for testing OS bring-up itself (not test-in-guest).
    ## Distinct from BaselineSpec: BaselineSpec provisions a long-lived
    ## known-good guest; BootMediaSpec spins up a transient VM around a
    ## specific bootable artifact to capture serial output during boot.
    name*: string                   ## ephemeral VM name (backend-prefixed)
    kind*: BootMediaKind
    mediaPath*: string              ## primary boot media (VHDX/ISO/tar path)
    secondaryIsoPath*: string       ## optional second ISO (e.g. cloud-init seed)
    targetDiskPath*: string         ## optional caller-owned blank install disk
      ## Valid only with bmkIso. When set, the backend creates a blank disk at
      ## this exact path, installs into it, and never removes it during VM
      ## cleanup. Existing paths are rejected instead of overwritten.
    cpus*: int                      ## defaults to 2 when zero
    memoryMB*: int                  ## defaults to 2048 when zero
    generation*: int                ## 1 (legacy BIOS) or 2 (UEFI); defaults to 2
    secureBootEnabled*: bool        ## defaults to false (most test ISOs unsigned)
    acceleration*: BootAcceleration ## libvirt execution mode; defaults to auto
    graphics*: BootGraphicsKind     ## graphical console; defaults to none
    videoModel*: string             ## backend video model; defaults to virtio
    sshForwardPort*: int            ## loopback host port forwarded to guest SSH
    tpmEnabled*: bool               ## attach a virtual TPM 2.0 (Gen 2 / UEFI only)
      ## Windows 11 Setup refuses to install without TPM 2.0 — it fails at the
      ## "This PC can't run Windows 11" gate long before the autounattend's
      ## specialize pass runs, so this is not optional for a Win11 guest.
      ##
      ## Backends realise it differently and it is NOT free: on Hyper-V the vTPM
      ## is backed by a key protector that must be created BEFORE the device is
      ## added (``Set-VMKeyProtector`` then ``Enable-VMTPM``), which is why this
      ## is a spec field rather than something a caller can bolt on afterwards.
      ## libvirt/QEMU back it with swtpm instead.
    diskGB*: int                    ## bmkIso scratch boot disk size; defaults to 8
      ## Only consulted when the boot disk is created by the backend (bmkIso);
      ## for bmkVhdx the media IS the disk and this is ignored. The 8 GB default
      ## suits a Linux install ISO; Windows 11 requires >= 64 GB and Setup's
      ## partitioning step fails on anything smaller.
    serialPipeName*: string         ## backend may override; otherwise auto-generated
    serialLogPath*: string          ## host-side path where serial bytes are logged
    extra*: Table[string, string]   ## backend-specific scratch (post-import scripts...)

  SerialMatch* = object
    ## Result of a single boot-time assertion.
    matched*: bool
    matchedText*: string            ## the line that matched
    elapsedMs*: int                 ## ms from assertion start to match (or timeout)
    timedOut*: bool

  SerialStream* = ref object of RootObj
    ## Backend-owned stream interface. The base type is an abstract handle;
    ## each backend constructs its own concrete subtype carrying the
    ## handle/pipe/process state it needs internally. Methods below dispatch
    ## via the owning backend.
    vm*: VmHandle                   ## owning VM (cyclic but safe)
    logPath*: string                ## host-side path of the captured serial log

# ---------------------------------------------------------------------------
# Concept methods. Every backend implements these by inheriting from
# ``VmBackend`` and using ``method ... of <Backend>`` overrides.

method probeAvailability*(b: VmBackend): bool {.base.} =
  ## Cheap capability check: is the underlying CLI installed and usable on
  ## this host? Backends typically check ``findExe`` for their core tool
  ## (``tart``, ``virsh``, ``utmctl``, ``wsl``, ``Get-VM`` via PowerShell).
  ##
  ## Used by ``vm-harness --backend auto`` and ``vm-harness probe``.
  raise newException(CatchableError, "probeAvailability not implemented")

method provisionBaseline*(b: VmBackend, spec: BaselineSpec) {.base.} =
  ## Idempotent: build the baseline image if absent, no-op when already
  ## present. Wall-clock budget: minutes to hours (one-time per baseline).
  raise newException(CatchableError, "provisionBaseline not implemented")

method revertToBaseline*(b: VmBackend, baselineName: string): VmHandle {.base.} =
  ## Fast per-gate reset. Returns a ``VmHandle`` for a started VM ready for
  ## ``execInGuest``. Per-backend wall-clock budgets (the Per-Gate Reset
  ## Performance Contract from M0):
  ##
  ## ====================  ============  =====================================
  ## Backend               Target time   Mechanism
  ## ====================  ============  =====================================
  ## Hyper-V               ≤ 10 s        ``Restore-VMCheckpoint``
  ## libvirt/QEMU          ≤ 10 s        ``virsh snapshot-revert --running``
  ## UTM                   ≤ 20 s        ``utmctl clone`` from local bundle
  ## Tart                  ≤ 30 s        ``tart clone`` from local OCI cache
  ## WSL                   ≤ 20 s        ``wsl --import`` from rootfs tarball
  ## Lima                  ≤ 30 s        ``limactl delete + create + start``
  ## ====================  ============  =====================================
  ##
  ## Budgets are *targets*; miss-by-more-than-50% triggers a regression
  ## flag in ``e2e_vm_harness_per_gate_revert_meets_m0_budget``.
  raise newException(CatchableError, "revertToBaseline not implemented")

method startAndAwaitReady*(b: VmBackend, vm: VmHandle, timeoutSec: int = 120) {.base.} =
  ## Many backends fold start-and-wait into ``revertToBaseline``; this hook
  ## exists for backends that want to expose a separate ready-poll step
  ## (useful when the consumer wants to inspect a stopped clone before
  ## starting it). The default is a no-op for backends that already return
  ## a started VM from ``revertToBaseline``.
  discard

method execInGuest*(b: VmBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult {.base.} =
  raise newException(CatchableError, "execInGuest not implemented")

method copyToGuest*(b: VmBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) {.base.} =
  raise newException(CatchableError, "copyToGuest not implemented")

method copyFromGuest*(b: VmBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) {.base.} =
  raise newException(CatchableError, "copyFromGuest not implemented")

method installArgvTraceShim*(b: VmBackend, vm: VmHandle,
                            shim: ArgvTraceShim) {.base.} =
  ## Replace the named binary in the guest with a wrapper that appends the
  ## invocation argv to ``shim.traceLogPath`` and then exec's the original.
  ## The implementation is backend-specific but the contract is identical
  ## across guest OSes.
  raise newException(CatchableError, "installArgvTraceShim not implemented")

method uninstallArgvTraceShim*(b: VmBackend, vm: VmHandle,
                              wrappedBinaryName: string) {.base.} =
  ## Restore the original binary from its ``.real`` backup. Backends that
  ## treat revert-to-baseline as definitive cleanup can no-op this.
  discard

method stopAndCleanup*(b: VmBackend, vm: VmHandle, deleteVm: bool = true) {.base.} =
  ## Must be safe to call from a ``finally`` block: this method NEVER
  ## raises. Errors are logged and swallowed. Implementations should also
  ## be safe to call multiple times for the same ``VmHandle``.
  discard

# ---------------------------------------------------------------------------
# M30: Snapshot/Restore primitives. These mirror the
# ``snapshot`` / ``restore_snapshot`` / ``list_snapshots`` trait methods on
# the Rust ``ah-vm::VmOrchestrator`` side. The default base implementations
# raise ``BackendUnavailableError`` so backends that lack snapshot support
# remain fully conformant. Each backend that *does* support snapshots (Tart,
# UTM, Lima, libvirt, hyperv, wsl) overrides them.
#
# Snapshot naming convention (matches the Rust port):
#   - Tart/UTM (clone-based)  : `<vm>-snap-<name>`
#   - libvirt (native)        : virsh-managed name
#   - hyperv  (native)        : Restore-VMCheckpoint name
#   - Lima/WSL (record-based) : files in a side directory
# Returned identifiers are opaque strings that ``restoreSnapshot`` accepts.

method snapshot*(b: VmBackend, vmName: string, snapshotName: string): string {.base.} =
  raise newException(BackendUnavailableError,
    "snapshot not implemented for backend " & $b.id)

method restoreSnapshot*(b: VmBackend, vmName: string, snapshotName: string) {.base.} =
  raise newException(BackendUnavailableError,
    "restoreSnapshot not implemented for backend " & $b.id)

method removeSnapshot*(b: VmBackend, vmName, snapshotName: string) {.base.} =
  ## Remove a previously-created snapshot. The symmetric counterpart of
  ## ``snapshot`` / ``snapshotRunning``. Backends that lack a separate
  ## "delete" primitive (clone-based Tart, UTM today) implement this by
  ## removing the named clone.
  ##
  ## Idempotent: removing a missing snapshot is a no-op, not an error.
  ## This is required so test-harness teardown blocks can be safely
  ## re-entered.
  raise newException(BackendUnavailableError,
    "removeSnapshot not implemented for backend " & $b.id)

method snapshotRunning*(b: VmBackend, vmName, snapshotName: string): string {.base.} =
  ## Capture a snapshot of a **running** VM that includes the guest's
  ## RAM + CPU + device state, not just disk state. ``restoreSnapshot``
  ## to such a snapshot resumes the guest from the saved memory image
  ## rather than performing a fresh boot, which on Hyper-V cuts per-revert
  ## wall-clock from 28-46 s down to ~5 s — see
  ## ``docs/per-backend-notes/hyperv-snapshot-benchmarks.md``.
  ##
  ## Backends that lack a memory-state snapshot primitive (the M30
  ## clone-based Tart/UTM implementations, today) raise
  ## ``BackendUnavailableError``. Tart's ``tart suspend`` + ``tart run``
  ## is the planned implementation path (see ``docs/design.md`` running-
  ## state snapshots note); Hyper-V uses ``Checkpoint-VM`` with the VM
  ## in the ``Running`` state and ``CheckpointType = Standard``.
  ##
  ## ``vmName`` must refer to a VM that is currently running. The
  ## returned identifier is the same opaque string ``restoreSnapshot``
  ## accepts, identical in shape to the cold ``snapshot`` return value.
  raise newException(BackendUnavailableError,
    "snapshotRunning not implemented for backend " & $b.id)

method exportBaseline*(b: VmBackend, vmName, destDir: string;
                       baselineName: string = "") {.base.} =
  ## Export a previously-provisioned baseline VM (and its snapshot tree)
  ## to ``destDir`` as a self-contained, transferable artifact. Used by
  ## CI artifact-caching workflows where one "warmer" host pays the
  ## cold-boot cost once and the resulting image is then consumed by
  ## every other runner.
  ##
  ## On backends that store snapshots inside a VM (Hyper-V, libvirt) the
  ## export includes the full snapshot tree. ``baselineName`` is then an
  ## optional sanity-check hint — if non-empty, the export operation
  ## verifies the named snapshot exists before writing. On clone-based
  ## backends (Tart, UTM) the export is the single named clone.
  ##
  ## ``destDir`` may be on the same volume as the VM's storage (in which
  ## case the backend may use reflinks/hardlinks for VHDX or qcow2
  ## content) or on a different volume (in which case a byte copy occurs).
  raise newException(BackendUnavailableError,
    "exportBaseline not implemented for backend " & $b.id)

method importBaseline*(b: VmBackend, srcDir: string): seq[string] {.base.} =
  ## Import a previously-exported baseline bundle into the receiving
  ## backend. Returns the list of baseline / snapshot names now available
  ## via ``revertToBaseline`` and ``restoreSnapshot``.
  ##
  ## The bundle layout is backend-specific (Hyper-V's ``Export-VM``
  ## produces a folder with ``Virtual Machines/*.vmcx``; Tart's clone is
  ## an OCI layer; libvirt uses ``virsh save`` + ``virsh restore``).
  ## ``srcDir`` must contain the layout produced by the *same* backend's
  ## ``exportBaseline`` call — cross-backend portability is out of scope.
  raise newException(BackendUnavailableError,
    "importBaseline not implemented for backend " & $b.id)

method listSnapshots*(b: VmBackend, vmName: string): seq[string] {.base.} =
  raise newException(BackendUnavailableError,
    "listSnapshots not implemented for backend " & $b.id)

# ---------------------------------------------------------------------------
# M1.5 — bootFromMedia + serial-stream primitives. Distinct from the
# baseline-oriented lifecycle (provisionBaseline + revertToBaseline +
# execInGuest): these primitives spin up a transient VM directly around a
# bootable artifact (VHDX/ISO/rootfs tar) and capture serial output during
# OS bring-up. The returned VmHandle must be paired with ``stopAndCleanup``
# in a try/finally; the orchestrator's ``runGate`` does this for the
# consumer.

method bootFromMedia*(b: VmBackend, spec: BootMediaSpec): VmHandle {.base.} =
  ## Boot a transient VM directly from media (VHDX/ISO/rootfs tar). The
  ## returned VmHandle is connected; the guest may still be booting. Call
  ## ``captureSerial`` on the returned handle to drive boot-time assertions
  ## via the SerialStream.
  ##
  ## Distinct from ``revertToBaseline``: no baseline lookup, no
  ## provision step, ephemeral by design. The handle MUST be passed to
  ## ``stopAndCleanup`` when done (the try/finally orchestrator already
  ## does this for the consumer).
  ##
  ## Backends that lack direct-boot support raise BackendUnavailableError.
  raise newException(BackendUnavailableError,
    "bootFromMedia not implemented for backend " & $b.id)

method captureSerial*(b: VmBackend, vm: VmHandle): SerialStream {.base.} =
  ## Open the serial console stream for boot-time pattern assertions. The
  ## backend writes the captured bytes to ``result.logPath`` AND returns
  ## a stream the consumer can ``expectLine`` / ``serialSend`` /
  ## ``captureUntil`` on.
  ##
  ## Pre-condition: ``vm`` was returned by ``bootFromMedia`` (or by a
  ## backend that explicitly documents serial-after-revertToBaseline).
  raise newException(BackendUnavailableError,
    "captureSerial not implemented for backend " & $b.id)

method waitForShutdown*(b: VmBackend, vm: VmHandle,
                        timeoutSec: int): bool {.base.} =
  ## Wait for a guest-initiated clean poweroff. Returns false on timeout or
  ## when the backend can no longer prove the VM reached its normal off state.
  ## This is deliberately separate from stopAndCleanup: installer consumers
  ## must distinguish a completed install from a controller-forced teardown.
  raise newException(BackendUnavailableError,
    "waitForShutdown not implemented for backend " & $b.id)

method captureScreenshot*(b: VmBackend, vm: VmHandle,
                          outputPath: string) {.base.} =
  ## Capture the guest's primary graphical console to ``outputPath``.
  ## Callers must request a graphical console when booting the VM. Backends
  ## should return only after the file exists and is non-empty.
  raise newException(BackendUnavailableError,
    "captureScreenshot not implemented for backend " & $b.id)

method expectLine*(b: VmBackend, stream: SerialStream,
                  pattern: string, timeoutSec: int = 60): SerialMatch {.base.} =
  ## Block until ``pattern`` (Perl-flavoured regex) matches a line in the
  ## serial stream, or ``timeoutSec`` elapses. Returns the match outcome.
  raise newException(BackendUnavailableError,
    "expectLine not implemented for backend " & $b.id)

method serialSend*(b: VmBackend, stream: SerialStream, text: string) {.base.} =
  ## Write ``text`` to the guest's serial input (e.g. a login response).
  ## Newlines must be explicit (caller provides ``\n`` where wanted).
  raise newException(BackendUnavailableError,
    "serialSend not implemented for backend " & $b.id)

method closeSerial*(b: VmBackend, stream: SerialStream) {.base.} =
  ## Close the serial connection. Safe in finally blocks; never raises.
  discard

# ---------------------------------------------------------------------------
# Helpers used by the CLI dispatcher and the docs.

proc selectBackendId*(host: HostPlatform, guest: GuestOs): BackendId =
  ## Backend selection table for ``--backend auto`` per design doc §6.
  ##
  ## ====================  =================  ============================
  ## Host                  Guest              Backend
  ## ====================  =================  ============================
  ## Windows               Windows            hyperv
  ## Windows               Linux              wsl
  ## Linux                 Linux              libvirt
  ## Linux                 Windows            libvirt (QEMU+autounattend)
  ## macOS (Apple Silicon) macOS              tart-macos
  ## macOS (Apple Silicon) Linux              tart-linux-arm
  ## macOS (Apple Silicon) Windows            utm-windows-arm
  ## ====================  =================  ============================
  case host
  of hpWindows:
    case guest
    of goWindows: biHyperv
    of goLinux: biWsl
    of goMacos:
      raise newException(BackendUnavailableError,
        "macOS guests are not supported on Windows hosts (Apple licensing)")
  of hpLinux:
    case guest
    of goLinux: biLibvirt
    of goWindows: biLibvirt
    of goMacos:
      raise newException(BackendUnavailableError,
        "macOS guests are not supported on Linux hosts (Apple licensing)")
  of hpMacosArm:
    case guest
    of goMacos: biTartMacos
    of goLinux: biTartLinuxArm
    of goWindows: biUtmWindowsArm

proc detectHostPlatform*(): HostPlatform =
  ## Runtime probe of the host OS. Returns the ``HostPlatform`` value that
  ## matches ``defined(...)`` at compile time. Compile-time platforms that
  ## are not in the supported set raise ``BackendUnavailableError``.
  when defined(windows):
    hpWindows
  elif defined(linux):
    hpLinux
  elif defined(macosx):
    when defined(arm64) or defined(arm) or defined(aarch64):
      hpMacosArm
    else:
      # x86_64 Macs are unsupported targets for this campaign (Tart needs
      # Apple Virtualization.framework on Apple Silicon).
      hpMacosArm
  else:
    raise newException(BackendUnavailableError,
      "Unsupported host platform for vm-harness")

proc isCleanupSafe*(p: LifecyclePhase): bool =
  ## True for phases where the consumer should always run ``stopAndCleanup``
  ## even if the phase failed. Used by the ``try/finally`` orchestrator to
  ## decide whether a failure should still trigger cleanup.
  p in {lpRevert, lpStartup, lpExec, lpCopy, lpShim}

proc newVmHarnessError*(backend: string, phase: LifecyclePhase,
                       msg: string, cause: ref Exception = nil): ref VmHarnessError =
  result = newException(VmHarnessError, msg)
  result.backend = backend
  result.phase = phase
  result.cause = cause
