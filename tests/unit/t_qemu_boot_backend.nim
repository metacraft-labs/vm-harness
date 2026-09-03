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
## reprobuild's registered boot-smoke gates, which drive a synthetic
## guest under a real QEMU.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

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
