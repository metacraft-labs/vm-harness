## QemuWindowsArmBackend — direct QEMU/HVF Windows-on-ARM cached boot.
##
## This backend is intentionally narrower than UTM: it consumes a prebuilt
## directory containing ``windows.qcow2``, creates a per-run copy under a
## writable state directory, boots it with ``qemu-system-aarch64`` on macOS
## HVF, and reaches the guest through OpenSSH over user-mode networking with
## host port forwarding. It exists as an unblock path when UTM's control plane
## cannot enumerate or clone registered bundles.

import std/[algorithm, hashes, net, options, os, osproc, streams,
            strutils, tables, times]
when defined(posix):
  import std/posix
import ../types
import ../auto

type
  QemuWindowsArmBackend* = ref object of VmBackend
    qemuCmd*: string
    swtpmCmd*: string
    sshpassCmd*: string
    sshCmd*: string
    scpCmd*: string
    stateDir*: string
    ephemeralPrefix*: string
    sshUser*: string
    sshPassword*: string
    sshPort*: int
    bootTimeoutSec*: int
    sshReadyTimeoutSec*: int
    probeTimeoutSec*: int
    baselines*: Table[string, string]
    baselineCpus*: Table[string, int]
    baselineMemoryMB*: Table[string, int]
    qemuPids*: Table[string, int]
    swtpmPids*: Table[string, int]

const
  DefaultQemuWindowsArmPrefix* = "repro-vm-qemu-windows-arm"
  DefaultQemuWindowsArmUser* = "admin"
  DefaultQemuWindowsArmPassword* = "repro-windows-arm"
  QemuPortAllocationLockName = ".qemu-port-allocation.lock"
  QemuPortClaimTimeoutMs = 5000
  QemuPortAllocationAttempts = 5
  QemuSshAttempts = 5
  QemuSshRetryDelayMs = 2000

type
  PortAllocationLock* = object
    held*: bool
    when defined(posix):
      fd*: cint

proc defaultStateDir*(): string =
  let override = getEnv("VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR")
  if override.len > 0:
    return override
  getHomeDir() / ".local" / "state" / "vm-harness" / "qemu-windows-arm"

proc newQemuWindowsArmBackend*(qemuCmd: string = "qemu-system-aarch64",
                               swtpmCmd: string = "swtpm",
                               sshpassCmd: string = "sshpass",
                               sshCmd: string = "ssh",
                               scpCmd: string = "scp",
                               stateDir: string = "",
                               ephemeralPrefix: string = DefaultQemuWindowsArmPrefix,
                               sshUser: string = DefaultQemuWindowsArmUser,
                               sshPassword: string = DefaultQemuWindowsArmPassword,
                               sshPort: int = 2223,
                               bootTimeoutSec: int = 300,
                               sshReadyTimeoutSec: int = 300,
                               probeTimeoutSec: int = 10): QemuWindowsArmBackend =
  result = QemuWindowsArmBackend(
    id: biQemuWindowsArm,
    hostPlatform: hpMacosArm,
    supportedGuests: {goWindows},
    qemuCmd: qemuCmd,
    swtpmCmd: swtpmCmd,
    sshpassCmd: sshpassCmd,
    sshCmd: sshCmd,
    scpCmd: scpCmd,
    stateDir: (if stateDir.len > 0: stateDir else: defaultStateDir()),
    ephemeralPrefix: ephemeralPrefix,
    sshUser: sshUser,
    sshPassword: sshPassword,
    sshPort: sshPort,
    bootTimeoutSec: bootTimeoutSec,
    sshReadyTimeoutSec: sshReadyTimeoutSec,
    probeTimeoutSec: probeTimeoutSec,
    baselines: initTable[string, string](),
    baselineCpus: initTable[string, int](),
    baselineMemoryMB: initTable[string, int](),
    qemuPids: initTable[string, int](),
    swtpmPids: initTable[string, int]())

