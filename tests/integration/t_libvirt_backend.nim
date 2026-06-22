## Integration test (no-live-virsh) for LibvirtBackend.
##
## Verifies the M4 Phase A slice's compile + boilerplate-correctness
## contract WITHOUT booting a real VM and WITHOUT requiring libvirtd
## to be running. The full live-virsh lifecycle test will land with
## M4 Phase B (snapshots) once a CI host with KVM is wired up.
##
## What this asserts:
##
##  - The libvirt module compiles into the vm-harness library on any
##    host (Linux/macOS/Windows).
##  - ``newLibvirtBackend()`` returns a populated backend with
##    sensible defaults.
##  - ``probeAvailability`` returns false (no libvirtd connection +
##    fake virsh path).
##  - ``stopAndCleanup`` on a fake VmHandle never raises (the
##    finally-safety contract).
##  - ``buildVirtInstallArgs`` produces a stable argv shape — pure
##    function, tested by string-match.
##  - Snapshot/export methods raise ``BackendUnavailableError`` with
##    the documented "M4 Phase B" sentinel string so callers
##    debugging the unimplemented surface get a clear signpost.
##  - The backend is registered with the auto-selection factory.

import std/[options, os, sequtils, strutils, tables, unittest]
import vm_harness

suite "LibvirtBackend smoke (no live virsh)":
  test "newLibvirtBackend populates defaults consistent with solunska-server":
    let b = newLibvirtBackend()
    check b.id == biLibvirt
    check b.hostPlatform == hpLinux
    check goWindows in b.supportedGuests
    check goLinux in b.supportedGuests
    check b.libvirtUri == DefaultLibvirtUri
    check b.networkBridge == DefaultLibvirtBridge
    check b.imagePoolDir == DefaultLibvirtImagePool
    check b.sshUser == DefaultLibvirtWindowsSshUser

  test "probeAvailability returns false when virsh path is bogus":
    # Use a non-existent binary so the probe definitely returns false
    # even on a host with libvirt installed.
    let b = newLibvirtBackend(virshCmd = "/nonexistent/virsh-no-such")
    check not b.probeAvailability()

  test "buildVirtInstallArgs renders an argv with the expected key flags":
    let b = newLibvirtBackend(networkBridge = "br0",
                              libvirtUri = "qemu:///system")
    let argv = buildVirtInstallArgs(b,
      name = "windows-runner-001",
      diskPath = "/var/lib/libvirt/images/windows-runner-001.qcow2",
      diskGB = 80,
      memoryMB = 8192,
      vcpus = 4,
      isoPath = "/storage/iso/Win11_24H2_EnglishInternational_x64.iso",
      unattendIsoPath = "/tmp/autounattend.iso",
      virtioWinIsoPath = "/tmp/virtio-win.iso",
      osVariant = "win11")
    # Argv[0] is the binary.
    check argv[0].endsWith("virt-install")
    # Connection URI is threaded through.
    check "qemu:///system" in argv
    # Required Win11 flags.
    check "--osinfo" in argv
    check "win11" in argv
    check "--machine" in argv
    check "q35" in argv
    check "--boot" in argv
    check "uefi" in argv
    # Bridge override survives.
    let networkSpec = argv.filterIt(it.startsWith("bridge=br0"))
    check networkSpec.len == 1
    # Both companion ISOs are present.
    check argv.filterIt("virtio-win.iso" in it).len >= 1
    check argv.filterIt("autounattend.iso" in it).len >= 1

  test "stopAndCleanup on a fake handle never raises":
    let b = newLibvirtBackend(virshCmd = "/nonexistent/virsh-no-such")
    let vm = VmHandle(
      backend: b,
      name: "never-existed",
      baseline: "never-existed",
      ipAddress: none(string),
      sshPort: 0,
      sshUser: "",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    # Must not raise — finally-safety contract.
    b.stopAndCleanup(vm, deleteVm = true)
    b.stopAndCleanup(vm, deleteVm = false)
    # And calling it twice in a row also must not raise.
    b.stopAndCleanup(vm, deleteVm = true)

  test "snapshot surface raises BackendUnavailableError with M4 Phase B sentinel":
    let b = newLibvirtBackend()
    expect BackendUnavailableError:
      discard b.snapshot("any", "any")
    expect BackendUnavailableError:
      discard b.snapshotRunning("any", "any")
    expect BackendUnavailableError:
      b.restoreSnapshot("any", "any")
    expect BackendUnavailableError:
      discard b.listSnapshots("any")
    expect BackendUnavailableError:
      b.removeSnapshot("any", "any")
    expect BackendUnavailableError:
      b.exportBaseline("any", "/tmp/x")
    expect BackendUnavailableError:
      discard b.importBaseline("/tmp/x")
    # The error message should make the deferred-to-Phase-B intent obvious.
    try:
      discard b.snapshot("any", "any")
    except BackendUnavailableError as e:
      check "Phase B" in e.msg

  test "bootFromMedia rejects rootfs-tar (WSL-only) cleanly":
    let b = newLibvirtBackend()
    expect BackendUnavailableError:
      discard b.bootFromMedia(BootMediaSpec(
        name: "repro-test-boot-libvirt-x",
        kind: bmkRootfsTar,
        mediaPath: "/tmp/never.tar"))

  test "bootFromMedia rejects an unprefixed name":
    let b = newLibvirtBackend()
    when defined(linux):
      # On Linux the call will try to do real work; we only verify it
      # rejects the safety-prefix violation before any subprocess call.
      # The test fixture uses a non-existent media path so the fileExists
      # check fires first and the name validation order means we still
      # get the IOError instead. To test the prefix check we need a
      # fake-existing file: use the test binary itself.
      let tmpExisting = getAppFilename()
      expect ValueError:
        discard b.bootFromMedia(BootMediaSpec(
          name: "bad-name-no-prefix",
          kind: bmkQcow2,
          mediaPath: tmpExisting))
    else:
      # On non-Linux hosts the method raises BackendUnavailableError
      # before any input validation, so the prefix check isn't reached.
      expect BackendUnavailableError:
        discard b.bootFromMedia(BootMediaSpec(
          name: "bad-name-no-prefix",
          kind: bmkQcow2,
          mediaPath: "/tmp/never.qcow2"))

  test "installArgvTraceShim raises a clear M4 Phase B error":
    let b = newLibvirtBackend()
    let vm = VmHandle(
      backend: b, name: "x", baseline: "x",
      ipAddress: some("127.0.0.1"), sshPort: 22, sshUser: "admin",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    expect BackendUnavailableError:
      b.installArgvTraceShim(vm, ArgvTraceShim(
        wrappedBinaryName: "useradd",
        traceLogPath: "C:\\trace.log"))

  test "uninstallArgvTraceShim is a no-op (Phase A)":
    let b = newLibvirtBackend()
    let vm = VmHandle(
      backend: b, name: "x", baseline: "x",
      ipAddress: some("127.0.0.1"), sshPort: 22, sshUser: "admin",
      sshAuth: SshAuth(kind: saNone),
      extra: initTable[string, string]())
    b.uninstallArgvTraceShim(vm, "useradd")  # must not raise

  test "biLibvirt is registered with the auto-selection factory":
    check biLibvirt in registeredBackends()
    # And the (linux, windows) dispatch picks libvirt.
    check autoSelectBackendId(hpLinux, goWindows) == biLibvirt
    check autoSelectBackendId(hpLinux, goLinux) == biLibvirt
