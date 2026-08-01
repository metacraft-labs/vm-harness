## Unit tests for the WslBackend and its shared parser helpers.
##
## Like the Hyper-V parser tests, these are pure-logic and run on any
## host. The full lifecycle (which requires a Windows host with WSL2)
## is covered by ``tests/integration/t_wsl_lifecycle.nim`` (status
## pending) and ``tests/e2e/t_vm_harness_wsl_m69_passwd_user_passes.nim``.

import std/unittest
import vm_harness

suite "parseWslListQuiet":
  test "splits ASCII names":
    let names = parseWslListQuiet("ubuntu\nrepro-m69-posix-1234\n")
    check names == @["ubuntu", "repro-m69-posix-1234"]

  test "strips UTF-16 stray null bytes":
    # Simulate the UTF-16 output wsl.exe emits for --list when the
    # console encoding wasn't switched. The bytes between letters
    # are stray nulls.
    let raw = "u\x00b\x00u\x00n\x00t\x00u\x00\n\x00"
    let names = parseWslListQuiet(raw)
    check names == @["ubuntu"]

  test "strips UTF-8 BOM":
    let raw = "\xEF\xBB\xBFubuntu\n"
    let names = parseWslListQuiet(raw)
    check names == @["ubuntu"]

  test "ignores blank lines":
    let names = parseWslListQuiet("\n\nubuntu\n\n")
    check names == @["ubuntu"]

suite "buildWslExecArgs":
  test "minimal exec":
    let args = buildWslExecArgs(WslExecInvocation(
      distro: "ubuntu",
      command: "echo hi"))
    check args[0] == "wsl.exe"
    check "-d" in args
    check "ubuntu" in args
    check "--exec" in args
    check "/bin/bash" in args
    check "-c" in args
    check "echo hi" in args
    check "--user" notin args

  test "user and working dir flags propagate":
    let args = buildWslExecArgs(WslExecInvocation(
      distro: "ubuntu",
      user: "root",
      workingDir: "/tmp",
      command: "pwd"))
    check "--user" in args
    check "root" in args
    check "--cd" in args
    check "/tmp" in args

  test "alternative shell honored":
    let args = buildWslExecArgs(WslExecInvocation(
      distro: "ubuntu",
      shell: "/bin/sh",
      command: "true"))
    check "/bin/sh" in args
    check "/bin/bash" notin args

suite "buildWslImportArgs":
  test "renders the import argv":
    let args = buildWslImportArgs(WslImportInvocation(
      distroName: "repro-m69",
      installDir: "D:\\state",
      rootfsTarball: "D:\\cache\\ubuntu.tar.gz"))
    check args == @["wsl.exe", "--import",
                    "repro-m69", "D:\\state",
                    "D:\\cache\\ubuntu.tar.gz"]

  test "version flag appended when non-zero":
    let args = buildWslImportArgs(WslImportInvocation(
      distroName: "x", installDir: "y", rootfsTarball: "z",
      version: 2))
    check "--version" in args
    check "2" in args

suite "buildWsl{Unregister,Terminate,ListQuiet}Args":
  test "unregister is two-arg":
    let a = buildWslUnregisterArgs("repro-m69")
    check a == @["wsl.exe", "--unregister", "repro-m69"]

  test "terminate is two-arg":
    let a = buildWslTerminateArgs("repro-m69")
    check a == @["wsl.exe", "--terminate", "repro-m69"]

  test "list-quiet is plain":
    let a = buildWslListQuietArgs()
    check a == @["wsl.exe", "--list", "--quiet"]

suite "hostPathToWslPath":
  test "Windows drive paths become /mnt/<drive>":
    check hostPathToWslPath("D:\\metacraft\\foo") ==
          "/mnt/d/metacraft/foo"
    check hostPathToWslPath("C:\\Users\\zahary\\file.txt") ==
          "/mnt/c/Users/zahary/file.txt"

  test "Mixed slashes normalize":
    check hostPathToWslPath("D:/metacraft/foo") ==
          "/mnt/d/metacraft/foo"

  test "POSIX paths pass through":
    check hostPathToWslPath("/usr/local/bin/foo") ==
          "/usr/local/bin/foo"

  test "Drive root yields /mnt/<drive>":
    check hostPathToWslPath("D:") == "/mnt/d"
    check hostPathToWslPath("D:\\") == "/mnt/d/"

suite "buildWslRunArgs":
  test "minimal invocation":
    let a = buildWslRunArgs(plPwsh, WslRunInvocation(
      scriptPath: "C:\\s\\run-wsl-m69-posix.ps1"))
    check "-File" in a
    check "C:\\s\\run-wsl-m69-posix.ps1" in a
    check "-TimeoutMinutes" notin a
    check "-KeepDistro" notin a

  test "all flags propagate":
    let a = buildWslRunArgs(plPwsh, WslRunInvocation(
      scriptPath: "C:\\s\\run.ps1",
      timeoutMinutes: 45,
      keepDistro: true))
    check "-TimeoutMinutes" in a
    check "45" in a
    check "-KeepDistro" in a

suite "newWslBackend":
  test "construction sets identity":
    let b = newWslBackend(distroPrefix = "test-prefix",
                          rootfsTarballPath = "D:\\rootfs.tar.gz",
                          installRootDir = "D:\\state",
                          defaultUser = "root")
    check b.id == biWsl
    check b.hostPlatform == hpWindows
    check b.supportedGuests == {goLinux}
    check b.distroPrefix == "test-prefix"
    check b.rootfsTarballPath == "D:\\rootfs.tar.gz"

  test "M0 registry auto-registers a default instance":
    let b = newBackend(biWsl)
    check b.id == biWsl
    check b of WslBackend

  when not defined(windows):
    test "probeAvailability returns false off-Windows":
      let b = newWslBackend()
      check not b.probeAvailability()
