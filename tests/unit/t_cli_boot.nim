import std/[os, tempfiles, unittest]
import vm_harness/cli
import vm_harness/types

suite "CLI boot media":
  test "boot flags parse without overloading gate command arguments":
    let opts = parseCliOpts(@[
      "boot",
      "--backend", "auto",
      "--source-image", "images",
      "--kind", "qcow2",
      "--expect", "systemd",
      "--timeout-sec", "90"])
    check opts.subcommand == "boot"
    check opts.sourceImage == "images"
    check opts.mediaKind == "qcow2"
    check opts.expectPattern == "systemd"
    check opts.timeoutSec == 90

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