proc runProcessCapture(cmd: seq[string], cwd: string = "",
                      timeoutSec: int = 0,
                      mergeStderr: bool = true): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "runProcessCapture: empty cmd")
  let start = epochTime()
  let opts = if mergeStderr: {poUsePath, poStdErrToStdOut} else: {poUsePath}
  var p = startProcess(cmd[0], workingDir = cwd, args = cmd[1 .. ^1],
                       options = opts)
  defer: p.close()
  let outStream = p.outputStream
  let errStream = if mergeStderr: nil else: p.errorStream
  var timedOut = false
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while p.running:
    if timeoutSec > 0 and epochTime() > deadline:
      timedOut = true
      p.terminate()
      sleep(200)
      if p.running:
        try: p.kill()
        except CatchableError: discard
      break
    sleep(50)
  let code = p.waitForExit(timeout = -1)
  if timedOut:
    return ExecResult(exitCode: -1, stdout: "",
                      stderr: "vm-harness: process timed out after " &
                              $timeoutSec & "s",
                      elapsedMs: int((epochTime() - start) * 1000))
  let stdout = outStream.readAll()
  let stderr = if errStream != nil: errStream.readAll() else: ""
  ExecResult(exitCode: code, stdout: stdout, stderr: stderr,
             elapsedMs: int((epochTime() - start) * 1000))

proc validateWindowsArmVmDir*(dir: string): string =
  ## Return the absolute baseline directory when it contains windows.qcow2.
  if dir.len == 0:
    raise newException(ValueError, "Windows ARM baseline directory is empty")
  if not dirExists(dir):
    raise newException(ValueError, "Windows ARM baseline directory not found: " & dir)
  let disk = dir / "windows.qcow2"
  if not fileExists(disk):
    raise newException(ValueError,
      "Windows ARM baseline directory must contain windows.qcow2: " & dir)
  absolutePath(dir)

proc ephemeralName*(prefix: string, epochMs: int64, pid: int): string =
  prefix & "-" & $epochMs & "-" & $pid

proc ephemeralDirFor*(stateDir, name: string): string =
  stateDir / "instances" / name

proc tcpPortAvailable(port: int): bool =
  try:
    var s = newSocket()
    defer: s.close()
    s.bindAddr(Port(port), "127.0.0.1")
    true
  except OSError:
    false

proc pickTcpPort*(preferred: int): int =
  if preferred > 0 and tcpPortAvailable(preferred):
    return preferred
  var s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])

proc acquirePortAllocationLock*(stateDir: string): PortAllocationLock =
  ## Serialize the short port-selection/QEMU-bind window across vm-harness
  ## processes. The advisory lock is tied to the file descriptor, so the OS
  ## releases it automatically if a launcher crashes.
  when defined(posix):
    createDir(stateDir)
    let lockPath = stateDir / QemuPortAllocationLockName
    let fd = posix.open(lockPath.cstring, O_CREAT or O_RDWR, Mode(0o600))
    if fd < 0:
      raise newException(OSError,
        "QemuWindowsArmBackend: cannot open port allocation lock " & lockPath)
    if posix.lockf(fd, F_LOCK, Off(0)) != 0:
      discard posix.close(fd)
      raise newException(OSError,
        "QemuWindowsArmBackend: cannot acquire port allocation lock " & lockPath)
    result = PortAllocationLock(held: true, fd: fd)
  else:
    raise newException(OSError,
      "QemuWindowsArmBackend: atomic port allocation requires POSIX lockf")

proc releasePortAllocationLock*(allocationLock: var PortAllocationLock) =
  when defined(posix):
    if allocationLock.held:
      discard posix.lockf(allocationLock.fd, F_ULOCK, Off(0))
      discard posix.close(allocationLock.fd)
      allocationLock.held = false
  else:
    allocationLock.held = false

proc shortSocketPath(prefix, vmDir: string): string =
  "/tmp" / (prefix & "-" & $abs(hash(vmDir)) & ".sock")

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc qemuFirmwareArgs(vmDir: string): seq[string] =
  let explicitCode = getEnv("VMH_QEMU_EFI_CODE")
  let explicitVars = getEnv("VMH_QEMU_EFI_VARS")
  let codeCandidates = @[
    explicitCode,
    vmDir / "QEMU_EFI.fd",
    vmDir / "edk2-aarch64-code.fd",
    vmDir / "AAVMF_CODE.fd",
    vmDir / "OVMF_CODE.fd"
  ]
  let varsCandidates = @[
    explicitVars,
    vmDir / "QEMU_VARS.fd",
    vmDir / "edk2-aarch64-vars.fd",
    vmDir / "AAVMF_VARS.fd",
    vmDir / "OVMF_VARS.fd"
  ]
  var code = ""
  var vars = ""
  for c in codeCandidates:
    if c.len > 0 and fileExists(c):
      code = c
      break
  for v in varsCandidates:
    if v.len > 0 and fileExists(v):
      vars = v
      break
  if code.len > 0 and vars.len > 0:
    return @[
      "-drive", "if=pflash,format=raw,readonly=on,file=" & code,
      "-drive", "if=pflash,format=raw,file=" & vars
    ]
  if code.len > 0:
    return @["-bios", code]
  @[]

