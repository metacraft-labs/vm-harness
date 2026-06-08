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
    snapshots*: Table[string, seq[string]] ## vm-name -> snapshot names (M30)

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
    shims: initTable[string, string](),
    snapshots: initTable[string, seq[string]]())

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

# ---------------------------------------------------------------------------
# M30: in-memory snapshot store. Useful for CLI-dispatch and orchestrator
# tests that exercise the snapshot subcommand without a real hypervisor.

method snapshot*(b: NoopBackend, vmName: string, snapshotName: string): string =
  b.calls.add("snapshot:" & vmName & ":" & snapshotName)
  if not b.snapshots.hasKey(vmName):
    b.snapshots[vmName] = @[]
  if snapshotName in b.snapshots[vmName]:
    raise newVmHarnessError($b.id, lpProvisioning,
      "snapshot '" & snapshotName & "' already exists for VM '" & vmName & "'")
  b.snapshots[vmName].add(snapshotName)
  snapshotName

method restoreSnapshot*(b: NoopBackend, vmName: string, snapshotName: string) =
  b.calls.add("restoreSnapshot:" & vmName & ":" & snapshotName)
  if not b.snapshots.hasKey(vmName) or snapshotName notin b.snapshots[vmName]:
    raise newVmHarnessError($b.id, lpRevert,
      "snapshot '" & snapshotName & "' not found for VM '" & vmName & "'")

method listSnapshots*(b: NoopBackend, vmName: string): seq[string] =
  b.calls.add("listSnapshots:" & vmName)
  if b.snapshots.hasKey(vmName): b.snapshots[vmName] else: @[]

method snapshotRunning*(b: NoopBackend, vmName, snapshotName: string): string =
  ## NoopBackend has no actual VM state to capture, so the running-state
  ## variant behaves identically to `snapshot` from the test's point of
  ## view. The call is tagged separately so tests can verify the
  ## orchestrator dispatched to the correct method.
  b.calls.add("snapshotRunning:" & vmName & ":" & snapshotName)
  if not b.snapshots.hasKey(vmName):
    b.snapshots[vmName] = @[]
  if snapshotName in b.snapshots[vmName]:
    raise newVmHarnessError($b.id, lpProvisioning,
      "snapshot '" & snapshotName & "' already exists for VM '" & vmName & "'")
  b.snapshots[vmName].add(snapshotName)
  snapshotName

method exportBaseline*(b: NoopBackend, vmName, destDir: string;
                       baselineName: string = "") =
  ## In-memory export: write a one-line manifest into ``destDir`` with the
  ## VM name and recorded snapshot list so an in-process import can
  ## restore the state. Real backends produce binary blobs; this is just
  ## enough fidelity to round-trip the test's expectations.
  b.calls.add("exportBaseline:" & vmName & ":" & destDir & ":" & baselineName)
  if baselineName.len > 0:
    let existing = if b.snapshots.hasKey(vmName): b.snapshots[vmName] else: @[]
    if baselineName notin existing:
      raise newVmHarnessError($b.id, lpProvisioning,
        "exportBaseline: baseline '" & baselineName &
        "' not found on VM '" & vmName & "'")
  createDir(destDir)
  let snaps =
    if b.snapshots.hasKey(vmName): b.snapshots[vmName].join(",")
    else: ""
  writeFile(destDir / "noop-baseline.manifest",
            "vm=" & vmName & "\nsnapshots=" & snaps & "\n")

method importBaseline*(b: NoopBackend, srcDir: string): seq[string] =
  ## Read the manifest written by ``exportBaseline`` and register the
  ## snapshot list against the imported VM name. Returns the imported
  ## snapshot names so callers can assert round-trip fidelity.
  b.calls.add("importBaseline:" & srcDir)
  let manifest = srcDir / "noop-baseline.manifest"
  if not fileExists(manifest):
    raise newVmHarnessError($b.id, lpProvisioning,
      "importBaseline: manifest not found at " & manifest)
  var vm = ""
  var snaps: seq[string] = @[]
  for line in readFile(manifest).splitLines():
    if line.startsWith("vm="):
      vm = line["vm=".len .. ^1]
    elif line.startsWith("snapshots="):
      let rest = line["snapshots=".len .. ^1]
      if rest.len > 0:
        for s in rest.split(","):
          if s.len > 0: snaps.add(s)
  if vm.len == 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "importBaseline: malformed manifest (no 'vm=' line) at " & manifest)
  b.snapshots[vm] = snaps
  result = snaps
