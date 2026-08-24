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
      "--graphics", "vnc",
      "--video", "virtio",
      "--screenshot", "build/welcome.png",
      "--screenshot-delay-sec", "3",
      "--viewer",
      "--wait-for-shutdown",
      "--timeout-sec", "90"])
    check opts.subcommand == "boot"
    check opts.sourceImage == "images"
    check opts.secondaryIsoPath == "seed.iso"
    check opts.targetDiskPath == "build/installed.qcow2"
    check opts.mediaKind == "qcow2"
    check opts.expectPattern == "systemd"
    check opts.generation == 2
    check opts.graphics == "vnc"
    check opts.videoModel == "virtio"
    check opts.screenshotPath == "build/welcome.png"
    check opts.screenshotDelaySec == 3
    check opts.viewer
    check opts.waitForShutdown
    check opts.timeoutSec == 90

  test "boot graphics and firmware defaults are explicit":
    let opts = parseCliOpts(@["boot", "--source-image", "reproos.qcow2",
                              "--keep"])
    check opts.generation == 2
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
      discard parseCliOpts(@[
        "boot", "--screenshot-delay-sec", "-1"])

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

  test "content-addressed output directories select their newest image":
    let root = createTempDir("vmh-cli-boot", "")
    defer: removeDir(root)
    let older = root / "aaa-reproos-installed.qcow2"
    let newer = root / "bbb-reproos-installed.qcow2"
    writeFile(older, "old")
    sleep(1100)
    writeFile(newer, "new")
    check resolveBootMediaPath(root) == absolutePath(newer)