proc buildQemuWindowsArmArgs*(vmDir: string, sshPort: int,
                              cpus: int = 4, memoryMB: int = 8192): seq[string] =
  let disk = vmDir / "windows.qcow2"
  let tpmSock = shortSocketPath("vmh-qwa-tpm", vmDir)
  let serialLog = vmDir / "serial.log"
  let monitorSock = shortSocketPath("vmh-qwa-mon", vmDir)
  result = @[
    "-accel", "hvf",
    "-machine", "virt,highmem=on",
    "-cpu", "host",
    "-m", $memoryMB,
    "-smp", $cpus,
    "-drive", "id=disk0,file=" & disk & ",format=qcow2,if=none,cache=writeback,discard=unmap",
    "-device", "nvme,drive=disk0,serial=winarm0,bootindex=1",
    "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:" & $sshPort & "-:22",
    "-device", "virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27",
    "-chardev", "socket,id=chrtpm,path=" & tpmSock,
    "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
    "-device", "tpm-tis-device,tpmdev=tpm0",
    "-device", "virtio-rng-device",
    "-device", "ramfb",
    "-display", "none",
    "-serial", "file:" & serialLog,
    "-monitor", "unix:" & monitorSock & ",server=on,wait=off",
    "-D", vmDir / "qemu.log",
    "-rtc", "base=utc",
    "-no-reboot"
  ]
  result.add(qemuFirmwareArgs(vmDir))

proc powershellLiteral*(s: string): string =
  "'" & s.replace("'", "''") & "'"

proc buildWindowsRemoteCommand*(env: Table[string, string],
                                cmd: seq[string]): string =
  if cmd.len == 0:
    raise newException(ValueError, "buildWindowsRemoteCommand: empty cmd")
  var inner = ""
  var envKeys: seq[string]
  for k in env.keys:
    envKeys.add(k)
  envKeys.sort()
  for k in envKeys:
    inner.add("$env:")
    inner.add(k)
    inner.add(" = ")
    inner.add(powershellLiteral(env[k]))
    inner.add("; ")
  inner.add("& ")
  inner.add(powershellLiteral(cmd[0]))
  if cmd.len > 1:
    for a in cmd[1 .. ^1]:
      inner.add(" ")
      inner.add(powershellLiteral(a))
  inner

proc sshArgsBase*(b: QemuWindowsArmBackend, port: int): seq[string] =
  @[
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4",
    "-p", $port,
    b.sshUser & "@127.0.0.1"
  ]

proc buildSshpassSshArgs*(b: QemuWindowsArmBackend, pwdFile: string,
                          port: int, remoteCommand: string): seq[string] =
  @[b.sshpassCmd, "-f", pwdFile, b.sshCmd] &
    b.sshArgsBase(port) & @[remoteCommand]

proc transientSshFailure*(execResult: ExecResult): bool =
  ## OpenSSH uses 255 for transport and authentication failures. Remote
  ## commands retain their own exit code, so retrying only 255 cannot replay a
  ## completed command that returned an application error.
  execResult.exitCode == 255

proc writePasswordFile(password: string): string =
  let path = getTempDir() / "vm-harness-qemu-win-arm-pwd-" &
             $getCurrentProcessId() & "-" & $int(epochTime() * 1000)
  writeFile(path, password)
  when defined(posix):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite})
    except CatchableError:
      discard
  path

proc cloneOneFile(src, dst: string) =
  when defined(macosx):
    let r = runProcessCapture(@["/bin/cp", "-c", src, dst], timeoutSec = 120)
    if r.exitCode == 0:
      return
  copyFile(src, dst)

