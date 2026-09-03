## QemuBootBackend — daemon-less direct-boot backend for x86_64 guests.
##
## *What it is for.* Boot a disk image (or install ISO) under a
## ``qemu-system-x86_64`` process this library owns, capture the guest's
## serial console into a durable host-side log, and assert an ordered
## sequence of regex lines against it. It is the substrate every
## boot-time gate uses on Linux.
##
## *Why it is not the libvirt backend.* ``backends/libvirt.nim`` already
## implements ``bootFromMedia`` + ``captureSerial`` + ``expectLine``, and
## for a long-lived, networked, pool-managed guest it is the right
## adapter. It is the wrong one for a boot-assertion gate:
##
## - It requires ``virt-install`` and a running ``libvirtd`` the caller
##   has authorisation on. A gate whose whole purpose is to prove the
##   serial-expect engine works must not be able to skip because a
##   system daemon is absent, and a package that pulls in a Python +
##   GTK closure is a poor thing to make a unit-ish gate depend on.
## - It defines a domain in a *shared, host-global namespace*. On a host
##   that also runs production CI, a leaked transient domain is a real
##   hazard; an owned child process that dies with its parent is not.
## - Its file-backed serial device is output-only:
##   ``LibvirtBackend.serialSend`` raises by construction. Driving a
##   login prompt — which the vTPM guest gate needs next — is not
##   reachable from there without changing the device model anyway.
##
## What this backend deliberately does NOT do is re-implement pattern
## matching. Reading and matching go through ``../serial.nim``'s
## ``SerialLineBuffer`` / ``expectLineImpl``, the same cursor-advancing
## PCRE engine every other backend uses, so there is exactly one
## serial-expect implementation in the tree.
##
## *Serial device model.* One ``-chardev socket`` with QEMU's own
## ``logfile=`` option, wired to ``-serial``:
##
## - QEMU writes every byte the guest emits to ``logfile`` from the
##   first firmware byte onward, whether or not anything is connected
##   to the socket. Reads therefore poll a plain file (the same shape
##   as the libvirt backend's ``pumpSerialFile``) with no reader thread
##   and no possibility of losing early output to a connect race.
## - ``serialSend`` connects to the socket, writes, drains briefly and
##   disconnects. Nothing is lost by disconnecting because the log — not
##   the socket — is the read path, and never holding the connection
##   open means the harness can never back-pressure the guest's console
##   by failing to drain it.
##
## *Ownership and teardown.* Everything a run creates lives under one
## per-VM run directory: the CoW overlay, the writable NVRAM copy, the
## chardev socket and QEMU's own log. ``stopAndCleanup`` kills the
## process and removes that directory, and is safe to call repeatedly
## and from a ``finally``. The caller-visible serial log is written
## wherever ``BootMediaSpec.serialLogPath`` points, which callers should
## put *outside* the run directory precisely so it survives teardown as
## a test artifact.
##
## *TPM.* Not wired here. The swtpm lifecycle in
## ``backends/qemu_windows_arm.nim`` is the model to copy, and
## ``buildQemuBootArgs`` is a pure function over a value type
## specifically so adding ``-tpmdev``/``-device tpm-tis`` later is a
## local change with a unit test rather than a refactor.

import std/[hashes, options, os, osproc, streams, strutils, tables, times]

when defined(posix):
  import std/posix
  import std/net

import ../types
import ../auto
import ../firmware
import ../serial

# ---------------------------------------------------------------------------
# Backend type.

const
  QemuBootNamePrefix* = "repro-test-boot-qemu-"
    ## Default VM-name prefix. Every name this backend accepts must start
    ## with the backend's configured prefix so a stale-process sweep can
    ## recognise what the harness owns without pattern-matching on
    ## "looks like QEMU". Consumers running on a shared host should
    ## configure their own campaign-specific prefix.

  DefaultQemuBootMemoryMB* = 2048
  DefaultQemuBootCpus* = 2
  DefaultQemuBootStartTimeoutSec* = 20
    ## How long ``bootFromMedia`` waits for QEMU to still be alive and
    ## for the serial log to exist. A firmware/argv error kills QEMU in
    ## well under a second, so this only bounds pathological cases.

