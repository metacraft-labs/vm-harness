## NoopBackend — the one allowed mock per the test methodology in design
## doc §9.1.
##
## This backend implements the ``VmBackend`` concept but performs no real
## VM operations. It exists solely to verify the harness *scaffolding*
## (CLI dispatch, output envelope, ``try/finally`` orchestration, auto-
## selection) without requiring a real hypervisor.
##
## Tests that use ``NoopBackend`` must make clear they are testing the
## harness, not backend behavior — see ``e2e_vm_harness_smoke``,
## ``e2e_vm_harness_finally_cleanup_on_panic``,
## ``e2e_vm_harness_auto_backend_selection``.

import std/[options, os, sequtils, strutils, tables, times]
import ../types

type
  NoopBackend* = ref object of VmBackend
    ## Records every lifecycle call for assertions. The ``rootDir`` is a
    ## writable directory the backend can use to simulate the guest
    ## filesystem (``copyToGuest`` writes into ``rootDir / guest-fs``).
    rootDir*: string
    calls*: seq[string]            ## chronological method-name log
    execHandler*: proc(cmd: seq[string]): ExecResult {.gcsafe.}
    available*: bool
    provisioned*: seq[string]
    activeVms*: seq[string]
    cleanedVms*: seq[string]
    shims*: Table[string, string]  ## binary name -> trace log path

proc newNoopBackend*(rootDir: string = ""): NoopBackend =
  ## Construct a fresh NoopBackend. If ``rootDir`` is empty a temp dir is
  ## created so the test fixture is self-contained.
  let dir = if rootDir.len == 0:
              getTempDir() / "vm-harness-noop-" & $epochTime()
            else:
              rootDir
  createDir(dir)
  createDir(dir / "guest-fs")
  result = NoopBackend(
    id: biNoop,
    hostPlatform: detectHostPlatform(),
    supportedGuests: {goLinux, goWindows, goMacos},
    rootDir: dir,
    calls: @[],
    available: true,
    shims: initTable[string, string]())

method probeAvailability*(b: NoopBackend): bool =
  b.calls.add("probeAvailability")
  b.available

method provisionBaseline*(b: NoopBackend, spec: BaselineSpec) =
  b.calls.add("provisionBaseline:" & spec.name)
  if spec.name notin b.provisioned:
    b.provisioned.add(spec.name)
    createDir(b.rootDir / "baselines" / spec.name)

method revertToBaseline*(b: NoopBackend, baselineName: string): VmHandle =
  b.calls.add("revertToBaseline:" & baselineName)
  if baselineName notin b.provisioned:
    raise newVmHarnessError($b.id, lpRevert,
      "Baseline '" & baselineName & "' was never provisioned")
  let vmName = "noop-vm-" & $epochTime()
  let vmDir = b.rootDir / "vms" / vmName
  createDir(vmDir)
  b.activeVms.add(vmName)
  result = VmHandle(
    backend: b,
    name: vmName,
    baseline: baselineName,
    ipAddress: some("127.0.0.1"),
    sshPort: 22,
    sshUser: "noop",
    sshAuth: SshAuth(kind: saNone),
    extra: {"root": vmDir}.toTable)

method execInGuest*(b: NoopBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  b.calls.add("execInGuest:" & cmd.join(" "))
  if b.execHandler != nil:
    return b.execHandler(cmd)
  ExecResult(
    exitCode: 0,
    stdout: "noop:" & cmd.join(" ") & "\n",
    stderr: "",
    elapsedMs: 1)

method copyToGuest*(b: NoopBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  b.calls.add("copyToGuest:" & hostPath & "->" & guestPath)
  let dest = b.rootDir / "guest-fs" / guestPath.strip(leading = true, chars = {'/'})
  createDir(parentDir(dest))
  if fileExists(hostPath):
    copyFile(hostPath, dest)
  elif dirExists(hostPath):
    copyDir(hostPath, dest)
  else:
    raise newVmHarnessError($b.id, lpCopy,
      "Source path not found: " & hostPath)

method copyFromGuest*(b: NoopBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  b.calls.add("copyFromGuest:" & guestPath & "->" & hostPath)
  let src = b.rootDir / "guest-fs" / guestPath.strip(leading = true, chars = {'/'})
  if not fileExists(src) and not dirExists(src):
    raise newVmHarnessError($b.id, lpCopy,
      "Guest path not found: " & guestPath)
  createDir(parentDir(hostPath))
  if fileExists(src):
    copyFile(src, hostPath)
  else:
    copyDir(src, hostPath)

method installArgvTraceShim*(b: NoopBackend, vm: VmHandle, shim: ArgvTraceShim) =
  b.calls.add("installArgvTraceShim:" & shim.wrappedBinaryName)
  b.shims[shim.wrappedBinaryName] = shim.traceLogPath
  let logFs = b.rootDir / "guest-fs" /
              shim.traceLogPath.strip(leading = true, chars = {'/'})
  createDir(parentDir(logFs))
  writeFile(logFs, "")

method uninstallArgvTraceShim*(b: NoopBackend, vm: VmHandle,
                              wrappedBinaryName: string) =
  b.calls.add("uninstallArgvTraceShim:" & wrappedBinaryName)
  b.shims.del(wrappedBinaryName)

method stopAndCleanup*(b: NoopBackend, vm: VmHandle, deleteVm: bool = true) =
  ## Per the design contract this method NEVER raises.
  try:
    b.calls.add("stopAndCleanup:" & vm.name & (if deleteVm: ":delete" else: ""))
    if deleteVm:
      b.activeVms.keepItIf(it != vm.name)
      b.cleanedVms.add(vm.name)
      let vmDir = b.rootDir / "vms" / vm.name
      if dirExists(vmDir):
        removeDir(vmDir)
  except CatchableError:
    discard
