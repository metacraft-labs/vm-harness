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

## Windows applies RunSynchronousCommand in `Order` sequence; a gap or a
## repeat makes Setup skip or re-run a step. THAT is the property worth
## asserting. Pinning the exact count instead just breaks every time a step is
## legitimately added -- which is what happened when PowerShell 7 provisioning
## was staged here, and it says nothing about correctness either way.
proc ordersAreContiguousFrom1(commands: seq[XmlNode]): bool =
  commands.mapIt(it.elementText("Order")) == toSeq(1 .. commands.len).mapIt($it)

## Locate by Description, not by index, for the reason spelled out on the
## install-done test below: inserting a command shifts every later position,
## and an index-pinned lookup then asserts against the WRONG command while
## still passing or failing for reasons unrelated to its name.
proc commandDescribed(commands: seq[XmlNode], description: string): XmlNode =
  for command in commands:
    if command.elementText("Description") == description:
      return command

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
    check commands.ordersAreContiguousFrom1()

    let command = commands.commandDescribed("Stage OpenSSH provisioning script locally")
    check command != nil
    # A nil here would crash the binary and hide the rest of the verdict; the
    # content checks below then fail on their own terms instead.
    let stage = if command == nil: "" else: command.elementText("Path")
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\provision-openssh.ps1" in stage
    check "copy /Y %i:\\provision-openssh.ps1 C:\\Windows\\Temp\\provision-openssh.ps1" in
      stage

  test "windows-arm specialize stages offline OpenSSH ARM64 zip locally when present":
    let commands = windowsArmAutounattend().specializeDeploymentCommands()
    check commands.ordersAreContiguousFrom1()

    let command = commands.commandDescribed("Stage OpenSSH ARM64 portable zip locally when present")
    check command != nil
    # A nil here would crash the binary and hide the rest of the verdict; the
    # content checks below then fail on their own terms instead.
    let stage = if command == nil: "" else: command.elementText("Path")
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\openssh\\OpenSSH-ARM64.zip" in stage
    check "copy /Y %i:\\openssh\\OpenSSH-ARM64.zip C:\\Windows\\Temp\\OpenSSH-ARM64.zip" in
      stage

  test "windows-arm specialize stages offline VirtIO NetKVM ARM64 driver locally when present":
    let commands = windowsArmAutounattend().specializeDeploymentCommands()
    check commands.ordersAreContiguousFrom1()

    let command = commands.commandDescribed("Stage VirtIO NetKVM ARM64 driver locally when present")
    check command != nil
    # A nil here would crash the binary and hide the rest of the verdict; the
    # content checks below then fail on their own terms instead.
    let stage = if command == nil: "" else: command.elementText("Path")
    check stage.len < 260
    check "for %i in (D E F G H)" in stage
    check "if exist %i:\\virtio\\NetKVM\\w11\\ARM64\\netkvm.inf" in stage
    check "xcopy /E /I /Y %i:\\virtio C:\\Windows\\Temp\\virtio" in stage

  test "windows-arm FirstLogon launches staged local OpenSSH provisioning script":
    # Located by Description, not by index, for the reason spelled out on
    # the install-done test below: inserting a FirstLogonCommand (the
    # credential and power-policy hardening steps did) shifts every later
    # position, and an index-pinned lookup then asserts against the WRONG
    # command instead of reporting a missing one. Order contiguity is
    # covered for every pass of every answer file by
    # tests/unit/t_windows_golden_recipe_hardening.nim.
    let commands = windowsArmAutounattend().firstLogonCommands()
    var provision = ""
    var found = false
    for command in commands:
      if command.elementText("Description") ==
          "Provision OpenSSH Server with diagnostics":
        provision = command.elementText("CommandLine")
        found = true
        break

    check found
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
    # Located by Description rather than by a hardcoded index: inserting a new
    # FirstLogonCommand (as the Git for Windows provisioning step did) shifts
    # every later position, and an index-pinned lookup then silently asserts
    # against the WRONG command instead of reporting a missing one.
    let commands = windowsArmAutounattend().firstLogonCommands()
    var marker = ""
    var found = false
    for command in commands:
      if command.elementText("Description") ==
          "Write install-done sentinel after OpenSSH is ready":
        marker = command.elementText("CommandLine")
        found = true
        break

    check found
    check "Test-Path -LiteralPath 'C:\\Windows\\Temp\\vmh-openssh-provision-failed'" in
      marker
    check "Get-Service -Name sshd" in marker
    check ".Status -ne 'Running'" in marker
    check "{ exit 0 }" in marker
    check "exit 1" notin marker
    check "Set-Content -LiteralPath 'C:\\Windows\\Temp\\repro-install-done'" in
      marker

  test "windows-arm provisions Git for Windows and stages its gate":
    # Git for Windows supplies bash.exe; without it every GitHub Actions
    # `shell: bash` step on a clone of this golden fails with
    # "bash: command not found". The install step must therefore exist, must
    # select the arm64 asset, and must not be able to wedge OOBE.
    let xml = windowsArmAutounattend()
    var gitCommand = ""
    for command in xml.firstLogonCommands():
      if "provision-git.ps1" in command.elementText("CommandLine"):
        gitCommand = command.elementText("CommandLine")
        break
    check gitCommand.len > 0
    check "-Arch arm64" in gitCommand
    check "exit 0" in gitCommand

    # The install media is detached before FirstLogonCommands on this recipe,
    # so both scripts must be copied to C:\ during the SPECIALIZE pass.
    var stagedProvision = false
    var stagedGate = false
    for command in xml.specializeDeploymentCommands():
      let path = command.elementText("Path")
      if "provision-git.ps1" in path and "C:\\Windows\\Temp" in path:
        stagedProvision = true
      if "assert-git-provisioned.ps1" in path and "C:\\Windows\\Temp" in path:
        stagedGate = true
    check stagedProvision
    # provision-git.ps1 exits 0 even on failure so it cannot wedge the chain;
    # assert-git-provisioned.ps1 is what turns that into a refusal to ship a
    # Git-less golden, and this recipe is captured by a MANUAL sysprep, so the
    # gate has to already be inside the guest.
    check stagedGate

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
            discard execCmd("kill -TERM " & $pidA)
            discard execCmd("kill -TERM " & $pidB)
          check portA != portB
          check preferredPort in [portA, portB]
    else:
      skip()

  test "QEMU cleanup terminates the direct child and releases its port":
    when defined(posix):
      let tmp = createTempDir("vmh-qemu-win-arm-cleanup-", "")
      defer: removeDir(tmp)
      let vmDir = tmp / "vm"
      createDir(vmDir)
      writeFile(vmDir / "windows.qcow2", "fake-qcow2")
      putEnv(PortListenerHelperEnv, "1")
      defer: delEnv(PortListenerHelperEnv)
      let preferredPort = pickTcpPort(0)
      let backend = newQemuWindowsArmBackend(
        qemuCmd = getAppFilename(), stateDir = tmp / "state",
        sshPort = preferredPort)
      let started = backend.startQemuWithAllocatedPort(vmDir, 1, 64)
      let vm = VmHandle(
        backend: backend,
        name: "cleanup-test",
        extra: {"vmDir": vmDir, "qemuPid": $started.pid}.toTable)

      backend.stopAndCleanup(vm, deleteVm = true)

      check pickTcpPort(preferredPort) == preferredPort
      check not dirExists(vmDir)
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
    check tpmArg.startsWith("socket,id=chrtpm,path=")
    check "vmh-qwa-tpm-" in tpmArg
    check tpmArg.endsWith(".sock")
    check "emulator,id=tpm0,chardev=chrtpm" in args
    check "tpm-tis-device,tpmdev=tpm0" in args
    check args.filterIt("e1000" in it or "e1000e" in it or
                        "usb-net" in it or "rtl8139" in it or
                        "virtio-net-device" in it or
                        "virtio-blk-device" in it).len == 0
    check "file:" & tmp / "serial.log" in args
    let monArg = args[args.find("-monitor") + 1]
    check monArg.startsWith("unix:")
    check "vmh-qwa-mon-" in monArg
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

  test "Windows SSH retries only transport and authentication failures":
    check transientSshFailure(ExecResult(exitCode: 255))
    check not transientSshFailure(ExecResult(exitCode: 1))
    check not transientSshFailure(ExecResult(exitCode: 0))

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

