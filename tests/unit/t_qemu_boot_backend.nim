## Pure/unit tests for the direct-QEMU boot backend (``qemu_boot.nim``).
##
## These do not boot QEMU. They assert the argument vector, the firmware
## pairing rules, the name-prefix guard that makes a stale-process sweep
## possible, and the shell quoting of the stdout/stderr redirection
## wrapper — i.e. everything the live boot gates depend on being right
## before a guest ever runs.
##
## The live end of the contract (a guest really boots, the expect engine
## really matches, teardown really removes everything) is covered by
## ``tests/integration/t_boot_smoke_harness_fails_on_missing_line.nim``
## and ``tests/integration/t_boot_smoke_harness_tears_down_on_failure.nim``,
## which drive a synthetic guest under a real QEMU.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

when defined(posix):
  import std/[net, posix]

proc idx(args: seq[string], needle: string): int =
  result = -1
  for i, a in args:
    if a == needle:
      return i

proc valueAfter(args: seq[string], flag: string): string =
  let i = idx(args, flag)
  if i < 0 or i + 1 >= args.len:
    return ""
  args[i + 1]

proc baseLaunch(): QemuBootLaunch =
  QemuBootLaunch(
    vmName: "repro-test-boot-qemu-1-abc",
    diskPath: "/tmp/overlay.qcow2",
    diskFormat: "qcow2",
    serialSocketPath: "/tmp/vmh-qb-1.sock",
    serialLogPath: "/tmp/artifacts/serial.log",
    qemuLogPath: "/tmp/run/qemu-trace.log",
    cpus: 2,
    memoryMB: 1024,
    accel: baTcg)

when defined(posix):
  proc cleanupHandle(b: QemuBootBackend, name: string): VmHandle =
    let runDir = b.runDirFor(name)
    let socketDir = b.serialSocketPathFor(name).parentDir
    result = VmHandle(backend: b, name: name,
      extra: {"runDir": runDir, "socketDir": socketDir,
              "serialSocketPath": socketDir / "serial.sock",
              "tpmSocketPath": socketDir / "tpm.sock"}.toTable)
    for key in ["runDir", "socketDir"]:
      let id = getFileInfo(result.extra[key], followSymlink = false).id
      result.extra[key & "Identity"] = $id.device & ":" & $id.file

