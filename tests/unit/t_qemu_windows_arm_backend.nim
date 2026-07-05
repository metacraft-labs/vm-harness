## Pure/unit tests for the direct QEMU Windows ARM backend.
##
## These do not boot QEMU. They assert the filesystem validation,
## deterministic naming, command construction, SSH command quoting, and
## bounded probe behavior that the live cached-boot path depends on.

import std/[os, tables, tempfiles, times, unittest]
import vm_harness

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "QemuWindowsArmBackend pure behavior":
  test "baseline directory validation requires windows.qcow2":
    let tmp = createTempDir("vmh-qemu-win-arm-validate-", "")
    defer: removeDir(tmp)

    expect ValueError:
      discard validateWindowsArmVmDir(tmp)

    writeFile(tmp / "windows.qcow2", "not-a-real-qcow2")
    check validateWindowsArmVmDir(tmp) == absolutePath(tmp)

  test "ephemeral naming and state path are deterministic":
    check ephemeralName("repro-vm-qemu-windows-arm", 1700000000123'i64, 42) ==
      "repro-vm-qemu-windows-arm-1700000000123-42"
    check ephemeralDirFor("/state", "vm-a") == "/state" / "instances" / "vm-a"

  test "QEMU argv uses aarch64 HVF, user networking, and a cloned disk path":
    let tmp = createTempDir("vmh-qemu-win-arm-argv-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")
    writeFile(tmp / "QEMU_EFI.fd", "")

    let args = buildQemuWindowsArmArgs(tmp, 2230, cpus = 6, memoryMB = 12288)
    check args[0 .. 5] == @["-accel", "hvf", "-machine", "virt,highmem=on",
                            "-cpu", "host"]
    check "-m" in args
    check args[args.find("-m") + 1] == "12288"
    check "-smp" in args
    check args[args.find("-smp") + 1] == "6"
    check "id=disk0,file=" & tmp / "windows.qcow2" &
          ",format=qcow2,if=none,cache=writeback,discard=unmap" in args
    check "user,id=net0,hostfwd=tcp:127.0.0.1:2230-:22" in args
    check "virtio-blk-device,drive=disk0,bootindex=1" in args
    check "virtio-net-device,netdev=net0" in args
    check "file:" & tmp / "serial.log" in args
    check "-bios" in args
    check args[args.find("-bios") + 1] == tmp / "QEMU_EFI.fd"

  test "ephemeral copy clones only boot-relevant files":
    let base = createTempDir("vmh-qemu-win-arm-base-", "")
    let state = createTempDir("vmh-qemu-win-arm-state-", "")
    defer:
      removeDir(base)
      removeDir(state)
    writeFile(base / "windows.qcow2", "disk")
    writeFile(base / "AAVMF_VARS.fd", "vars")
    writeFile(base / "notes.txt", "skip")

    let dest = state / "instances" / "vm"
    createEphemeralCopy(base, dest)
    check fileExists(dest / "windows.qcow2")
    check fileExists(dest / "AAVMF_VARS.fd")
    check not fileExists(dest / "notes.txt")
    check readFile(base / "windows.qcow2") == "disk"

  test "Windows SSH command quoting preserves argv boundaries and env":
    let env = {"VMH_TEST": "a&b"}.toTable
    let remote = buildWindowsRemoteCommand(env,
      @["powershell", "-NoProfile", "-Command", "Write-Output \"hello world\""])
    check remote == "cmd /c \"set \"VMH_TEST=a&b\" & powershell -NoProfile -Command \"Write-Output \"\"hello world\"\"\"\""

    let b = newQemuWindowsArmBackend(sshpassCmd = "sshpass-test",
                                     sshCmd = "ssh-test",
                                     sshUser = "admin")
    let sshArgs = buildSshpassSshArgs(b, "/tmp/pwd", 2230, remote)
    check sshArgs[0 .. 3] == @["sshpass-test", "-f", "/tmp/pwd", "ssh-test"]
    check "-p" in sshArgs
    check sshArgs[sshArgs.find("-p") + 1] == "2230"
    check sshArgs[^2] == "admin@127.0.0.1"
    check sshArgs[^1] == remote

  test "probeAvailability is bounded when qemu command is silent":
    when defined(macosx):
      let tmp = createTempDir("vmh-qemu-win-arm-probe-", "")
      defer: removeDir(tmp)
      let silent = tmp / "silent-qemu"
      let sshpass = tmp / "sshpass"
      writeExecutable(silent, "#!/bin/sh\nsleep 5\n")
      writeExecutable(sshpass, "#!/bin/sh\necho 'sshpass 1.10'\n")

      let b = newQemuWindowsArmBackend(qemuCmd = silent,
                                       sshpassCmd = sshpass,
                                       probeTimeoutSec = 1)
      let started = epochTime()
      check not b.probeAvailability()
      check epochTime() - started < 3.0
    else:
      let b = newQemuWindowsArmBackend()
      check not b.probeAvailability()
