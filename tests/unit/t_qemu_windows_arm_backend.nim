## Pure/unit tests for the direct QEMU Windows ARM backend.
##
## These do not boot QEMU. They assert the filesystem validation,
## deterministic naming, command construction, SSH command quoting, and
## bounded probe behavior that the live cached-boot path depends on.

import std/[net, os, osproc, sequtils, streams, strutils, tables, tempfiles,
            times, unittest, xmlparser, xmltree]
import vm_harness

const
  PortAllocationWorkerArg = "--vmh-qemu-port-allocation-worker"
  PortListenerHelperEnv = "VMH_QEMU_PORT_LISTENER_HELPER"
  PortListenerBindDelayEnv = "VMH_QEMU_PORT_LISTENER_BIND_DELAY_MS"

proc qemuForwardedPort(): int =
  const marker = "hostfwd=tcp:127.0.0.1:"
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    let start = arg.find(marker)
    if start < 0:
      continue
    let portStart = start + marker.len
    let portEnd = arg.find("-:22", portStart)
    if portEnd > portStart:
      return parseInt(arg[portStart ..< portEnd])
  raise newException(ValueError, "fake QEMU did not receive an SSH hostfwd")

proc maybeRunPortListenerHelper() =
  if getEnv(PortListenerHelperEnv) != "1":
    return
  let delayMs = parseInt(getEnv(PortListenerBindDelayEnv, "0"))
  if delayMs > 0:
    sleep(delayMs)
  var listener = newSocket()
  listener.bindAddr(Port(qemuForwardedPort()), "127.0.0.1")
  listener.listen()
  sleep(30_000)
  quit(QuitSuccess)

proc maybeRunPortAllocationWorker() =
  if paramCount() < 5 or paramStr(1) != PortAllocationWorkerArg:
    return
  let stateDir = paramStr(2)
  let vmDir = paramStr(3)
  let resultFile = paramStr(4)
  let preferredPort = parseInt(paramStr(5))
  createDir(vmDir)
  writeFile(vmDir / "windows.qcow2", "fake-qcow2")
  putEnv(PortListenerHelperEnv, "1")
  putEnv(PortListenerBindDelayEnv, "250")
  let backend = newQemuWindowsArmBackend(
    qemuCmd = getAppFilename(),
    stateDir = stateDir,
    sshPort = preferredPort)
  let started = backend.startQemuWithAllocatedPort(vmDir, 1, 64)
  writeFile(resultFile, $started.sshPort & " " & $started.pid)
  quit(QuitSuccess)

maybeRunPortListenerHelper()
maybeRunPortAllocationWorker()

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

proc windowsArmRecipeFile(name: string): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "windows-arm-base" / name

proc windowsArmProvisionOpenSshScript(): string =
  readFile(windowsArmRecipeFile("provision-openssh.ps1"))

proc firstLogonCommands(xml: XmlNode): seq[XmlNode] =
  for settings in xml.elements("settings"):
    if settings.attr("pass") != "oobeSystem":
      continue
    for component in settings.elements("component"):
      if component.attr("name") == "Microsoft-Windows-Shell-Setup":
        let firstLogon = component.childElement("FirstLogonCommands")
        if firstLogon != nil:
          return firstLogon.elements("SynchronousCommand")