proc createEphemeralCopy*(baselineDir, destDir: string) =
  let base = validateWindowsArmVmDir(baselineDir)
  if dirExists(destDir):
    removeDir(destDir)
  createDir(destDir)
  for kind, path in walkDir(base):
    if kind != pcFile:
      continue
    let name = extractFilename(path)
    if name == "windows.qcow2" or name.endsWith(".fd") or
       name.endsWith(".rom") or name.endsWith(".bin"):
      cloneOneFile(path, destDir / name)
  if dirExists(base / "tpm"):
    copyDir(base / "tpm", destDir / "tpm")
    try: removeFile(destDir / "tpm" / ".lock")
    except CatchableError: discard
  else:
    createDir(destDir / "tpm")

proc waitForSshReady*(b: QemuWindowsArmBackend, port: int,
                    timeoutSec: int): bool =
  let deadline = epochTime() + timeoutSec.float
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  while epochTime() < deadline:
    let cmd = b.buildSshpassSshArgs(pwdFile, port, "cmd /c \"echo ready\"")
    let r = runProcessCapture(cmd, timeoutSec = 20)
    if r.exitCode == 0 and "ready" in r.stdout:
      return true
    sleep(3000)
  false

proc startSwtpmInBackground*(b: QemuWindowsArmBackend, vmDir: string): int =
  let tpmDir = vmDir / "tpm"
  createDir(tpmDir)
  let sock = shortSocketPath("vmh-qwa-tpm", vmDir)
  try: removeFile(sock)
  except CatchableError: discard
  let args = @[
    "socket",
    "--tpm2",
    "--tpmstate", "dir=" & tpmDir,
    "--ctrl", "type=unixio,path=" & sock
  ]
  var p = startProcess(b.swtpmCmd, args = args,
                       # Keep the direct child PID. On Darwin poDaemon may
                       # detach through an intermediate process, leaving the
                       # real swtpm orphaned and impossible to reap reliably.
                       options = {poUsePath, poParentStreams},
                       workingDir = vmDir)
  result = p.processID
  let deadline = epochTime() + 3.0
  while epochTime() < deadline:
    if pathExists(sock):
      return
    if not p.running:
      raise newVmHarnessError($b.id, lpStartup,
        "QemuWindowsArmBackend: swtpm exited before creating socket " & sock)
    sleep(100)
  raise newVmHarnessError($b.id, lpStartup,
    "QemuWindowsArmBackend: swtpm did not create socket " & sock)

proc startQemuInBackground*(b: QemuWindowsArmBackend, vmDir: string,
                            sshPort, cpus, memoryMB: int): int =
  let args = buildQemuWindowsArmArgs(vmDir, sshPort, cpus, memoryMB)
  var p = startProcess(b.qemuCmd, args = args,
                       # Keep QEMU as our direct child so the PID stored in the
                       # VmHandle is the process stopAndCleanup must terminate.
                       options = {poUsePath, poParentStreams},
                       workingDir = vmDir)
  result = p.processID

proc childProcessExited(pid: int): bool =
  when defined(posix):
    var status: cint
    let waited = posix.waitpid(Pid(pid), status, WNOHANG)
    if waited == Pid(pid):
      return true
    if waited < Pid(0):
      return posix.kill(Pid(pid), cint(0)) != 0
    false
  else:
    false

proc stopStartedProcess(pid: int) =
  when defined(posix):
    discard posix.kill(Pid(pid), SIGTERM)
    let deadline = epochTime() + 2.0
    while epochTime() < deadline:
      if childProcessExited(pid):
        return
      sleep(25)
    discard posix.kill(Pid(pid), SIGKILL)
    let killDeadline = epochTime() + 2.0
    while epochTime() < killDeadline:
      if childProcessExited(pid):
        return
      sleep(25)
  else:
    discard runProcessCapture(@["/bin/kill", "-TERM", $pid], timeoutSec = 5)

proc waitForTcpPortClaim(pid, port, timeoutMs: int): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if childProcessExited(pid):
      return false
    if not tcpPortAvailable(port):
      return true
    sleep(25)
  false