suite "qemu_boot argv":
  test "carries the VM name, a serial chardev with a durable logfile and no network":
    let args = buildQemuBootArgs(baseLaunch())
    check valueAfter(args, "-name") == "repro-test-boot-qemu-1-abc"
    check valueAfter(args, "-machine") == "q35"
    check valueAfter(args, "-m") == "1024"
    check valueAfter(args, "-smp") == "2"
    check valueAfter(args, "-display") == "none"
    check idx(args, "-no-reboot") >= 0
    let chardev = valueAfter(args, "-chardev")
    check chardev.startsWith("socket,id=serial0,")
    check "path=/tmp/vmh-qb-1.sock" in chardev
    check "server=on,wait=off" in chardev
    check "logfile=/tmp/artifacts/serial.log" in chardev
    check valueAfter(args, "-serial") == "chardev:serial0"
    check valueAfter(args, "-nic") == "none"
    check valueAfter(args, "-D") == "/tmp/run/qemu-trace.log"

  test "legacy-BIOS launches carry no pflash drives":
    let args = buildQemuBootArgs(baseLaunch())
    for a in args:
      check "if=pflash" notin a

  test "UEFI launches pass a read-only loader and a writable vars copy":
    var l = baseLaunch()
    l.ovmfCode = "/nix/store/x-OVMF-fd/FV/OVMF_CODE.fd"
    l.ovmfVars = "/run/vm/OVMF_VARS.fd"
    let args = buildQemuBootArgs(l)
    var sawCode = false
    var sawVars = false
    for a in args:
      if a == "if=pflash,format=raw,readonly=on,file=" & l.ovmfCode:
        sawCode = true
      if a == "if=pflash,format=raw,file=" & l.ovmfVars:
        sawVars = true
    check sawCode
    check sawVars

  test "a half-specified firmware pair is rejected rather than silently ignored":
    var l = baseLaunch()
    l.ovmfCode = "/nix/store/x-OVMF-fd/FV/OVMF_CODE.fd"
    expect ValueError:
      discard buildQemuBootArgs(l)
    l.ovmfCode = ""
    l.ovmfVars = "/run/vm/OVMF_VARS.fd"
    expect ValueError:
      discard buildQemuBootArgs(l)

  test "TCG never inherits the host CPU model; KVM does":
    var l = baseLaunch()
    l.accel = baTcg
    let tcg = buildQemuBootArgs(l)
    check valueAfter(tcg, "-accel") == "tcg"
    check valueAfter(tcg, "-cpu") == "qemu64"
    l.accel = baKvm
    let kvm = buildQemuBootArgs(l)
    check valueAfter(kvm, "-accel") == "kvm"
    check valueAfter(kvm, "-cpu") == "host"

  test "an SSH forward replaces the isolated NIC":
    var l = baseLaunch()
    l.sshForwardPort = 2222
    let args = buildQemuBootArgs(l)
    check idx(args, "-nic") < 0
    check valueAfter(args, "-netdev") ==
      "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22"
    l.sshForwardPort = 70000
    expect ValueError:
      discard buildQemuBootArgs(l)

  test "a launch with neither a disk nor a cdrom is rejected":
    var l = baseLaunch()
    l.diskPath = ""
    expect ValueError:
      discard buildQemuBootArgs(l)

  test "an ISO launch attaches the cdrom":
    var l = baseLaunch()
    l.diskPath = ""
    l.cdromPath = "/images/install.iso"
    let args = buildQemuBootArgs(l)
    check valueAfter(args, "-cdrom") == "/images/install.iso"

suite "qemu_boot process wrapper":
  test "the redirection wrapper execs qemu so the child pid is qemu's":
    let cmd = qemuBootShellCommand("qemu-system-x86_64",
                                   @["-name", "vm-1"], "/tmp/run/stdio.log")
    check cmd.startsWith("exec 'qemu-system-x86_64' '-name' 'vm-1'")
    check cmd.endsWith(">'/tmp/run/stdio.log' 2>&1")

  test "single quotes in a path cannot break out of the wrapper":
    check shQuote("a'b") == "'a'\\''b'"
    let cmd = qemuBootShellCommand("qemu", @["-name", "a'b"], "/tmp/o")
    check "'a'\\''b'" in cmd

  test "auto acceleration always resolves to a concrete mode":
    check resolveQemuAccel(baAuto) in {baKvm, baTcg}
    check resolveQemuAccel(baTcg) == baTcg
    check resolveQemuAccel(baKvm) == baKvm

suite "qemu_boot naming":
  test "generated names carry the configured prefix and this process id":
    let name = newQemuBootVmName("reproos-att-a1-")
    check name.startsWith("reproos-att-a1-")
    check ("-" & $getCurrentProcessId() & "-") in ("-" & name[15 .. ^1])

  test "a name outside the backend prefix is refused":
    let dir = createTempDir("vmh-qemu-boot-unit-", "")
    defer: removeDir(dir)
    let media = dir / "disk.qcow2"
    writeFile(media, "not-a-real-image")
    let b = newQemuBootBackend(stateDir = dir / "state",
                               namePrefix = "reproos-att-a1-")
    var spec = BootMediaSpec(
      name: "some-other-vm",
      kind: bmkQcow2,
      mediaPath: media,
      generation: 1,
      acceleration: baTcg,
      extra: initTable[string, string]())
    expect ValueError:
      discard b.bootFromMedia(spec)
    # And nothing was left behind by the refusal.
    check not dirExists(dir / "state" / "some-other-vm")

  test "an empty prefix is refused at construction":
    expect ValueError:
      discard newQemuBootBackend(namePrefix = "")