type
  QemuBootBackend* = ref object of VmBackend
    ## Direct ``qemu-system-x86_64`` driver. Holds no host-global state:
    ## every VM is a child process plus one directory under ``stateDir``.
    qemuCmd*: string           ## ``qemu-system-x86_64`` by default
    qemuImgCmd*: string        ## ``qemu-img`` by default
    stateDir*: string          ## parent of the per-VM run directories
    namePrefix*: string        ## enforced prefix for VM names
    probeTimeoutSec*: int

  QemuBootSerialStream* = ref object of SerialStream
    ## Cursor over the QEMU-written serial log plus the write side of
    ## the chardev socket.
    buf*: SerialLineBuffer
    fileOffset*: int64
    socketPath*: string

proc defaultQemuBootStateDir*(): string =
  getTempDir() / "vm-harness-qemu-boot"

proc newQemuBootBackend*(qemuCmd = "qemu-system-x86_64",
                         qemuImgCmd = "qemu-img",
                         stateDir = "",
                         namePrefix = QemuBootNamePrefix,
                         probeTimeoutSec = 10): QemuBootBackend =
  if namePrefix.len == 0:
    raise newException(ValueError,
      "QemuBootBackend: namePrefix must not be empty")
  QemuBootBackend(
    id: biQemuBoot,
    hostPlatform: hpLinux,
    supportedGuests: {goLinux, goWindows},
    qemuCmd: qemuCmd,
    qemuImgCmd: qemuImgCmd,
    stateDir: (if stateDir.len > 0: stateDir else: defaultQemuBootStateDir()),
    namePrefix: namePrefix,
    probeTimeoutSec: probeTimeoutSec)

# ---------------------------------------------------------------------------
# Small process helpers. Deliberately local: ``qemu_windows_arm.nim`` has
# equivalents, but they are private there and coupled to its own state
# tables, and exporting one shared copy would collide in ``vm_harness.nim``'s
# flat re-export surface.

proc runProcessCapture(cmd: seq[string], timeoutSec: int = 60):
    tuple[exitCode: int, output: string] =
  if cmd.len == 0:
    return (127, "empty command")
  var p: Process
  try:
    p = startProcess(cmd[0], args = cmd[1 .. ^1],
                     options = {poUsePath, poStdErrToStdOut})
  except CatchableError as e:
    return (127, "failed to start " & cmd[0] & ": " & e.msg)
  let deadline = epochTime() + timeoutSec.float
  var output = ""
  while true:
    if not p.running:
      break
    if epochTime() >= deadline:
      try: p.terminate()
      except CatchableError: discard
      output.add("\n[timeout after " & $timeoutSec & "s]")
      break
    sleep(25)
  try:
    output.add(p.outputStream.readAll())
  except CatchableError:
    discard
  let code = try: p.waitForExit() except CatchableError: 127
  try: p.close() except CatchableError: discard
  (code, output)

proc processAlive*(pid: int): bool =
  ## ``true`` while the OS still has a live (non-reaped) process with
  ## this id. Used by teardown and by the stale-process sweep.
  if pid <= 0:
    return false
  when defined(posix):
    var status: cint
    let waited = posix.waitpid(Pid(pid), status, WNOHANG)
    if waited == Pid(pid):
      return false          # our child, just reaped
    if waited < Pid(0):
      return posix.kill(Pid(pid), cint(0)) == 0
    true
  else:
    false

proc stopStartedProcess(pid: int) =
  ## SIGTERM, then SIGKILL if it does not go away. Never raises.
  if pid <= 0:
    return
  when defined(posix):
    discard posix.kill(Pid(pid), SIGTERM)
    var deadline = epochTime() + 3.0
    while epochTime() < deadline:
      if not processAlive(pid):
        return
      sleep(25)
    discard posix.kill(Pid(pid), SIGKILL)
    deadline = epochTime() + 3.0
    while epochTime() < deadline:
      if not processAlive(pid):
        return
      sleep(25)
  else:
    discard runProcessCapture(@["kill", "-9", $pid], timeoutSec = 5)

proc shQuote*(s: string): string =
  ## POSIX single-quote escaping. Used only for the ``sh -c 'exec …'``
  ## wrapper that redirects QEMU's own stdout/stderr into the run
  ## directory; ``exec`` keeps the QEMU process as our direct child, so
  ## the pid we record is the pid we must later kill.
  "'" & s.replace("'", "'\\''") & "'"

# ---------------------------------------------------------------------------
# Naming and per-VM layout.