suite "QemuWindowsArmBackend golden build":
  ## The golden install boot and the guards that keep a rebuild from
  ## corrupting the instances running on top of the golden it replaces.

  test "install argv boots the media and defers the empty target disk":
    let tmp = createTempDir("vmh-qemu-win-arm-install-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")
    writeFile(tmp / "QEMU_EFI.fd", "")
    let winIso = tmp / "win11-arm64.iso"
    let unattendIso = tmp / "autounattend.iso"
    writeFile(winIso, "")
    writeFile(unattendIso, "")

    let args = buildQemuWindowsArmInstallArgs(
      tmp, winIso, unattendIso, 2240, cpus = 6, memoryMB = 12288)

    # Install media first, answer file second, target disk last. The disk is
    # empty at this point, so anything else leaves the firmware with nothing
    # bootable.
    check "usb-storage,bus=usb.0,drive=installcd,bootindex=0" in args
    check "usb-storage,bus=usb.0,drive=unattendcd,bootindex=1" in args
    check "nvme,drive=disk0,serial=winarm0,bootindex=2" in args

    # aarch64 virt has no built-in USB or IDE controller to hang a CD off.
    check "qemu-xhci,id=usb" in args
    check "id=installcd,file=" & winIso & ",media=cdrom,readonly=on,if=none" in args
    check "id=unattendcd,file=" & unattendIso &
          ",media=cdrom,readonly=on,if=none" in args

    # Windows setup reboots several times before OOBE. Exiting on the first
    # one leaves a half-installed disk that looks like a hung build.
    check "-no-reboot" notin args

    # The install writes the base disk directly; overlays are a per-job
    # concern and must not appear here.
    check "id=disk0,file=" & tmp / "windows.qcow2" &
          ",format=qcow2,if=none,cache=writeback,discard=unmap" in args

    # Still headless, still measurable.
    check "-display" in args
    check args[args.find("-display") + 1] == "none"
    check args.anyIt(it.startsWith("file:") and it.endsWith("serial.log"))

  test "the per-job boot keeps -no-reboot and its own boot order":
    let tmp = createTempDir("vmh-qemu-win-arm-runargv-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")

    let args = buildQemuWindowsArmArgs(tmp, 2241)
    check "-no-reboot" in args
    check "nvme,drive=disk0,serial=winarm0,bootindex=1" in args
    check not args.anyIt("usb-storage" in it)

  test "a golden build refuses to overwrite an existing golden":
    let tmp = createTempDir("vmh-qemu-win-arm-guard-", "")
    defer: removeDir(tmp)
    let existing = tmp / "win-arm-runner-0001"
    createDir(existing)
    writeFile(existing / "windows.qcow2", "pretend this backs a live overlay")

    # Overwriting it would not fail at the qcow2 layer: every overlay naming
    # it as a backing store would silently continue against different data.
    expect VmHarnessError:
      prepareGoldenBuildDir(existing)
    check readFile(existing / "windows.qcow2") ==
      "pretend this backs a live overlay"

  test "a golden build accepts a fresh or empty directory":
    let tmp = createTempDir("vmh-qemu-win-arm-fresh-", "")
    defer: removeDir(tmp)
    let fresh = tmp / "win-arm-runner-0002"
    prepareGoldenBuildDir(fresh)
    check dirExists(fresh)
    # Re-running before any disk exists is fine; a failed build leaves a
    # directory nothing ever points at.
    prepareGoldenBuildDir(fresh)
    check dirExists(fresh)

  test "golden disk allocation rejects a nonsense size":
    let tmp = createTempDir("vmh-qemu-win-arm-size-", "")
    defer: removeDir(tmp)
    expect VmHarnessError:
      createGoldenDisk("qemu-img", tmp, 0)

  test "an overlay records the resolved golden, not the pointer":
    when defined(posix):
      let tmp = createTempDir("vmh-qemu-win-arm-symlink-", "")
      defer: removeDir(tmp)
      let versioned = tmp / "win-arm-runner-0003"
      createDir(versioned)
      writeFile(versioned / "windows.qcow2", "golden")
      let pointer = tmp / "win-arm-runner"
      createSymlink(versioned, pointer)

      let log = tmp / "qemu-img.log"
      let fakeQemuImg = tmp / "qemu-img"
      writeFile(fakeQemuImg, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> '" & log &
                             "'\nexit 0\n")
      setFilePermissions(fakeQemuImg, {fpUserRead, fpUserWrite, fpUserExec})

      createEphemeralOverlay(pointer, tmp / "instance", fakeQemuImg)

      let recorded = readFile(log)
      # Recording the pointer would mean the next build's flip repoints a
      # live instance's backing store at a different disk.
      check versioned / "windows.qcow2" in recorded
      check (pointer / "windows.qcow2") notin recorded
    else:
      skip()

