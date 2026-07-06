## Pure/unit tests for the direct QEMU Windows ARM backend.
##
## These do not boot QEMU. They assert the filesystem validation,
## deterministic naming, command construction, SSH command quoting, and
## bounded probe behavior that the live cached-boot path depends on.

import std/[os, sequtils, streams, strutils, tables, tempfiles, times, unittest,
            xmlparser, xmltree]
import vm_harness

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc childElement(node: XmlNode, tag: string): XmlNode =
  for child in node:
    if child.kind == xnElement and child.tag == tag:
      return child

proc textContent(node: XmlNode): string =
  case node.kind
  of xnText, xnVerbatimText, xnCData, xnEntity:
    result = node.text
  of xnElement:
    for child in node:
      result.add child.textContent()
  else:
    discard

proc elementText(node: XmlNode, tag: string): string =
  let child = node.childElement(tag)
  if child != nil:
    result = child.textContent()

proc collectElements(node: XmlNode, tag: string, acc: var seq[XmlNode]) =
  if node.kind == xnElement and node.tag == tag:
    acc.add node
  for child in node:
    if child.kind == xnElement:
      collectElements(child, tag, acc)

proc elements(node: XmlNode, tag: string): seq[XmlNode] =
  collectElements(node, tag, result)

proc windowsArmAutounattend(): XmlNode =
  let recipe = currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "windows-arm-base" / "autounattend.xml"
  parseXml(newStringStream(readFile(recipe)))

proc firstLogonCommands(xml: XmlNode): seq[XmlNode] =
  for settings in xml.elements("settings"):
    if settings.attr("pass") != "oobeSystem":
      continue
    for component in settings.elements("component"):
      if component.attr("name") == "Microsoft-Windows-Shell-Setup":
        let firstLogon = component.childElement("FirstLogonCommands")
        if firstLogon != nil:
          return firstLogon.elements("SynchronousCommand")

suite "QemuWindowsArmBackend pure behavior":
  test "windows-arm autounattend has exact LabConfig bypasses in windowsPE":
    let xml = windowsArmAutounattend()
    let expectedPaths = @[
      r"reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f",
      r"reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f",
      r"reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f",
    ]

    var setupComponent: XmlNode
    for settings in xml.elements("settings"):
      if settings.attr("pass") != "windowsPE":
        continue
      for component in settings.elements("component"):
        if component.attr("name") == "Microsoft-Windows-Setup":
          setupComponent = component

    check setupComponent != nil
    let runSynchronous = setupComponent.childElement("RunSynchronous")
    check runSynchronous != nil
    let commands = runSynchronous.elements("RunSynchronousCommand")
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]
    check commands.mapIt(it.elementText("Path")) == expectedPaths

  test "windows-arm autounattend logs OpenSSH provisioning and failure marker":
    let commands = windowsArmAutounattend().firstLogonCommands()
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]

    let provision = commands[0].elementText("CommandLine")
    check commands[0].elementText("Description") ==
      "Provision OpenSSH Server with diagnostics"
    check "C:\\Windows\\Temp\\vmh-openssh-provision.log" in provision
    check "C:\\Windows\\Temp\\vmh-openssh-provision-failed" in provision
    check "C:\\Windows\\Temp\\repro-install-done" in provision
    check "Remove-Item -LiteralPath $fail,$done" in provision
    check "CapabilityState 'before'" in provision
    check "CapabilityState 'after'" in provision
    check "' capability state: '" in provision
    check "Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'" in
      provision
    check "function LogError([string]$Step,[object]$Err)" in provision
    check "LASTEXITCODE=" in provision
    check "LogError 'Add-WindowsCapability' $_" in provision
    check "OpenSSH.Server capability is not installed" in provision
    check "Set-Service -Name sshd -StartupType Automatic" in provision
    check "Start-Service -Name sshd" in provision
    check "service sshd status:" in provision
    check "sshd is unavailable" in provision
    check "SUCCESS OpenSSH provisioning" in provision

  test "windows-arm install-done marker is gated on OpenSSH success":
    let commands = windowsArmAutounattend().firstLogonCommands()
    let marker = commands[2].elementText("CommandLine")

    check commands[2].elementText("Description") ==
      "Write install-done sentinel after OpenSSH is ready"
    check "Test-Path -LiteralPath 'C:\\Windows\\Temp\\vmh-openssh-provision-failed'" in
      marker
    check "Get-Service -Name sshd" in marker
    check ".Status -ne 'Running'" in marker
    check "exit 1" in marker
    check "Set-Content -LiteralPath 'C:\\Windows\\Temp\\repro-install-done'" in
      marker

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
