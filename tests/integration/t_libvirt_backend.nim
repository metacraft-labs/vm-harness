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
  test "newLibvirtBackend populates defaults consistent with high-mem-server":
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

  test "domainDiskPath uses the configured image pool (default + override)":
    # Default backend: disk lands under /var/lib/libvirt/images.
    let bDefault = newLibvirtBackend()
    check bDefault.imagePoolDir == DefaultLibvirtImagePool
    check bDefault.domainDiskPath("windows-runner-001") ==
      DefaultLibvirtImagePool / "windows-runner-001.qcow2"
    # Operator override: storage lives on a big ZFS pool at /storage.
    let bOverride = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    check bOverride.imagePoolDir == "/storage/libvirt"
    check bOverride.domainDiskPath("windows-runner-001") ==
      "/storage/libvirt/windows-runner-001.qcow2"

  test "buildVirtInstallArgs writes the disk at the overridden pool dir":
    # The disk path virt-install receives is computed by domainDiskPath,
    # so an --image-pool-dir override must surface in the --disk argv.
    let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    let diskPath = b.domainDiskPath("windows-runner-001")
    let argv = buildVirtInstallArgs(b,
      name = "windows-runner-001",
      diskPath = diskPath,
      diskGB = 80, memoryMB = 8192, vcpus = 4,
      isoPath = "/storage/iso/Win11.iso",
      unattendIsoPath = "/tmp/autounattend.iso",
      virtioWinIsoPath = "/tmp/virtio-win.iso",
      osVariant = "win11")
    var diskArg = ""
    for a in argv:
      if a.startsWith("path=/storage/libvirt/windows-runner-001.qcow2"):
        diskArg = a
    check diskArg.len > 0
    check diskArg.contains("format=qcow2")
    # And the default pool path must NOT appear anywhere in the argv.
    check not argv.anyIt(it.contains(DefaultLibvirtImagePool))

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
    # ``--boot`` is followed by a SINGLE combined value element
    # (``uefi,firmware.feature0...``), so a bare exact-element
    # ``"uefi" in argv`` never matches. Assert UEFI is actually
    # requested by checking the --boot value begins with ``uefi,``.
    let bootIdx = argv.find("--boot")
    check bootIdx >= 0 and bootIdx + 1 < argv.len
    check argv[bootIdx + 1].startsWith("uefi,")
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

  # ---- M3: config-drive injection + UEFI ephemeral domain rendering ----

  test "buildEphemeralDomainXml attaches the config-drive CD-ROM + NIC " &
       "for a firmware (Windows) golden":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m3-eph",
      goldenImage: "/storage/iso/golden-win11-cloudbase.qcow2",
      cpus: 4, memoryMB: 4096,
      configDriveIso: "/var/lib/libvirt/images/m3-eph.config-drive.iso")
    let xml = b.buildEphemeralDomainXml(spec,
      "/var/lib/libvirt/images/m3-eph.overlay.qcow2",
      "/tmp/m3-eph.serial.log")
    # The overlay disk is the boot disk.
    check "m3-eph.overlay.qcow2" in xml
    # The config-drive is attached read-only as a CD-ROM (cloudbase-init
    # ConfigDrive datasource consumes it).
    check "device='cdrom'" in xml
    check "m3-eph.config-drive.iso" in xml
    check "<readonly/>" in xml
    # A firmware-boot golden gets a NIC so cloudbase-init can reach the
    # metadata endpoint.
    check "<interface type='network'>" in xml
    # No direct-kernel boot for a firmware golden.
    check "<kernel>" notin xml
    check "<boot dev='hd'/>" in xml

  test "buildEphemeralDomainXml renders UEFI (OVMF) loader + per-job nvram":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m3-uefi",
      goldenImage: "/storage/iso/golden-win11-cloudbase.qcow2",
      uefiLoader: "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd",
      uefiNvramTemplate: "/run/libvirt/nix-ovmf/edk2-i386-vars.fd",
      uefiNvram: "/var/lib/libvirt/images/m3-uefi_VARS.fd")
    let xml = b.buildEphemeralDomainXml(spec,
      "/var/lib/libvirt/images/m3-uefi.overlay.qcow2",
      "/tmp/m3-uefi.serial.log")
    check "edk2-x86_64-code.fd" in xml
    check "<loader" in xml and "pflash" in xml
    check "m3-uefi_VARS.fd" in xml
    check "template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'" in xml
    # Windows on UEFI needs SMM.
    check "<smm state='on'/>" in xml

  test "the tiny-Linux (direct-kernel) ephemeral path is unchanged (no NIC/" &
       "config-drive/UEFI)":
    let b = newLibvirtBackend()
    let spec = EphemeralCloneSpec(
      name: "m2-tiny",
      goldenImage: "/tmp/golden.qcow2",
      kernel: "/tmp/kernel", initrd: "/tmp/initramfs.gz",
      cmdline: "console=ttyS0 quiet panic=1")
    let xml = b.buildEphemeralDomainXml(spec,
      "/tmp/m2-tiny.overlay.qcow2", "/tmp/m2-tiny.serial.log")
    check "<kernel>/tmp/kernel</kernel>" in xml
    # M2 tiny golden self-terminates without networking; no NIC is added.
    check "<interface" notin xml
    check "device='cdrom'" notin xml
    check "<loader" notin xml

  test "buildConfigDriveIso writes the openstack config-drive layout + " &
       "labels it config-2 (when an ISO tool is available)":
    if findExe("genisoimage").len == 0 and findExe("mkisofs").len == 0 and
       findExe("xorriso").len == 0:
      echo "[skip] no genisoimage/mkisofs/xorriso on PATH"
      skip()
    else:
      let iso = getTempDir() / "m3-configdrive-unit.iso"
      removeFile(iso)
      let ud = "#ps1_sysnative\nWrite-Output HELLO-M3\n"
      let meta = "{\"uuid\":\"unit-test\",\"hostname\":\"unit-test\"}"
      let got = buildConfigDriveIso(iso, ud, meta)
      check got == iso
      check fileExists(iso)
      # The ISO must carry the config-2 volume label + the user_data. We
      # grep the raw ISO bytes for the volume id + payload marker.
      let raw = readFile(iso)
      check "config-2" in raw
      check "HELLO-M3" in raw
      check "user_data" in raw
      removeFile(iso)