suite "Golden build space precondition":
  ## Pure policy, so the thresholds can be exercised without a filesystem.

  setup:
    delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")

  test "a build that cannot finish is refused":
    let v = goldenBuildSpaceVerdict(freeGB = 40, diskGB = QwaDefaultGoldenDiskGB)
    check v.fatal
    check "refusing to start a golden build" in v.message
    check "40GB free" in v.message

  test "a tight but survivable build warns instead of failing":
    # Enough for the image, not enough to also absorb a saturated fleet.
    let v = goldenBuildSpaceVerdict(freeGB = 100, diskGB = QwaDefaultGoldenDiskGB)
    check not v.fatal
    check "concurrent CI" in v.message

  test "an idle host with room says nothing":
    let v = goldenBuildSpaceVerdict(
      freeGB = QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB +
               QwaFleetPeakGB + 1,
      diskGB = QwaDefaultGoldenDiskGB)
    check not v.fatal
    check v.message == ""

  test "a smaller requested image lowers the floor":
    # qcow2 cannot outgrow its requested size, so a 20GB image needs less
    # than the full install-peak estimate.
    check qwaGoldenFloorGB(20) == 20 + QwaGoldenBuildSlackGB
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) ==
      QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB
    check not goldenBuildSpaceVerdict(freeGB = 40, diskGB = 20).fatal
    check goldenBuildSpaceVerdict(freeGB = 40,
                                  diskGB = QwaDefaultGoldenDiskGB).fatal

  test "an operator can override the estimate":
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "5")
    defer: delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) == 5
    check not goldenBuildSpaceVerdict(freeGB = 10,
                                      diskGB = QwaDefaultGoldenDiskGB).fatal

  test "a garbage override falls back to the computed floor":
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "not-a-number")
    defer: delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    check qwaGoldenFloorGB(QwaDefaultGoldenDiskGB) ==
      QwaGoldenInstallPeakGB + QwaGoldenBuildSlackGB

  test "unknown free space proceeds rather than blocking":
    # A failed statvfs must not be reported as a full disk.
    let warning = checkGoldenBuildSpace("/nonexistent-path-for-vmh-test",
                                        QwaDefaultGoldenDiskGB)
    check "could not determine free space" in warning

  test "free space on a real path is plausible":
    let tmp = createTempDir("vmh-qemu-win-arm-space-", "")
    defer: removeDir(tmp)
    when defined(posix):
      check freeSpaceGB(tmp) >= 0
    else:
      check freeSpaceGB(tmp) == -1