proc newQemuBootVmName*(prefix = QemuBootNamePrefix): string =
  ## ``<prefix><pid>-<hex>``. The pid makes a name traceable back to the
  ## harness process that owns it; the time-derived suffix keeps two
  ## sequential runs in one process distinct.
  prefix & $getCurrentProcessId() & "-" &
    toHex(int64(epochTime() * 1000.0) and 0xFFFFFF'i64, 6).toLowerAscii()

proc runDirFor*(b: QemuBootBackend, name: string): string =
  b.stateDir / name

proc serialSocketPathFor*(b: QemuBootBackend, name: string): string =
  ## Unix sockets have a ~108 byte sun_path limit, which a long
  ## ``stateDir`` plus a long VM name can exceed. Hash the run directory
  ## down to a short, stable name under the system temp dir instead of
  ## discovering the limit at bind time.
  getTempDir() / ("vmh-qb-" & $abs(hash(b.runDirFor(name))) & ".sock")

# ---------------------------------------------------------------------------
# Argument construction. Pure over a value type so it is unit-testable
# without a QEMU on PATH.

type
  QemuBootLaunch* = object
    vmName*: string
    diskPath*: string          ## boot disk (already an overlay, if any)
    diskFormat*: string        ## "qcow2" / "raw"
    cdromPath*: string         ## optional install ISO
    serialSocketPath*: string
    serialLogPath*: string
    qemuLogPath*: string       ## QEMU's own ``-D`` trace
    ovmfCode*: string          ## empty => legacy BIOS (SeaBIOS)
    ovmfVars*: string          ## per-VM WRITABLE copy, never the template
    cpus*: int
    memoryMB*: int
    accel*: BootAcceleration   ## must already be resolved (never baAuto)
    sshForwardPort*: int

proc kvmUsable*(): bool =
  ## KVM is usable when ``/dev/kvm`` exists and this process may open it
  ## read-write. Probing the device beats probing group membership: the
  ## host may grant access through an ACL or a permissive mode.
  when defined(linux):
    if not fileExists("/dev/kvm"):
      return false
    try:
      let f = open("/dev/kvm", fmReadWriteExisting)
      f.close()
      true
    except CatchableError:
      false
  else:
    false

proc resolveQemuAccel*(requested: BootAcceleration): BootAcceleration =
  ## ``baAuto`` becomes KVM when the host can, TCG otherwise. An explicit
  ## ``baKvm`` is left alone so a caller that requires acceleration gets
  ## QEMU's own hard failure instead of a silent 20x slowdown.
  case requested
  of baAuto: (if kvmUsable(): baKvm else: baTcg)
  of baKvm: baKvm
  of baTcg: baTcg

proc buildQemuBootArgs*(l: QemuBootLaunch): seq[string] =
  ## Build the full argv (excluding argv[0]) for one transient boot.
  if l.vmName.len == 0:
    raise newException(ValueError, "QemuBootLaunch.vmName is empty")
  if l.serialLogPath.len == 0:
    raise newException(ValueError, "QemuBootLaunch.serialLogPath is empty")
  if l.diskPath.len == 0 and l.cdromPath.len == 0:
    raise newException(ValueError,
      "QemuBootLaunch needs at least one of diskPath / cdromPath")
  if (l.ovmfCode.len == 0) != (l.ovmfVars.len == 0):
    raise newException(ValueError,
      "UEFI boot requires both a loader and a writable NVRAM copy")
  if l.sshForwardPort != 0 and l.sshForwardPort notin 1 .. 65535:
    raise newException(ValueError,
      "QemuBootLaunch.sshForwardPort must be 0 or a TCP port from 1 to 65535")

  result = @[
    # -name lands in the process table, which is what makes an orphaned
    # QEMU attributable to the harness that leaked it.
    "-name", l.vmName,
    "-machine", "q35",
    "-m", $(if l.memoryMB > 0: l.memoryMB else: DefaultQemuBootMemoryMB),
    "-smp", $(if l.cpus > 0: l.cpus else: DefaultQemuBootCpus),
    "-display", "none",
    # A guest that triple-faults must end the run, not spin in a reboot
    # loop until the gate's timeout expires and reports the wrong thing.
    "-no-reboot",
    "-rtc", "base=utc"]

  case l.accel
  of baKvm:
    result.add(@["-accel", "kvm", "-cpu", "host"])
  of baTcg, baAuto:
    # TCG must not inherit a host CPU model: that model can advertise
    # KVM-only features the emulator cannot provide.
    result.add(@["-accel", "tcg", "-cpu", "qemu64"])

  if l.ovmfCode.len > 0:
    result.add(@[
      "-drive", "if=pflash,format=raw,readonly=on,file=" & l.ovmfCode,
      "-drive", "if=pflash,format=raw,file=" & l.ovmfVars])

  if l.diskPath.len > 0:
    let fmt = if l.diskFormat.len > 0: l.diskFormat else: "qcow2"
    result.add(@["-drive",
      "file=" & l.diskPath & ",format=" & fmt & ",if=virtio"])
  if l.cdromPath.len > 0:
    result.add(@["-cdrom", l.cdromPath])

  # One chardev serves both directions; ``logfile`` is what makes the
  # transcript durable and complete regardless of who is connected.
  var chardev = "socket,id=serial0,path=" & l.serialSocketPath &
                ",server=on,wait=off,logfile=" & l.serialLogPath
  result.add(@["-chardev", chardev, "-serial", "chardev:serial0"])

  if l.sshForwardPort > 0:
    result.add(@[
      "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:" &
        $l.sshForwardPort & "-:22",
      "-device", "virtio-net-pci,netdev=net0"])
  else:
    # Boot gates are network-isolated by default.
    result.add(@["-nic", "none"])

  if l.qemuLogPath.len > 0:
    result.add(@["-D", l.qemuLogPath])

proc qemuBootShellCommand*(qemuCmd: string, args: seq[string],
                           qemuStdioLogPath: string): string =
  ## Wrap the invocation so QEMU's own stdout/stderr land in a file we
  ## can quote back in a failure message. ``exec`` means the shell is
  ## replaced by QEMU, so ``startProcess`` still hands back QEMU's pid.
  var parts = @["exec", shQuote(qemuCmd)]
  for a in args:
    parts.add(shQuote(a))
  parts.join(" ") & " >" & shQuote(qemuStdioLogPath) & " 2>&1"

# ---------------------------------------------------------------------------
# Lifecycle.

method probeAvailability*(b: QemuBootBackend): bool =
  when defined(linux) or defined(macosx):
    try:
      let q = runProcessCapture(@[b.qemuCmd, "--version"],
                                timeoutSec = b.probeTimeoutSec)
      if q.exitCode != 0:
        return false
      if "qemu" notin q.output.toLowerAscii:
        return false
      let i = runProcessCapture(@[b.qemuImgCmd, "--version"],
                                timeoutSec = b.probeTimeoutSec)
      i.exitCode == 0
    except CatchableError:
      false
  else:
    false

proc prepareOverlay(b: QemuBootBackend, runDir, source, sourceFormat: string):
    tuple[path, format: string] =
  ## Never boot the caller's image directly: a guest that writes to its
  ## root filesystem would mutate the artifact under test and make the
  ## next run non-reproducible. The overlay lives in the run directory,
  ## so teardown removing that directory is what proves no disk leaked.
  let overlay = runDir / "overlay.qcow2"
  let r = runProcessCapture(@[
    b.qemuImgCmd, "create", "-f", "qcow2",
    "-b", absolutePath(source), "-F", sourceFormat, overlay],
    timeoutSec = 120)
  if r.exitCode != 0:
    raise newVmHarnessError($b.id, lpStartup,
      "QemuBootBackend: qemu-img overlay creation failed (exit " &
      $r.exitCode & "): " & r.output)
  (overlay, "qcow2")

method bootFromMedia*(b: QemuBootBackend, spec: BootMediaSpec): VmHandle =
  ## Start one transient QEMU child around ``spec.mediaPath``.
  ##
  ## The returned handle MUST be passed to ``stopAndCleanup`` — from a
  ## ``finally``/``defer``, not from the happy path only. Call
  ## ``captureSerial`` on it to drive assertions.
  when defined(posix):
    if spec.kind == bmkRootfsTar:
      raise newException(BackendUnavailableError,
        "QemuBootBackend.bootFromMedia does not support bmkRootfsTar")
    if spec.mediaPath.len == 0:
      raise newException(ValueError, "BootMediaSpec.mediaPath is empty")
    if not fileExists(spec.mediaPath):
      raise newException(IOError,
        "BootMediaSpec.mediaPath does not exist: " & spec.mediaPath)

    let vmName = if spec.name.len > 0: spec.name
                 else: newQemuBootVmName(b.namePrefix)
    if not vmName.startsWith(b.namePrefix):
      raise newException(ValueError,
        "BootMediaSpec.name must start with '" & b.namePrefix &
        "' so a stale-process sweep can recognise it (got '" & vmName & "')")

    let runDir = b.runDirFor(vmName)
    if dirExists(runDir):
      removeDir(runDir)
    createDir(runDir)

    # Everything below can fail; a half-built VM must not leak a process,
    # an overlay or a socket, so the whole body runs under one guard.
    var pid = 0
    var handle: VmHandle
    try:
      let serialLogPath =
        if spec.serialLogPath.len > 0: absolutePath(spec.serialLogPath)
        else: runDir / "serial.log"
      let serialLogDir = parentDir(serialLogPath)
      if serialLogDir.len > 0:
        createDir(serialLogDir)
      # QEMU truncates on open, but an existing file from a previous run
      # would otherwise be indistinguishable from "QEMU never started".
      if fileExists(serialLogPath):
        removeFile(serialLogPath)

      let socketPath = b.serialSocketPathFor(vmName)
      if fileExists(socketPath):
        removeFile(socketPath)

      var launch = QemuBootLaunch(
        vmName: vmName,
        serialSocketPath: socketPath,
        serialLogPath: serialLogPath,
        qemuLogPath: runDir / "qemu-trace.log",
        cpus: spec.cpus,
        memoryMB: spec.memoryMB,
        accel: resolveQemuAccel(spec.acceleration),
        sshForwardPort: spec.sshForwardPort)

      let generation = if spec.generation > 0: spec.generation else: 2
      if generation notin [1, 2]:
        raise newException(ValueError,
          "BootMediaSpec.generation must be 1 (BIOS) or 2 (UEFI)")
      if generation == 2:
        let ovmf = resolveOvmfPair(spec.extra.getOrDefault("uefiLoader"),
                                   spec.extra.getOrDefault("uefiNvramTemplate"))
        if ovmf.loader.len == 0:
          raise newVmHarnessError($b.id, lpStartup,
            "QemuBootBackend: UEFI boot requested but no firmware was " &
            "found.\n" & describeOvmfSearch())
        # The template is read-only in the store; the guest needs its own
        # writable copy or the firmware fails to save variables.
        let varsCopy = runDir / "OVMF_VARS.fd"
        copyFile(ovmf.nvram, varsCopy)
        setFilePermissions(varsCopy, {fpUserRead, fpUserWrite})
        launch.ovmfCode = ovmf.loader
        launch.ovmfVars = varsCopy

      case spec.kind
      of bmkIso:
        launch.cdromPath = absolutePath(spec.mediaPath)
        if spec.targetDiskPath.len > 0:
          let target = absolutePath(spec.targetDiskPath)
          if fileExists(target) or dirExists(target):
            raise newException(ValueError,
              "BootMediaSpec.targetDiskPath already exists: " & target)
          let targetDir = parentDir(target)
          if targetDir.len > 0:
            createDir(targetDir)
          let diskGB = if spec.diskGB > 0: spec.diskGB else: 8
          let created = runProcessCapture(@[
            b.qemuImgCmd, "create", "-f", "qcow2", target, $diskGB & "G"],
            timeoutSec = 120)
          if created.exitCode != 0:
            raise newVmHarnessError($b.id, lpStartup,
              "QemuBootBackend: target disk creation failed (exit " &
              $created.exitCode & "): " & created.output)
          launch.diskPath = target
          launch.diskFormat = "qcow2"
      of bmkQcow2, bmkVhdx:
        let sourceFormat = spec.extra.getOrDefault("diskFormat", "qcow2")
        let overlay = b.prepareOverlay(runDir, spec.mediaPath, sourceFormat)
        launch.diskPath = overlay.path
        launch.diskFormat = overlay.format
      of bmkRootfsTar:
        doAssert false          # guarded above

      let args = buildQemuBootArgs(launch)
      let stdioLog = runDir / "qemu-stdio.log"
      let shellCmd = qemuBootShellCommand(b.qemuCmd, args, stdioLog)
      var p = startProcess("/bin/sh", args = @["-c", shellCmd],
                           options = {poParentStreams})
      pid = p.processID

      # A bad argv, a missing firmware file or an unreadable disk kills
      # QEMU immediately. Surface that here, with QEMU's own words,
      # instead of letting the first expectLine time out 60 s later
      # against a log that will never grow.
      let deadline = epochTime() +
        DefaultQemuBootStartTimeoutSec.float
      var started = false
      while epochTime() < deadline:
        if fileExists(serialLogPath):
          started = true
          break
        if not processAlive(pid):
          break
        sleep(25)
      if not started and not processAlive(pid):
        var detail = ""
        if fileExists(stdioLog):
          detail = readFile(stdioLog).strip()
        raise newVmHarnessError($b.id, lpStartup,
          "QemuBootBackend: qemu exited before opening its serial log. " &
          "argv: " & (b.qemuCmd & " " & args.join(" ")) &
          (if detail.len > 0: "\nqemu said: " & detail else: ""))

      var extra = initTable[string, string]()
      extra["mediaPath"] = spec.mediaPath
      extra["runDir"] = runDir
      extra["qemuPid"] = $pid
      extra["serialLogPath"] = serialLogPath
      extra["serialSocketPath"] = socketPath
      extra["qemuStdioLogPath"] = stdioLog
      if launch.diskPath.len > 0:
        extra["bootDiskPath"] = launch.diskPath
      if spec.targetDiskPath.len > 0:
        extra["targetDiskPath"] = launch.diskPath
        extra["preserveBootDisk"] = "true"
      extra["accel"] = $launch.accel
      handle = VmHandle(
        backend: b,
        name: vmName,
        baseline: "<boot-from-media>",
        ipAddress: (if spec.sshForwardPort > 0: some("127.0.0.1")
                    else: none(string)),
        sshPort: spec.sshForwardPort,
        extra: extra)
      return handle
    except CatchableError:
      if pid > 0:
        stopStartedProcess(pid)
      try:
        let sock = b.serialSocketPathFor(vmName)
        if fileExists(sock): removeFile(sock)
      except CatchableError: discard
      try:
        if dirExists(runDir): removeDir(runDir)
      except CatchableError: discard
      raise
  else:
    raise newException(BackendUnavailableError,
      "QemuBootBackend requires a POSIX host")

method stopAndCleanup*(b: QemuBootBackend, vm: VmHandle,
                       deleteVm: bool = true) =
  ## Unconditional teardown. Never raises, idempotent, and safe from a
  ## ``finally`` reached by timeout, assertion failure or exception.
  if vm == nil:
    return
  try:
    let pidText = vm.extra.getOrDefault("qemuPid", "")
    if pidText.len > 0:
      try: stopStartedProcess(parseInt(pidText))
      except ValueError: discard
    let sock = vm.extra.getOrDefault("serialSocketPath", "")
    if sock.len > 0 and fileExists(sock):
      try: removeFile(sock) except CatchableError: discard
    if deleteVm:
      let runDir = vm.extra.getOrDefault("runDir", "")
      # A caller-owned install target may live outside the run dir; the
      # run dir itself is always ours, overlay included.
      if runDir.len > 0 and dirExists(runDir):
        removeDir(runDir)
    vm.extra["cleanedUp"] = "true"
  except CatchableError:
    discard

method waitForShutdown*(b: QemuBootBackend, vm: VmHandle,
                        timeoutSec: int): bool =
  ## A guest-initiated poweroff makes QEMU exit; that is the signal.
  let pidText = vm.extra.getOrDefault("qemuPid", "")
  if pidText.len == 0:
    return true
  var pid = 0
  try: pid = parseInt(pidText) except ValueError: return true
  let deadline = epochTime() + max(timeoutSec, 0).float
  while true:
    if not processAlive(pid):
      return true
    if epochTime() >= deadline:
      return false
    sleep(200)

# ---------------------------------------------------------------------------
# Serial.

proc pumpSerialFile(s: QemuBootSerialStream) =
  ## Feed everything QEMU has appended since the last call into the
  ## shared line buffer. Failures are swallowed: a transient read error
  ## must not abort a boot assertion that is still perfectly able to
  ## succeed on the next poll.
  if s == nil or not fileExists(s.logPath):
    return
  try:
    let size = getFileSize(s.logPath)
    if size < s.fileOffset:
      s.fileOffset = 0
    if size <= s.fileOffset:
      return
    var f = open(s.logPath, fmRead)
    defer: f.close()
    setFilePos(f, s.fileOffset)
    let bytes = f.readAll()
    s.fileOffset += bytes.len.int64
    s.buf.feed(bytes)
  except CatchableError:
    discard

method captureSerial*(b: QemuBootBackend, vm: VmHandle): SerialStream =
  QemuBootSerialStream(
    vm: vm,
    logPath: vm.extra.getOrDefault("serialLogPath"),
    buf: newSerialLineBuffer(),
    fileOffset: 0,
    socketPath: vm.extra.getOrDefault("serialSocketPath"))

method expectLine*(b: QemuBootBackend, stream: SerialStream,
                   pattern: string, timeoutSec: int = 60): SerialMatch =
  let s = QemuBootSerialStream(stream)
  expectLineImpl(s.buf, pattern, timeoutSec * 1000, 100,
                 proc() = pumpSerialFile(s))

method serialSend*(b: QemuBootBackend, stream: SerialStream, text: string) =
  ## Write to the guest's serial input. Connect, write, drain briefly,
  ## disconnect — see this module's header for why the connection is not
  ## held open. Reads continue to come from the log, so the drained
  ## bytes are not lost.
  when defined(posix):
    let s = QemuBootSerialStream(stream)
    if s == nil or s.socketPath.len == 0:
      raise newException(BackendUnavailableError,
        "QemuBootBackend.serialSend: no chardev socket for this stream")
    if not fileExists(s.socketPath):
      raise newVmHarnessError($b.id, lpExec,
        "QemuBootBackend.serialSend: serial socket is gone: " & s.socketPath)
    # Qualified: ``std/posix`` also exports AF_UNIX / SOCK_STREAM as cint.
    var sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
                         Protocol.IPPROTO_IP)
    try:
      sock.connectUnix(s.socketPath)
      sock.send(text)
      # Discard anything the guest echoes while we hold the connection;
      # the durable log already has it.
      let deadline = epochTime() + 0.2
      while epochTime() < deadline:
        var drained = ""
        try:
          if sock.recv(drained, 4096, timeout = 50) <= 0:
            break
        except CatchableError:
          break
    finally:
      try: sock.close() except CatchableError: discard
  else:
    raise newException(BackendUnavailableError,
      "QemuBootBackend.serialSend requires a POSIX host")

