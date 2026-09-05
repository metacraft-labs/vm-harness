import std/[os, tempfiles, unittest]
import vm_harness/cli
import vm_harness/types

suite "CLI boot media":
  test "boot flags parse without overloading gate command arguments":
    let opts = parseCliOpts(@[
      "boot",
      "--backend", "auto",
      "--source-image", "images",
      "--secondary-iso", "seed.iso",
      "--target-disk", "build/installed.qcow2",
      "--kind", "qcow2",
      "--expect", "systemd",
      "--generation", "2",
      "--acceleration", "tcg",
      "--graphics", "vnc",
      "--video", "virtio",
      "--screenshot", "build/welcome.png",
      "--screenshot-delay-sec", "3",
      "--viewer",
      "--wait-for-shutdown",
      "--timeout-sec", "90",
      "--ssh-ready-timeout-sec", "20"])
    check opts.subcommand == "boot"
    check opts.sourceImage == "images"
    check opts.secondaryIsoPath == "seed.iso"
    check opts.targetDiskPath == "build/installed.qcow2"
    check opts.mediaKind == "qcow2"
    check opts.expectPattern == "systemd"
    check opts.generation == 2
    check opts.acceleration == "tcg"
    check opts.graphics == "vnc"
    check opts.videoModel == "virtio"
    check opts.screenshotPath == "build/welcome.png"
    check opts.screenshotDelaySec == 3
    check opts.viewer
    check opts.waitForShutdown
    check opts.timeoutSec == 90
    check opts.sshReadyTimeoutSec == 20

  test "boot graphics and firmware defaults are explicit":
    let opts = parseCliOpts(@["boot", "--source-image", "reproos.qcow2",
                              "--keep"])
    check opts.generation == 2
    check opts.acceleration == "auto"
    check opts.graphics == "none"
    check opts.videoModel == "virtio"

  test "default boot artifacts are isolated between CLI processes":
    let first = resolveBootOutputDir("", 101)
    let second = resolveBootOutputDir("", 202)
    check first == getTempDir() / "vm-harness-boot-101"
    check second == getTempDir() / "vm-harness-boot-202"
    check first != second

    let explicit = getTempDir() / "vm-harness-explicit-output"
    check resolveBootOutputDir(explicit, 303) == absolutePath(explicit)

  test "invalid boot generation and graphics are rejected":
    expect ValueError:
      discard parseCliOpts(@["boot", "--generation", "3"])
    expect ValueError:
      discard parseCliOpts(@["boot", "--graphics", "public-vnc"])
    expect ValueError:
      discard parseCliOpts(@["boot", "--acceleration", "nested-magic"])
    expect ValueError:
      discard parseCliOpts(@[
        "boot", "--screenshot-delay-sec", "-1"])
    expect ValueError:
      discard parseCliOpts(@[
        "boot", "--ssh-ready-timeout-sec", "0"])

  test "install parses as a target-disk lifecycle":
    let opts = parseCliOpts(@[
      "install", "--source-image", "reproos.iso", "--kind", "iso",
      "--target-disk", "build/reproos-installed.qcow2",
      "--expect", "INSTALL COMPLETE"])
    check opts.subcommand == "install"
    check opts.targetDiskPath == "build/reproos-installed.qcow2"
    check opts.expectPattern == "INSTALL COMPLETE"

  test "media kind is inferred from supported extensions":
    check parseBootMediaKind("auto", "reproos.iso") == bmkIso
    check parseBootMediaKind("", "reproos.qcow2") == bmkQcow2
    check parseBootMediaKind("auto", "reproos.vhdx") == bmkVhdx

  test "auto backend uses Hyper-V on Windows and libvirt on Linux":
    let opts = parseCliOpts(@["boot", "--source-image", "reproos.qcow2",
                              "--keep"])
    check resolveBootBackendId(opts, bmkQcow2, hpWindows) == biHyperv
    check resolveBootBackendId(opts, bmkQcow2, hpLinux) == biLibvirt

  test "vTPM and secure boot are off unless the caller asks for them":
    # ``--tpm`` and ``--secure-boot`` are the only way a caller can reach
    # ``BootMediaSpec.tpmEnabled`` / ``secureBootEnabled`` from the command
    # line. Both polarities, because a flag that is always on is the same
    # defect as a spec field no backend reads.
    let plain = parseCliOpts(@["boot", "--source-image", "reproos.qcow2"])
    check not plain.tpmEnabled
    check not plain.secureBootEnabled
    let armed = parseCliOpts(@["boot", "--source-image", "reproos.qcow2",
                               "--tpm", "--secure-boot"])
    check armed.tpmEnabled
    check armed.secureBootEnabled

  test "the parser records whether a generation was actually requested":
    # A direct kernel boot defaults to legacy BIOS, which only works if
    # "nobody said" is distinguishable from "the caller asked for 2".
    check not parseCliOpts(@["boot", "--source-image", "bzImage"]).generationSet
    let explicit = parseCliOpts(@["boot", "--source-image", "bzImage",
                                  "--generation", "2"])
    check explicit.generationSet
    check explicit.generation == 2

  test "kernel media must be asked for, never inferred":
    check parseBootMediaKind("kernel", "bzImage") == bmkKernel
    expect ValueError:
      discard parseBootMediaKind("auto", "bzImage")

  test "a kernel boot carries its initramfs and cmdline and picks qemu-boot":
    # libvirt's bootFromMedia rejects bmkKernel outright, so auto-selection
    # routing there would turn a supported boot into a hard failure.
    let opts = parseCliOpts(@["boot", "--source-image", "bzImage",
                              "--kind", "kernel",
                              "--initrd", "initramfs.gz",
                              "--kernel-cmdline", "console=ttyS0 panic=1"])
    check opts.initrd == "initramfs.gz"
    check opts.kernelCmdline == "console=ttyS0 panic=1"
    check resolveBootBackendId(opts, bmkKernel, hpLinux) == biQemuBoot
    check resolveBootBackendId(opts, bmkQcow2, hpLinux) == biLibvirt

  test "content-addressed output directories select their newest image":
    let root = createTempDir("vmh-cli-boot", "")
    defer: removeDir(root)
    let older = root / "aaa-reproos-installed.qcow2"
    let newer = root / "bbb-reproos-installed.qcow2"
    writeFile(older, "old")
    sleep(1100)
    writeFile(newer, "new")
    check resolveBootMediaPath(root) == absolutePath(newer)
