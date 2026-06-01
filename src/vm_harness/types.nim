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
    biLibvirt = "libvirt"
    biLima = "lima"

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

method listSnapshots*(b: VmBackend, vmName: string): seq[string] {.base.} =
  raise newException(BackendUnavailableError,
    "listSnapshots not implemented for backend " & $b.id)

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