proc startQemuWithAllocatedPort*(b: QemuWindowsArmBackend, vmDir: string,
                                 cpus, memoryMB: int):
                                 tuple[sshPort: int, pid: int] =
  ## Keep the inter-process allocation lock until QEMU has claimed the chosen
  ## port. This closes the race between probing a free port and QEMU binding
  ## it when multiple ephemeral guests start at the same time.
  var allocationLock = acquirePortAllocationLock(b.stateDir)
  defer: releasePortAllocationLock(allocationLock)

  for attempt in 0 ..< QemuPortAllocationAttempts:
    let preferred = if attempt == 0: b.sshPort else: 0
    let port = pickTcpPort(preferred)
    let pid = b.startQemuInBackground(vmDir, port, cpus, memoryMB)
    if waitForTcpPortClaim(pid, port, QemuPortClaimTimeoutMs):
      return (sshPort: port, pid: pid)
    stopStartedProcess(pid)

  raise newVmHarnessError($b.id, lpStartup,
    "QemuWindowsArmBackend: QEMU failed to claim an allocated SSH port after " &
    $QemuPortAllocationAttempts & " attempts")

method probeAvailability*(b: QemuWindowsArmBackend): bool =
  when defined(macosx):
    try:
      let q = runProcessCapture(@[b.qemuCmd, "--version"],
                                timeoutSec = b.probeTimeoutSec)
      if q.exitCode != 0:
        return false
      if "aarch64" notin (q.stdout & q.stderr).toLowerAscii and
         "qemu emulator" notin (q.stdout & q.stderr).toLowerAscii:
        return false
      let t = runProcessCapture(@[b.swtpmCmd, "--version"],
                                timeoutSec = b.probeTimeoutSec)
      if t.exitCode != 0:
        return false
      let s = runProcessCapture(@[b.sshpassCmd, "-V"], timeoutSec = 10)
      return "sshpass" in (s.stdout & s.stderr).toLowerAscii
    except CatchableError:
      return false
  else:
    false

method provisionBaseline*(b: QemuWindowsArmBackend, spec: BaselineSpec) =
  let source = if spec.sourceImage.len > 0: spec.sourceImage else: spec.name
  let baselineDir =
    try:
      validateWindowsArmVmDir(source)
    except ValueError as e:
      raise newVmHarnessError($b.id, lpProvisioning,
        "QemuWindowsArmBackend: " & e.msg)
  createDir(b.stateDir / "instances")
  b.baselines[spec.name] = baselineDir
  b.baselineCpus[spec.name] = if spec.cpus > 0: spec.cpus else: 4
  b.baselineMemoryMB[spec.name] = if spec.memoryMB > 0: spec.memoryMB else: 8192
  if "ephemeralPrefix" in spec.backendOptions:
    b.ephemeralPrefix = spec.backendOptions["ephemeralPrefix"]

method revertToBaseline*(b: QemuWindowsArmBackend, baselineName: string): VmHandle =
  let baselineDir =
    if baselineName in b.baselines:
      b.baselines[baselineName]
    else:
      try:
        validateWindowsArmVmDir(baselineName)
      except ValueError as e:
        raise newVmHarnessError($b.id, lpRevert,
          "QemuWindowsArmBackend: " & e.msg)
  let name = ephemeralName(b.ephemeralPrefix, int64(epochTime() * 1000),
                           getCurrentProcessId())
  let vmDir = ephemeralDirFor(b.stateDir, name)
  createEphemeralCopy(baselineDir, vmDir)
  let cpus = if baselineName in b.baselineCpus: b.baselineCpus[baselineName] else: 4
  let memoryMB =
    if baselineName in b.baselineMemoryMB: b.baselineMemoryMB[baselineName]
    else: 8192
  let swtpmPid = b.startSwtpmInBackground(vmDir)
  b.swtpmPids[name] = swtpmPid
  var started: tuple[sshPort: int, pid: int]
  try:
    started = b.startQemuWithAllocatedPort(vmDir, cpus, memoryMB)
  except CatchableError:
    let vm = VmHandle(backend: b, name: name, baseline: baselineName,
                      extra: {"vmDir": vmDir, "swtpmPid": $swtpmPid}.toTable)
    b.stopAndCleanup(vm, deleteVm = true)
    raise
  let port = started.sshPort
  let pid = started.pid
  b.qemuPids[name] = pid
  if not b.waitForSshReady(port, b.sshReadyTimeoutSec):
    let vm = VmHandle(backend: b, name: name, baseline: baselineName,
                      ipAddress: some("127.0.0.1"), sshPort: port,
                      sshUser: b.sshUser,
                      sshAuth: SshAuth(kind: saPassword, password: b.sshPassword),
                      extra: {"vmDir": vmDir, "qemuPid": $pid,
                              "swtpmPid": $swtpmPid}.toTable)
    b.stopAndCleanup(vm, deleteVm = true)
    raise (ref GuestBootFailureError)(
      msg: "QemuWindowsArmBackend: SSH did not become ready on " &
           "127.0.0.1:" & $port & " within " & $b.sshReadyTimeoutSec & "s",
      backend: $b.id, phase: lpStartup)
  VmHandle(
    backend: b,
    name: name,
    baseline: baselineName,
    ipAddress: some("127.0.0.1"),
    sshPort: port,
    sshUser: b.sshUser,
    sshAuth: SshAuth(kind: saPassword, password: b.sshPassword),
    extra: {"vmDir": vmDir, "baselineDir": baselineDir, "qemuPid": $pid,
            "swtpmPid": $swtpmPid}.toTable)