when defined(posix):
  suite "qemu_boot socket ownership and byte limits":
    var oldTemp, oldRuntime, root: string
    var hadTemp, hadRuntime: bool
    setup:
      oldTemp = getEnv("TMPDIR")
      hadTemp = existsEnv("TMPDIR")
      oldRuntime = getEnv("XDG_RUNTIME_DIR")
      hadRuntime = existsEnv("XDG_RUNTIME_DIR")
      root = createTempDir("", "", getEnv("XDG_RUNTIME_DIR", "/tmp"))
      setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
      putEnv("XDG_RUNTIME_DIR", root)
      let longTemp = root / repeat("deep-temp-", 16)
      createDir(longTemp)
      putEnv("TMPDIR", longTemp)
      let b = newQemuBootBackend(stateDir = root / "state")
      let name = QemuBootNamePrefix & "socket-unit"
      let limit = sizeof(default(Sockaddr_un).sun_path) - 1

    teardown:
      if hadTemp: putEnv("TMPDIR", oldTemp)
      else: delEnv("TMPDIR")
      if hadRuntime: putEnv("XDG_RUNTIME_DIR", oldRuntime)
      else: delEnv("XDG_RUNTIME_DIR")
      removeDir(root)

    test "both socket paths fit under deep TMPDIR and isolate runs and state roots":
      let serial = b.serialSocketPathFor(name)
      let tpm = b.tpmSocketPathFor(name)
      check serial.len <= limit
      check tpm.len <= limit
      check serial != tpm
      check serial.parentDir == tpm.parentDir
      check serial.startsWith(root / "")
      check not serial.startsWith(longTemp / "")
      check serial == b.serialSocketPathFor(name)
      check tpm == b.tpmSocketPathFor(name)
      let other = newQemuBootBackend(stateDir = root / "other-state")
      check serial != b.serialSocketPathFor(name & "-other")
      check tpm != b.tpmSocketPathFor(name & "-other")
      check serial != other.serialSocketPathFor(name)
      check tpm != other.tpmSocketPathFor(name)

    test "the kernel accepts both socket paths under deep TMPDIR":
      let serial = b.serialSocketPathFor(name)
      let tpm = b.tpmSocketPathFor(name)
      createDir(serial.parentDir)
      setFilePermissions(serial.parentDir, {fpUserRead, fpUserWrite, fpUserExec})
      let serialSocket = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                                   Protocol.IPPROTO_IP)
      defer: serialSocket.close()
      let tpmSocket = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                                Protocol.IPPROTO_IP)
      defer: tpmSocket.close()
      serialSocket.bindUnix(serial)
      tpmSocket.bindUnix(tpm)
      check pathExists(serial)
      check pathExists(tpm)

    test "the longest socket path reserves the terminating NUL at the boundary":
      putEnv("TMPDIR", "/")
      let suffixLen = max(b.serialSocketPathFor(name).len,
                          b.tpmSocketPathFor(name).len)
      for delta in [-1, 0, 1]:
        let temp = "/" & repeat("t", limit - suffixLen - 1 + delta)
        putEnv("TMPDIR", temp)
        let serial = b.serialSocketPathFor(name)
        let tpm = b.tpmSocketPathFor(name)
        check serial.len <= limit
        check tpm.len <= limit
        if delta <= 0:
          check serial.startsWith(temp / "")
          check tpm.startsWith(temp / "")
        else:
          check not serial.startsWith(temp / "")
          check not tpm.startsWith(temp / "")
      # UTF-8 is measured in bytes, not code points.
      putEnv("TMPDIR", "/" & repeat("\xC3\xA9", limit))
      check b.serialSocketPathFor(name).len <= limit
      check b.tpmSocketPathFor(name).len <= limit

    test "unsafe or symlinked runtime directories are not used for fallback":
      setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec,
                                fpGroupWrite, fpOthersWrite})
      check b.serialSocketPathFor(name).startsWith("/tmp/")
      check b.tpmSocketPathFor(name).startsWith("/tmp/")
      setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec})
      let link = root / "l"
      createSymlink(root, link)
      putEnv("XDG_RUNTIME_DIR", link)
      check b.serialSocketPathFor(name).startsWith("/tmp/")
      check b.tpmSocketPathFor(name).startsWith("/tmp/")
      delEnv("XDG_RUNTIME_DIR")
      check b.serialSocketPathFor(name).startsWith("/tmp/")
      check b.tpmSocketPathFor(name).startsWith("/tmp/")

    test "unsafe or symlinked state roots are refused without writing into them":
      createDir(b.stateDir)
      setFilePermissions(b.stateDir, {fpUserRead, fpUserWrite, fpUserExec,
                                     fpGroupWrite, fpOthersWrite})
      let media = root / "kernel"
      writeFile(media, "not a kernel")
      let spec = BootMediaSpec(name: name, kind: bmkKernel,
                              mediaPath: media, generation: 3)
      expect IOError:
        discard b.bootFromMedia(spec)
      check not dirExists(b.runDirFor(name))
      removeDir(b.stateDir)
      let target = root / "state-target"
      createDir(target)
      createSymlink(target, b.stateDir)
      expect IOError:
        discard b.bootFromMedia(spec)
      check symlinkExists(b.stateDir)
      check not dirExists(target / name)

    test "a setup failure removes only the directories it claimed":
      let media = root / "kernel"
      writeFile(media, "not a kernel")
      expect ValueError:
        discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkKernel,
          mediaPath: media, generation: 3))
      check not dirExists(b.runDirFor(name))
      check not pathExists(b.serialSocketPathFor(name).parentDir)

    test "a newly claimed state root is private even with a permissive umask":
      let oldMask = posix.umask(Mode(0))
      defer: discard posix.umask(oldMask)
      let media = root / "kernel"
      writeFile(media, "not a kernel")
      expect ValueError:
        discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkKernel,
          mediaPath: media, generation: 3))
      check getFilePermissions(b.stateDir) == {fpUserRead, fpUserWrite, fpUserExec}
      check not dirExists(b.runDirFor(name))
      check not pathExists(b.serialSocketPathFor(name).parentDir)

    test "a failed socket directory removal can be retried":
      if geteuid() == Uid(0):
        echo "[skip] permission-denied cleanup requires an unprivileged user"
        skip()
      else:
        let runDir = b.runDirFor(name)
        let socketDir = b.serialSocketPathFor(name).parentDir
        createDir(runDir)
        createDir(socketDir)
        writeFile(socketDir / "owned", "data")
        let vm = cleanupHandle(b, name)
        setFilePermissions(socketDir, {})
        try:
          b.stopAndCleanup(vm)
          check vm.extra.getOrDefault("cleanedUp") != "true"
          check pathExists(socketDir)
        finally:
          setFilePermissions(socketDir, {fpUserRead, fpUserWrite, fpUserExec})
        b.stopAndCleanup(vm)
        check not pathExists(socketDir)
        check not dirExists(runDir)

    test "a retained run can be deleted later without reusing stale socket ownership":
      let runDir = b.runDirFor(name)
      let socketDir = b.serialSocketPathFor(name).parentDir
      createDir(runDir)
      createDir(socketDir)
      let vm = cleanupHandle(b, name)
      b.stopAndCleanup(vm, deleteVm = false)
      check dirExists(runDir)
      check not pathExists(socketDir)
      createDir(socketDir)
      writeFile(socketDir / "replacement", "keep")
      b.stopAndCleanup(vm)
      check not dirExists(runDir)
      check readFile(socketDir / "replacement") == "keep"
      createDir(runDir)
      writeFile(runDir / "replacement", "keep")
      b.stopAndCleanup(vm)
      check readFile(runDir / "replacement") == "keep"

    test "deleting a retained handle preserves a directory replaced before deletion":
      let runDir = b.runDirFor(name)
      let socketDir = b.serialSocketPathFor(name).parentDir
      createDir(runDir)
      createDir(socketDir)
      let vm = cleanupHandle(b, name)
      b.stopAndCleanup(vm, deleteVm = false)
      require dirExists(runDir)
      removeDir(runDir)
      createDir(runDir)
      writeFile(runDir / "replacement", "keep")
      b.stopAndCleanup(vm, deleteVm = true)
      check fileExists(runDir / "replacement")
      b.stopAndCleanup(vm, deleteVm = true)
      check fileExists(runDir / "replacement")

    test "first cleanup preserves replaced run and socket directories and their files":
      let runDir = b.runDirFor(name)
      let socketDir = b.serialSocketPathFor(name).parentDir
      createDir(runDir)
      createDir(socketDir)
      let vm = cleanupHandle(b, name)
      for path in [runDir, socketDir]:
        removeDir(path)
        createDir(path)
        writeFile(path / "replacement", "keep")
      writeFile(vm.extra["serialSocketPath"], "keep serial")
      writeFile(vm.extra["tpmSocketPath"], "keep TPM")
      b.stopAndCleanup(vm)
      check fileExists(runDir / "replacement")
      check fileExists(socketDir / "replacement")
      check fileExists(vm.extra["serialSocketPath"])
      check fileExists(vm.extra["tpmSocketPath"])

    test "cleanup refuses directory symlinks and paths without recorded identities":
      let runDir = b.runDirFor(name)
      let socketDir = b.serialSocketPathFor(name).parentDir
      createDir(runDir)
      createDir(socketDir)
      let vm = cleanupHandle(b, name)
      for path in [runDir, socketDir]:
        let moved = path & "-original"
        moveDir(path, moved)
        createSymlink(moved, path)
      b.stopAndCleanup(vm)
      for path in [runDir, socketDir]:
        check symlinkExists(path)
        check dirExists(path & "-original")
        removeFile(path)
        moveDir(path & "-original", path)
        writeFile(path / "unverified", "keep")
      let unverified = VmHandle(backend: b, name: name,
        extra: {"runDir": runDir, "socketDir": socketDir}.toTable)
      b.stopAndCleanup(unverified)
      check fileExists(runDir / "unverified")
      check fileExists(socketDir / "unverified")

    test "an existing run directory is refused without deleting its state":
      let runDir = b.runDirFor(name)
      createDir(runDir)
      writeFile(runDir / "owned-by-another-run", "keep")
      let media = root / "kernel"
      writeFile(media, "not a kernel")
      expect CatchableError:
        discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkKernel,
          mediaPath: media, generation: 3))
      check fileExists(runDir / "owned-by-another-run")

    test "pre-existing socket directories and symlinks are never adopted or cleaned":
      let media = root / "kernel"
      writeFile(media, "not a kernel")
      let socketDir = b.serialSocketPathFor(name).parentDir
      # On the old implementation this is TMPDIR itself; it too must survive.
      createDir(socketDir)
      let socketPath = b.serialSocketPathFor(name)
      writeFile(socketPath, "keep socket owner data")
      expect CatchableError:
        discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkKernel,
          mediaPath: media, generation: 3))
      check fileExists(socketPath)
      check not dirExists(b.runDirFor(name))
      if socketDir != longTemp:
        removeDir(socketDir)
        let target = root / "untouched"
        createDir(target)
        writeFile(target / "serial.sock", "keep symlink target")
        createSymlink(target, socketDir)
        expect CatchableError:
          discard b.bootFromMedia(BootMediaSpec(name: name, kind: bmkKernel,
            mediaPath: media, generation: 3))
        check symlinkExists(socketDir)
        check readFile(target / "serial.sock") == "keep symlink target"

suite "shared OVMF resolution":
  test "a half-specified explicit pair is an error, not a fallback":
    expect ValueError:
      discard acceptOvmfPair("/does/not/matter", "")
    expect ValueError:
      discard acceptOvmfPair("", "/does/not/matter")

  test "an explicit pair that does not exist is an error":
    expect IOError:
      discard acceptOvmfPair("/nonexistent/OVMF_CODE.fd",
                             "/nonexistent/OVMF_VARS.fd")

  test "an empty pair means 'nothing configured at this level'":
    check acceptOvmfPair("", "") == false

  test "the remediation text names the environment overrides":
    let text = describeOvmfSearch()
    check "VMH_OVMF_CODE" in text
    check "VMH_OVMF_VARS" in text