proc specializeDeploymentCommands(xml: XmlNode): seq[XmlNode] =
  for settings in xml.elements("settings"):
    if settings.attr("pass") != "specialize":
      continue
    for component in settings.elements("component"):
      if component.attr("name") == "Microsoft-Windows-Deployment":
        let runSync = component.childElement("RunSynchronous")
        if runSync != nil:
          return runSync.elements("RunSynchronousCommand")

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

  test "windows-arm specialize stages OpenSSH provisioning script locally":
    let commands = windowsArmAutounattend().specializeDeploymentCommands()
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]

    let stage = commands[0].elementText("Path")
    check commands[0].elementText("Description") ==
      "Stage OpenSSH provisioning script locally"
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\provision-openssh.ps1" in stage
    check "copy /Y %i:\\provision-openssh.ps1 C:\\Windows\\Temp\\provision-openssh.ps1" in
      stage

  test "windows-arm specialize stages offline OpenSSH ARM64 zip locally when present":
    let commands = windowsArmAutounattend().specializeDeploymentCommands()
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]

    let stage = commands[1].elementText("Path")
    check commands[1].elementText("Description") ==
      "Stage OpenSSH ARM64 portable zip locally when present"
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\openssh\\OpenSSH-ARM64.zip" in stage
    check "copy /Y %i:\\openssh\\OpenSSH-ARM64.zip C:\\Windows\\Temp\\OpenSSH-ARM64.zip" in
      stage

  test "windows-arm specialize stages offline VirtIO NetKVM ARM64 driver locally when present":
    let commands = windowsArmAutounattend().specializeDeploymentCommands()
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]

    let stage = commands[2].elementText("Path")
    check commands[2].elementText("Description") ==
      "Stage VirtIO NetKVM ARM64 driver locally when present"
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\virtio\\NetKVM\\w11\\ARM64\\netkvm.inf" in stage
    check "xcopy /E /I /Y %i:\\virtio C:\\Windows\\Temp\\virtio" in stage

  test "windows-arm FirstLogon launches staged local OpenSSH provisioning script":
    let commands = windowsArmAutounattend().firstLogonCommands()
    check commands.mapIt(it.elementText("Order")) == @["1", "2", "3"]

    let provision = commands[0].elementText("CommandLine")
    check commands[0].elementText("Description") ==
      "Provision OpenSSH Server with diagnostics"
    check provision.len < 1024
    check "$p='C:\\Windows\\Temp\\provision-openssh.ps1'" in provision
    check "Test-Path -LiteralPath $p" in provision
    check "& $p" in provision
    check "foreach ($drive" notin provision
    check ":\\provision-openssh.ps1" notin provision.replace(
      "C:\\Windows\\Temp\\provision-openssh.ps1", "")
    check "vmh-openssh-provision-failed" in provision
    check "provision-openssh.ps1 not found" in provision
    check "Add-WindowsCapability" notin provision
    check "function LogError" notin provision
    check "exit 0" in provision
    check "exit 1" notin provision

  test "windows-arm staged OpenSSH script logs diagnostics and failure marker":
    let provision = windowsArmProvisionOpenSshScript()

    check "C:\\Windows\\Temp\\vmh-openssh-provision.log" in provision
    check "C:\\Windows\\Temp\\vmh-openssh-provision-failed" in provision
    check "C:\\Windows\\Temp\\repro-install-done" in provision
    check "$portableZip = 'C:\\Windows\\Temp\\OpenSSH-ARM64.zip'" in provision
    check "$netKvmDir = 'C:\\Windows\\Temp\\virtio\\NetKVM\\w11\\ARM64'" in
      provision
    check "$installDir = 'C:\\Program Files\\OpenSSH'" in provision
    check "Remove-Item -LiteralPath $fail, $done" in provision
    check "$script:provisionFailed = $false" in provision
    check "function InstallNetKvmDriver" in provision
    check "Join-Path $netKvmDir 'netkvm.inf'" in provision
    check "NetKVM ARM64 driver not staged at" in provision
    check "skipping virtio-net driver install" in provision
    check "directory is staged but netkvm.inf is missing" in provision
    check "pnputil.exe /add-driver $netKvmInf /install" in provision
    check "END pnputil add NetKVM LASTEXITCODE=" in provision
    check "staged NetKVM ARM64 driver install failed" in provision
    check "SUCCESS NetKVM ARM64 driver install" in provision
    check "try {\n  InstallNetKvmDriver" in provision
    check provision.find("try {\n  InstallNetKvmDriver") <
      provision.find("Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'")
    check "CapabilityState 'before'" in provision
    check "CapabilityState 'after'" in provision
    check "' capability state: '" in provision
    check "Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'" in
      provision
    check "function LogError([string]$Step, [object]$Err)" in provision
    check "LASTEXITCODE=" in provision
    check "LogError 'Add-WindowsCapability' $_" in provision
    check "OpenSSH.Server capability is not installed" in provision
    check "trying portable OpenSSH ARM64 fallback" in provision
    check "InstallPortableOpenSsh" in provision
    check "portable OpenSSH fallback zip not found at" in provision
    check "Expand-Archive -LiteralPath $portableZip" in provision
    check "Move-Item -LiteralPath $expandedDir -Destination $installDir" in provision
    check "install-sshd.ps1" in provision
    check "bundled install-sshd.ps1 not found; registering sshd service manually" in
      provision
    check "New-Service `" in provision
    check "ssh-keygen -A" in provision
    check "OpenSSH.Server capability is not installed and portable fallback failed" in
      provision
    check "Set-Content -LiteralPath $fail -Value $Message" in provision
    check "$script:provisionFailed = $true" in provision
    check "if (-not $script:provisionFailed)" in provision
    check "function ConfigureOpenSsh" in provision
    check "Set-Service -Name sshd -StartupType Automatic" in provision
    check "Start-Service -Name sshd" in provision
    check "service sshd status:" in provision
    check "sshd is unavailable" in provision
    check "SUCCESS OpenSSH provisioning" in provision
    check "exit 0" in provision
    check "exit 1" notin provision

  test "windows-arm autounattend ISO builder stages OpenSSH script":
    let buildScript = readFile(windowsArmRecipeFile("build-autounattend-iso.sh"))

    check "provision-openssh.ps1" in buildScript
    check "missing provision-openssh.ps1" in buildScript
    check "cp \"${SCRIPT_DIR}/provision-openssh.ps1\" \"${STAGE_DIR}/provision-openssh.ps1\"" in
      buildScript

  test "windows-arm autounattend ISO builder stages OpenSSH ARM64 zip when available":
    let buildScript = readFile(windowsArmRecipeFile("build-autounattend-iso.sh"))

    check "OPENSSH_ZIP_SRC" in buildScript
    check "--openssh-arm64-zip" in buildScript
    check "--require-openssh-arm64-zip" in buildScript
    check "VMH_OPENSSH_ARM64_ZIP" in buildScript
    check "./build/OpenSSH-ARM64.zip" in buildScript
    check "mkdir -p \"${STAGE_DIR}/openssh\"" in buildScript
    check "cp \"${OPENSSH_ZIP_SRC}\" \"${STAGE_DIR}/openssh/OpenSSH-ARM64.zip\"" in
      buildScript
    check "OpenSSH ARM64 zip not embedded; offline fallback will be unavailable" in
      buildScript

  test "windows-arm autounattend ISO builder stages VirtIO NetKVM ARM64 driver when available":
    let buildScript = readFile(windowsArmRecipeFile("build-autounattend-iso.sh"))

    check "VIRTIO_NETKVM_SRC" in buildScript
    check "--virtio-netkvm-arm64-dir" in buildScript
    check "--require-virtio-netkvm-arm64" in buildScript
    check "VMH_VIRTIO_NETKVM_ARM64_DIR" in buildScript
    check "./build/virtio/NetKVM/w11/ARM64" in buildScript
    check "netkvm.inf" in buildScript
    check "mkdir -p \"${STAGE_DIR}/virtio/NetKVM/w11/ARM64\"" in buildScript
    check "cp -R \"${VIRTIO_NETKVM_SRC}/.\" \"${STAGE_DIR}/virtio/NetKVM/w11/ARM64/\"" in
      buildScript
    check "NetKVM ARM64 driver dir not embedded; virtio networking offline install will be unavailable" in
      buildScript

  test "windows-arm OpenSSH ARM64 fetch helper pins official release checksum":
    let fetchScript = readFile(windowsArmRecipeFile("fetch-openssh-arm64.sh"))

    check "PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-ARM64.zip" in
      fetchScript
    check "698c6aec31c1dd0fb996206e8741f4531a97355686b5431ef347d531b07fcd42" in
      fetchScript
    check "curl -fL --retry 3" in fetchScript
    check "checksum mismatch" in fetchScript
    check "VMH_OPENSSH_ARM64_ZIP_OUT" in fetchScript

  test "windows-arm VirtIO NetKVM ARM64 fetch helper pins qemus release checksum and validates contents":
    let fetchScript = readFile(windowsArmRecipeFile("fetch-virtio-netkvm-arm64.sh"))

    check "qemus/virtiso-arm/releases/download/v0.1.285-1/virtio-win-0.1.285.tar.xz" in
      fetchScript
    check "c6712f8d5730c09c1212be9fc3baa18b78534f3c8c136cf02b2cca46515ca310" in
      fetchScript
    check "MEMBER_ROOT=\"NetKVM/w11/ARM64\"" in fetchScript
    check "tar -tf \"${tmp}\" > \"${member_list}\"" in fetchScript
    check "grep -qx \"${MEMBER_ROOT}/netkvm.inf\" \"${member_list}\"" in fetchScript
    check "tar -xf \"${ARCHIVE_OUT}\" -C \"${extract_tmp}\" \"NetKVM\"" in
      fetchScript
    check "VMH_VIRTIO_NETKVM_ARM64_ARCHIVE_OUT" in fetchScript
    check "VMH_VIRTIO_NETKVM_ARM64_DIR_OUT" in fetchScript

  test "windows-arm install-done marker is gated on OpenSSH success":
    let commands = windowsArmAutounattend().firstLogonCommands()
    let marker = commands[2].elementText("CommandLine")

    check commands[2].elementText("Description") ==
      "Write install-done sentinel after OpenSSH is ready"
    check "Test-Path -LiteralPath 'C:\\Windows\\Temp\\vmh-openssh-provision-failed'" in
      marker
    check "Get-Service -Name sshd" in marker
    check ".Status -ne 'Running'" in marker
    check "{ exit 0 }" in marker
    check "exit 1" notin marker
    check "Set-Content -LiteralPath 'C:\\Windows\\Temp\\repro-install-done'" in
      marker

  test "windows-arm FirstLogonCommands do not abort OOBE":
    let commands = windowsArmAutounattend().firstLogonCommands()

    for command in commands:
      check "exit 1" notin command.elementText("CommandLine")

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

  test "concurrent QEMU launches allocate distinct forwarded SSH ports":
    when defined(posix):
      let tmp = createTempDir("vmh-qemu-win-arm-port-allocation-", "")
      defer: removeDir(tmp)
      let stateDir = tmp / "state"
      let resultA = tmp / "result-a"
      let resultB = tmp / "result-b"
      let preferredPort = pickTcpPort(0)
      var workerA = startProcess(getAppFilename(), args = @[
        PortAllocationWorkerArg, stateDir, tmp / "vm-a", resultA,
        $preferredPort], options = {poParentStreams})
      var workerB = startProcess(getAppFilename(), args = @[
        PortAllocationWorkerArg, stateDir, tmp / "vm-b", resultB,
        $preferredPort], options = {poParentStreams})
      defer:
        if workerA.running:
          workerA.kill()
        if workerB.running:
          workerB.kill()
        workerA.close()
        workerB.close()

      let exitA = workerA.waitForExit(10_000)
      let exitB = workerB.waitForExit(10_000)
      check exitA == 0
      check exitB == 0
      check fileExists(resultA)
      check fileExists(resultB)

      if exitA == 0 and exitB == 0 and
         fileExists(resultA) and fileExists(resultB):
        let fieldsA = readFile(resultA).splitWhitespace()
        let fieldsB = readFile(resultB).splitWhitespace()
        check fieldsA.len == 2
        check fieldsB.len == 2
        if fieldsA.len == 2 and fieldsB.len == 2:
          let portA = parseInt(fieldsA[0])
          let portB = parseInt(fieldsB[0])
          let pidA = parseInt(fieldsA[1])
          let pidB = parseInt(fieldsB[1])
          defer:
            discard execCmd("/bin/kill -TERM " & $pidA)
            discard execCmd("/bin/kill -TERM " & $pidB)
          check portA != portB
          check preferredPort in [portA, portB]
    else:
      skip()

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
    check "nvme,drive=disk0,serial=winarm0,bootindex=1" in args
    check "virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27" in args
    let tpmArg = args[args.find("-chardev") + 1]
    check tpmArg.startsWith("socket,id=chrtpm,path=/tmp/vmh-qwa-tpm-")
    check tpmArg.endsWith(".sock")
    check "emulator,id=tpm0,chardev=chrtpm" in args
    check "tpm-tis-device,tpmdev=tpm0" in args
    check args.filterIt("e1000" in it or "e1000e" in it or
                        "usb-net" in it or "rtl8139" in it or
                        "virtio-net-device" in it or
                        "virtio-blk-device" in it).len == 0
    check "file:" & tmp / "serial.log" in args
    let monArg = args[args.find("-monitor") + 1]
    check monArg.startsWith("unix:/tmp/vmh-qwa-mon-")
    check monArg.endsWith(".sock,server=on,wait=off")
    check "-rtc" in args
    check args[args.find("-rtc") + 1] == "base=utc"
    check "base=localtime" notin args
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
    createDir(base / "tpm")
    writeFile(base / "tpm" / "tpm2-00.permall", "tpm-state")
    writeFile(base / "tpm" / ".lock", "stale-lock")

    let dest = state / "instances" / "vm"
    createEphemeralCopy(base, dest)
    check fileExists(dest / "windows.qcow2")
    check fileExists(dest / "AAVMF_VARS.fd")
    check fileExists(dest / "tpm" / "tpm2-00.permall")
    check not fileExists(dest / "tpm" / ".lock")
    check not fileExists(dest / "notes.txt")
    check readFile(base / "windows.qcow2") == "disk"
    check readFile(dest / "tpm" / "tpm2-00.permall") == "tpm-state"

  test "Windows SSH command quoting preserves argv boundaries and env":
    let env = {"VMH_TEST": "a&b'c", "VMH_SECOND": "two words"}.toTable
    let remote = buildWindowsRemoteCommand(env,
      @["powershell", "-NoProfile", "-Command", "Write-Output \"hello world\""])
    check remote == "$env:VMH_SECOND = 'two words'; $env:VMH_TEST = 'a&b''c'; & 'powershell' '-NoProfile' '-Command' 'Write-Output \"hello world\"'"

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
      let swtpm = tmp / "swtpm"
      writeExecutable(silent, "#!/bin/sh\nsleep 5\n")
      writeExecutable(sshpass, "#!/bin/sh\necho 'sshpass 1.10'\n")
      writeExecutable(swtpm, "#!/bin/sh\necho 'swtpm 0.10.1'\n")

      let b = newQemuWindowsArmBackend(qemuCmd = silent,
                                       swtpmCmd = swtpm,
                                       sshpassCmd = sshpass,
                                       probeTimeoutSec = 1)
      let started = epochTime()
      check not b.probeAvailability()
      check epochTime() - started < 3.0
    else:
      let b = newQemuWindowsArmBackend()
      check not b.probeAvailability()

  test "probeAvailability requires qemu, swtpm, and sshpass":
    when defined(macosx):
      let tmp = createTempDir("vmh-qemu-win-arm-probe-ok-", "")
      defer: removeDir(tmp)
      let qemu = tmp / "qemu-system-aarch64"
      let swtpm = tmp / "swtpm"
      let badSwtpm = tmp / "bad-swtpm"
      let sshpass = tmp / "sshpass"
      writeExecutable(qemu, "#!/bin/sh\necho 'QEMU emulator version 9.2.0 aarch64'\n")
      writeExecutable(swtpm, "#!/bin/sh\necho 'swtpm 0.10.1'\n")
      writeExecutable(badSwtpm, "#!/bin/sh\necho 'swtpm unavailable' >&2\nexit 42\n")
      writeExecutable(sshpass, "#!/bin/sh\necho 'sshpass 1.10'\n")

      let good = newQemuWindowsArmBackend(qemuCmd = qemu,
                                          swtpmCmd = swtpm,
                                          sshpassCmd = sshpass,
                                          probeTimeoutSec = 1)
      check good.probeAvailability()

      let missingTpm = newQemuWindowsArmBackend(qemuCmd = qemu,
                                                swtpmCmd = badSwtpm,
                                                sshpassCmd = sshpass,
                                                probeTimeoutSec = 1)
      check not missingTpm.probeAvailability()
    else:
      let b = newQemuWindowsArmBackend()
      check not b.probeAvailability()