method execInGuest*(b: QemuWindowsArmBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult =
  if cmd.len == 0:
    raise newException(ValueError, "execInGuest: empty cmd")
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  let remote = buildWindowsRemoteCommand(env, cmd)
  let sshCmd = b.buildSshpassSshArgs(pwdFile, vm.sshPort, remote)
  if stdin.len == 0:
    var last = ExecResult(exitCode: -1)
    for attempt in 1 .. QemuSshAttempts:
      last = runProcessCapture(sshCmd, timeoutSec = timeoutSec)
      if not transientSshFailure(last) or attempt == QemuSshAttempts:
        return last
      # Windows OpenSSH can accept the readiness probe and briefly reject the
      # next authentication while the service finishes settling. Exit 255 is
      # SSH's transport/authentication failure code; remote command failures
      # retain their own exit code and are never replayed.
      sleep(QemuSshRetryDelayMs)
    return last
  let start = epochTime()
  var p = startProcess(sshCmd[0], args = sshCmd[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  p.inputStream.write(stdin)
  p.inputStream.close()
  let outStream = p.outputStream
  var stdout = ""
  let deadline = if timeoutSec > 0: epochTime() + timeoutSec.float else: 0.0
  while true:
    var chunk = newString(4096)
    let n = outStream.readData(addr chunk[0], chunk.len)
    if n > 0:
      chunk.setLen(n)
      stdout.add(chunk)
    elif n == 0:
      if not p.running: break
      if timeoutSec > 0 and epochTime() > deadline:
        p.terminate()
        return ExecResult(exitCode: -1, stdout: stdout, stderr: "",
                          elapsedMs: int((epochTime() - start) * 1000))
      sleep(50)
  ExecResult(exitCode: p.waitForExit(timeout = -1), stdout: stdout,
             stderr: "", elapsedMs: int((epochTime() - start) * 1000))

proc scpCopy*(b: QemuWindowsArmBackend, port: int, src, dest: string,
              toGuest: bool, recursive: bool = true,
              timeoutSec: int = 600) =
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  var args = @[b.sshpassCmd, "-f", pwdFile, b.scpCmd,
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "PreferredAuthentications=password",
    "-o", "PubkeyAuthentication=no",
    "-o", "IdentitiesOnly=yes",
    "-o", "LogLevel=ERROR",
    "-o", "ConnectTimeout=15",
    "-P", $port]
  if recursive:
    args.add("-r")
  if toGuest:
    args.add(src)
    args.add(b.sshUser & "@127.0.0.1:" & dest)
  else:
    args.add(b.sshUser & "@127.0.0.1:" & src)
    args.add(dest)
  let deadline = epochTime() + timeoutSec.float
  var last = ExecResult(exitCode: -1)
  var attempt = 0
  while epochTime() < deadline:
    inc attempt
    let remaining = max(1, int(deadline - epochTime()))
    last = runProcessCapture(args, timeoutSec = min(30, remaining))
    if last.exitCode == 0:
      return
    if attempt >= QemuSshAttempts:
      break
    sleep(QemuSshRetryDelayMs)
  raise newVmHarnessError($b.id, lpCopy,
    "scp " & (if toGuest: "to" else: "from") &
    " Windows ARM guest failed after " & $attempt & " attempts (exit " &
    $last.exitCode & "): " & last.stdout & last.stderr)

method copyToGuest*(b: QemuWindowsArmBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) =
  if not fileExists(hostPath) and not dirExists(hostPath):
    raise newVmHarnessError($b.id, lpCopy,
      "QemuWindowsArmBackend.copyToGuest: source not found: " & hostPath)
  b.scpCopy(vm.sshPort, hostPath, guestPath,
            toGuest = true, recursive = dirExists(hostPath))

method copyFromGuest*(b: QemuWindowsArmBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) =
  createDir(parentDir(hostPath))
  b.scpCopy(vm.sshPort, guestPath, hostPath, toGuest = false, recursive = true)

method installArgvTraceShim*(b: QemuWindowsArmBackend, vm: VmHandle,
                            shim: ArgvTraceShim) =
  raise newException(BackendUnavailableError,
    "installArgvTraceShim is not implemented for qemu-windows-arm yet")

method stopAndCleanup*(b: QemuWindowsArmBackend, vm: VmHandle,
                      deleteVm: bool = true) =
  try:
    let pidText = vm.extra.getOrDefault("qemuPid", "")
    if pidText.len > 0:
      discard runProcessCapture(@["/bin/kill", "-TERM", pidText], timeoutSec = 5)
      sleep(1000)
      discard runProcessCapture(@["/bin/kill", "-KILL", pidText], timeoutSec = 5)
    if vm.name in b.qemuPids:
      b.qemuPids.del(vm.name)
    let swtpmPidText = vm.extra.getOrDefault("swtpmPid", "")
    if swtpmPidText.len > 0:
      discard runProcessCapture(@["/bin/kill", "-TERM", swtpmPidText], timeoutSec = 5)
      sleep(500)
      discard runProcessCapture(@["/bin/kill", "-KILL", swtpmPidText], timeoutSec = 5)
    if vm.name in b.swtpmPids:
      b.swtpmPids.del(vm.name)
    if deleteVm:
      let vmDir = vm.extra.getOrDefault("vmDir", "")
      if vmDir.len > 0 and dirExists(vmDir):
        removeDir(vmDir)
  except CatchableError:
    discard

registerBackend(biQemuWindowsArm,
  proc(): VmBackend =
    newQemuWindowsArmBackend(
      qemuCmd = getEnv("VMH_QEMU_WINDOWS_ARM_QEMU_CMD", "qemu-system-aarch64"),
      swtpmCmd = getEnv("VMH_QEMU_WINDOWS_ARM_SWTPM_CMD", "swtpm"),
      sshpassCmd = getEnv("VMH_QEMU_WINDOWS_ARM_SSHPASS_CMD", "sshpass"),
      sshCmd = getEnv("VMH_QEMU_WINDOWS_ARM_SSH_CMD", "ssh"),
      scpCmd = getEnv("VMH_QEMU_WINDOWS_ARM_SCP_CMD", "scp"),
      stateDir = getEnv("VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR", ""),
      ephemeralPrefix = getEnv("VMH_QEMU_WINDOWS_ARM_EPHEMERAL_PREFIX",
                               DefaultQemuWindowsArmPrefix),
      sshUser = getEnv("VMH_QEMU_WINDOWS_ARM_SSH_USER",
                       DefaultQemuWindowsArmUser),
      sshPassword = getEnv("VMH_QEMU_WINDOWS_ARM_SSH_PASSWORD",
                           DefaultQemuWindowsArmPassword),
      sshPort = parseInt(getEnv("VMH_QEMU_WINDOWS_ARM_SSH_PORT", "2223")),
      bootTimeoutSec = parseInt(getEnv("VMH_QEMU_WINDOWS_ARM_BOOT_TIMEOUT", "300")),
      sshReadyTimeoutSec = parseInt(getEnv("VMH_QEMU_WINDOWS_ARM_SSH_TIMEOUT", "300")),
      probeTimeoutSec = parseInt(getEnv("VMH_QEMU_WINDOWS_ARM_PROBE_TIMEOUT", "10"))))
