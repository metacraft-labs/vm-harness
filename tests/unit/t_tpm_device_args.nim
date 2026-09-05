## Gate: the virtual-TPM device is emitted when ``tpmEnabled`` is set and
## is ABSENT when it is not — on both backends that claim to honour the
## field.
##
## This is the pure half of the vTPM gate. It asserts on the arguments
## that decide whether a guest gets a TPM, without starting QEMU, swtpm
## or libvirtd, so it runs everywhere and cannot be skipped. The live
## half — a booted Linux guest really seeing ``/dev/tpm0`` and answering
## a TPM 2.0 capability command — is
## ``tests/integration/t_guest_sees_tpm_device.nim``.
##
## *Why both polarities.* A one-sided assertion here would pass against a
## backend that unconditionally attached a TPM, and an attestation gate
## running against a guest that silently acquired firmware nobody asked
## for is worse than one that fails: it would report a measurement of the
## wrong machine. So every check below has a matching negative.
##
## *Mocking.* None. ``buildQemuBootArgs`` and ``transientBootTpmArgs`` are
## the same pure functions the live boot paths call; this file passes them
## real value types and reads the real argv they return.

import std/[strutils, unittest]
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

proc containsSubstring(args: seq[string], needle: string): bool =
  for a in args:
    if needle in a:
      return true
  false

proc baseLaunch(): QemuBootLaunch =
  QemuBootLaunch(
    vmName: "repro-test-boot-qemu-1-abc",
    diskPath: "/tmp/overlay.qcow2",
    diskFormat: "qcow2",
    serialSocketPath: "/tmp/vmh-qb-1.sock",
    serialLogPath: "/tmp/artifacts/serial.log",
    cpus: 2,
    memoryMB: 1024,
    accel: baTcg)

proc baseBootMedia(): BootMediaSpec =
  BootMediaSpec(
    name: "vmh-boot-1",
    kind: bmkQcow2,
    mediaPath: "/tmp/golden.qcow2",
    cpus: 2,
    memoryMB: 1024,
    generation: 2,
    acceleration: baKvm,
    graphics: bgNone)

suite "qemu-boot vTPM argv":
  test "a TPM socket produces the chardev/tpmdev/device trio":
    var l = baseLaunch()
    l.tpmSocketPath = "/tmp/vmh-qb-tpm-1.sock"
    let args = buildQemuBootArgs(l)

    # The three arguments must agree on the ids that wire them together;
    # a trio that names three different ids is a QEMU startup error, not
    # a TPM-less guest, so assert the wiring and not merely the presence.
    check containsSubstring(args, "socket,id=chrtpm,path=/tmp/vmh-qb-tpm-1.sock")
    check valueAfter(args, "-tpmdev") == "emulator,id=tpm0,chardev=chrtpm"
    check "tpm-tis,tpmdev=tpm0" in args

  test "the device is the x86 tpm-tis, never the aarch64 tpm-tis-device":
    # ``backends/qemu_windows_arm.nim`` — the backend this lifecycle was
    # copied from — emits ``tpm-tis-device``, which is aarch64's spelling.
    # On x86_64 that name does not exist and QEMU exits during device
    # realisation, so this is a real regression this gate must catch.
    var l = baseLaunch()
    l.tpmSocketPath = "/tmp/vmh-qb-tpm-1.sock"
    let args = buildQemuBootArgs(l)
    check not containsSubstring(args, "tpm-tis-device")

  test "no TPM socket produces no TPM arguments at all":
    let args = buildQemuBootArgs(baseLaunch())
    check idx(args, "-tpmdev") < 0
    check not containsSubstring(args, "chrtpm")
    check not containsSubstring(args, "tpm-tis")
    check not containsSubstring(args, "tpm")

  test "the TPM trio is the only difference between the two argvs":
    # Guards against a vTPM change that also perturbs the machine model,
    # the CPU or the serial wiring, which would make every other boot
    # gate's evidence non-comparable across the flag.
    var withTpm = baseLaunch()
    withTpm.tpmSocketPath = "/tmp/vmh-qb-tpm-1.sock"
    let plain = buildQemuBootArgs(baseLaunch())
    let tpm = buildQemuBootArgs(withTpm)
    check tpm.len == plain.len + 6
    check tpm[0 ..< plain.len] == plain

suite "qemu-boot direct kernel argv":
  # The vTPM guest gate needs a Linux guest that boots in about a second,
  # which means -kernel/-initrd rather than a disk image. These are the
  # arguments that carry it.
  test "kernel, initrd and cmdline are emitted when supplied":
    var l = baseLaunch()
    l.diskPath = ""
    l.diskFormat = ""
    l.kernelPath = "/nix/store/x-guest/kernel"
    l.initrdPath = "/nix/store/x-guest/initramfs.gz"
    l.kernelCmdline = "console=ttyS0 panic=1"
    let args = buildQemuBootArgs(l)
    check valueAfter(args, "-kernel") == "/nix/store/x-guest/kernel"
    check valueAfter(args, "-initrd") == "/nix/store/x-guest/initramfs.gz"
    check valueAfter(args, "-append") == "console=ttyS0 panic=1"

  test "a disk boot emits no kernel arguments":
    let args = buildQemuBootArgs(baseLaunch())
    check idx(args, "-kernel") < 0
    check idx(args, "-initrd") < 0
    check idx(args, "-append") < 0

  test "an initrd or cmdline without a kernel is rejected":
    var l = baseLaunch()
    l.initrdPath = "/nix/store/x-guest/initramfs.gz"
    expect ValueError:
      discard buildQemuBootArgs(l)
    var m = baseLaunch()
    m.kernelCmdline = "console=ttyS0"
    expect ValueError:
      discard buildQemuBootArgs(m)

  test "a kernel alone is enough media to boot":
    var l = baseLaunch()
    l.diskPath = ""
    l.diskFormat = ""
    l.kernelPath = "/nix/store/x-guest/kernel"
    let args = buildQemuBootArgs(l)
    check valueAfter(args, "-kernel") == "/nix/store/x-guest/kernel"

suite "libvirt vTPM virt-install arguments":
  test "tpmEnabled produces an emulator-backed TPM 2.0 on tpm-tis":
    var spec = baseBootMedia()
    spec.tpmEnabled = true
    let args = transientBootTpmArgs(spec)
    check args == @["--tpm", "emulator,model=tpm-tis,version=2.0"]

  test "tpmEnabled false produces nothing":
    let spec = baseBootMedia()
    check transientBootTpmArgs(spec).len == 0

  test "the field is version-pinned to 2.0, not left to libvirt's default":
    # libvirt's default TPM version is 1.2 on some releases. An
    # attestation gate that silently got a TPM 1.2 would fail much later
    # and much less legibly than one that never got a TPM at all.
    var spec = baseBootMedia()
    spec.tpmEnabled = true
    check "version=2.0" in transientBootTpmArgs(spec)[1]