method closeSerial*(b: QemuBootBackend, stream: SerialStream) =
  let s = QemuBootSerialStream(stream)
  if s != nil and s.buf != nil:
    s.buf.close()

# ---------------------------------------------------------------------------
# Stale-process sweep. A harness process that is SIGKILLed mid-run cannot
# run its own teardown, so the next run has to be able to clean up after
# it. Matching is by the ``-name <prefix>…`` argument this backend always
# emits, never by "is a qemu process".

proc qemuBootProcessesMatching*(namePrefix: string): seq[tuple[pid: int, name: string]] =
  ## Every live process whose argv carries ``-name <namePrefix>…``.
  ## Linux-only (it reads ``/proc``); returns an empty seq elsewhere.
  when defined(linux):
    for kind, path in walkDir("/proc"):
      if kind != pcDir:
        continue
      let base = extractFilename(path)
      var pid = 0
      try: pid = parseInt(base) except ValueError: continue
      var cmdline = ""
      try:
        cmdline = readFile(path / "cmdline")
      except CatchableError:
        continue
      let argv = cmdline.split('\0')
      for i in 0 ..< argv.len - 1:
        if argv[i] == "-name" and argv[i + 1].startsWith(namePrefix):
          result.add((pid: pid, name: argv[i + 1]))
          break
  else:
    discard

proc sweepStaleQemuBootProcesses*(b: QemuBootBackend): seq[string] =
  ## Kill every live QEMU carrying this backend's name prefix and remove
  ## its run directory. Returns the names swept. Intended for a harness
  ## to call at start-up, never for a caller to substitute for teardown.
  for entry in qemuBootProcessesMatching(b.namePrefix):
    stopStartedProcess(entry.pid)
    result.add(entry.name)
    let runDir = b.runDirFor(entry.name)
    try:
      if dirExists(runDir): removeDir(runDir)
    except CatchableError: discard

registerBackend(biQemuBoot,
  proc(): VmBackend =
    newQemuBootBackend(
      qemuCmd = getEnv("VMH_QEMU_BOOT_QEMU_CMD", "qemu-system-x86_64"),
      qemuImgCmd = getEnv("VMH_QEMU_BOOT_QEMU_IMG_CMD", "qemu-img"),
      stateDir = getEnv("VM_HARNESS_QEMU_BOOT_STATE_DIR", ""),
      namePrefix = getEnv("VMH_QEMU_BOOT_NAME_PREFIX", QemuBootNamePrefix)))
