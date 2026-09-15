## QemuWindowsArmBackend — direct QEMU/HVF Windows-on-ARM cached boot.
##
## This backend is intentionally narrower than UTM: it consumes a prebuilt
## directory containing ``windows.qcow2``, creates a per-run copy under a
## writable state directory, boots it with ``qemu-system-aarch64`` on macOS
## HVF, and reaches the guest through OpenSSH over user-mode networking with
## host port forwarding. It exists as an unblock path when UTM's control plane
## cannot enumerate or clone registered bundles.

import std/[algorithm, hashes, json, net, options, os, osproc, streams,
            strutils, tables, times]
when defined(posix):
  import std/posix
import ../types
import ../auto

type
  QemuWindowsArmBackend* = ref object of VmBackend
    qemuCmd*: string
    qemuImgCmd*: string
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
    instanceLockFds*: Table[string, cint]  ## per-instance lock fds, held for
                                            ## the instance lifetime; OS releases
                                            ## them if this launcher crashes.

const
  DefaultQemuWindowsArmPrefix* = "repro-vm-qemu-windows-arm"
  DefaultQemuWindowsArmUser* = "admin"
  DefaultQemuWindowsArmPassword* = "repro-windows-arm"
  QemuPortAllocationLockName = ".qemu-port-allocation.lock"
  QemuPortClaimTimeoutMs = 5000
  QemuPortAllocationAttempts = 5
  QemuSshAttempts = 5
  QemuSshRetryDelayMs = 2000
  # Ephemeral disk layout. The baseline directory holds an immutable golden
  # ``windows.qcow2``; each ephemeral instance boots from a thin
  # ``overlay.qcow2`` whose qcow2 backing file is that golden. The golden is
  # shared read-only across every concurrent instance, so a leaked instance
  # costs only its write-delta instead of a full disk copy.
  QwaBaseDiskName* = "windows.qcow2"
  QwaOverlayDiskName* = "overlay.qcow2"
  QwaInstanceLockName* = ".instance.lock"
  # Disk provisioning modes for ``VMH_QEMU_WINDOWS_ARM_DISK_MODE``.
  QwaDiskModeOverlay* = "overlay"   ## qcow2 backing overlay (default)
  QwaDiskModeClone* = "clone"       ## whole-file clone (clonefile/copy)

  # Golden build space budget. A build that dies at 90% costs the better
  # part of an hour, and it runs on a host that is also serving CI, so the
  # numbers below are deliberately pessimistic.
  QwaDefaultGoldenDiskGB* = 64
    ## Requested qcow2 size. qcow2 is sparse, so this is a ceiling on
    ## growth rather than an allocation.
  QwaGoldenInstallPeakGB* = 50
    ## Peak *actual* consumption assumed for a golden install. It produces a
    ## 60 GB floor for the default 64 GB image (see ``qwaGoldenFloorGB``).
    ##
    ## MEASURED on m3 2026-09-15, sampling ``du -sk`` of the whole build
    ## directory every 20s across four runs through to the install sentinel:
    ## peaks of 16.44, 14.97, 15.07 and 14.08 GiB, the largest being the run
    ## that got furthest through provisioning. The qcow2 alone peaked at
    ## 16.3 GiB and then SHRANK as Setup trimmed. So this number is
    ## pessimistic by roughly 3x — and it is KEPT anyway, deliberately:
    ##
    ## * The measurement stops at the sentinel. No run has yet survived
    ##   ``sysprep /generalize``, whose working set is exactly the part of
    ##   the estimate that is still unmeasured.
    ## * The error is in the safe direction. The band this over-estimate
    ##   wrongly refuses is 27-60 GB free, on a 1.9 TB host whose free space
    ##   swings by a saturated fleet's worth (``QwaFleetPeakGB``, 116 GB)
    ##   between idle and load. A build started at 30 GB free would be
    ##   racing CI for the disk for the next hour.
    ## * ``VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB`` already exists for an operator
    ##   who knows better on a specific host.
    ##
    ## Revisit it when a build has been through generalize, not before.
  QwaGoldenBuildSlackGB* = 10
    ## Logs, firmware vars, TPM state, and room to not wedge the host at
    ## exactly zero.
  QwaFleetPeakGB* = 116
    ## What a saturated fleet holds concurrently on m3, from the live
    ## scale-set limits and measured instance footprints: 2 macOS at ~36 GB,
    ## 3 Linux at ~8 GB, 2 Windows overlays at ~10 GB. A golden build shares
    ## the disk with all of it, and observed free space swings by that much
    ## over a day.

  # ---- Golden build orchestration (Runner-Fleet-M3-ARM-Wave MA3) ----------
  QwaInstallSentinelPath* = "C:\\Windows\\Temp\\repro-install-done"
    ## The install-completion sentinel. This is NOT invented here: it is the
    ## file ``guest-recipes/windows-arm-base/autounattend.xml`` writes from
    ## the LAST of its ``FirstLogonCommands``, and only after OpenSSH has
    ## been confirmed installed and ``sshd`` confirmed running. Polling for
    ## it is therefore a statement about the whole answer-file chain having
    ## completed, not merely about Windows having booted.
  QwaInstallDoneMarker* = "VMH-INSTALL-DONE"
    ## What the sentinel probe PRINTS when the sentinel is present.
    ## Deliberately different from the sentinel's own name: an ssh wrapper
    ## that echoes back the command it was given must not be able to look
    ## like a finished install.
  QwaSysprepExePath* = "C:\\Windows\\System32\\Sysprep\\sysprep.exe"
  QwaSysprepCreateMarker* = "VMH-SYSPREP-CREATE"
    ## Printed by the sysprep launch before it creates anything, so a launch
    ## that never reached the guest's shell is distinguishable from one that
    ## reached it and was refused.
  QwaSysprepRunningMarker* = "VMH-SYSPREP-RUNNING"
    ## What the "is sysprep actually running?" probe prints. Distinct from
    ## the process name for the same reason ``QwaInstallDoneMarker`` is: an
    ## ssh wrapper that echoes its argument must not look like a live sysprep.
  QwaSysprepTakeHoldSec* = 180
    ## How long to wait for sysprep to become visible in the guest after it
    ## has been launched. MEASURED on m3 2026-09-15: a sysprep that is killed
    ## with the SSH session dies about a second in, so this only has to be
    ## long enough to cover a slow start, not a whole generalize.
  QwaSysprepTakeHoldPollMs* = 10_000
  QwaSysprepAnswerGuestPath* = "C:\\repro-sysprep.xml"
    ## Where ``autounattend.xml`` copies ``repro-sysprep.xml`` to, from the
    ## answer-file ISO, in its ``FirstLogonCommands``. Sysprep is invoked
    ## with ``/unattend:`` pointing here, so the two must agree.
  QwaGoldenManifestName* = "golden-manifest.json"
  QwaGoldenManifestSchema* = "vm-harness/qemu-windows-arm-golden/1"
  QwaVmHarnessVersion* = "0.1.0"
    ## Recorded in each golden's manifest. Kept in step with the ``version``
    ## field of ``vm_harness.nimble``, which the unit gate compares against.
  QwaDefaultGoldenDeadlineSec* = 90 * 60
    ## One deadline for the whole run. The recipe README budgets 15-30 min
    ## for the install, 1-3 for OpenSSH and 10-20 for sysprep/generalize, so
    ## 90 minutes is generous; the point of the bound is that a guest stuck
    ## at an OOBE prompt has no SSH and no console and would otherwise wait
    ## forever.
  QwaSentinelPollMs* = 15_000
  QwaPowerOffPollMs* = 2_000
  QwaInstallMediaKey* = "ret"
    ## The key injected to answer ``cdboot.efi``'s "Press any key to boot
    ## from CD or DVD" prompt. MEASURED on m3 2026-09-15: without it the
    ## install boot cannot start at all. ``\EFI\BOOT\BOOTAA64.EFI`` on a
    ## Windows install ISO is ``cdboot.efi``, which waits ~5s for a keypress
    ## and returns ``EFI_TIMEOUT`` when none arrives; the headless machine
    ## shape has NO input device (``-display none`` and an output-only
    ## ``-serial file:``), so the firmware logged
    ## ``failed to start Boot0001 ...: Time out``, fell through to the EFI
    ## shell, and the build sat out its whole deadline.
  QwaInstallKeyPressWindowSec* = 180
    ## How long the install boot keeps answering that prompt. BOUNDED ON
    ## PURPOSE, and the bound is load-bearing rather than defensive: the same
    ## unanswered prompt is what makes Windows Setup's own reboots fall
    ## through the still-first install media and onto the disk it is
    ## installing to. Keep pressing keys past the first boot and Setup
    ## restarts from the media instead of continuing — measured on m3, the
    ## media is still ahead of the disk in ``BootOrder`` after Setup's first
    ## reboot. The prompt appears ~20-25s after power-on, so this is ample.
  QwaInstallKeyPressIntervalMs* = 2_000
  QwaInstallProgressBytes* = 4'i64 * 1024 * 1024
    ## Growth of the target qcow2 past its freshly-created size that means
    ## Windows Setup is writing — i.e. the prompt has been answered and the
    ## keypress window can stop early. A fresh 64 GB qcow2 is ~200 KB.
  QwaRecipeAnswerFiles* = ["autounattend.xml", "repro-sysprep.xml",
                           "provision-openssh.ps1"]
    ## The checked-in recipe inputs whose digests go into a golden's
    ## manifest. Together with the ISO hash they are what makes a golden of
    ## unknown provenance identifiable as one.

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
                               probeTimeoutSec: int = 10,
                               qemuImgCmd: string = "qemu-img"): QemuWindowsArmBackend =
  result = QemuWindowsArmBackend(
    id: biQemuWindowsArm,
    hostPlatform: hpMacosArm,
    supportedGuests: {goWindows},
    qemuCmd: qemuCmd,
    qemuImgCmd: qemuImgCmd,
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
    swtpmPids: initTable[string, int](),
    instanceLockFds: initTable[string, cint]())

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
  ## STRUCTURAL check: return the absolute directory when it holds a disk a
  ## guest could be booted from. This is what the overlay and clone paths
  ## need, and they are handed a directory something else already admitted.
  ##
  ## It is deliberately NOT the admission check. A half-finished install has
  ## a ``windows.qcow2`` too — see ``requireWindowsArmGolden``.
  if dir.len == 0:
    raise newException(ValueError, "Windows ARM baseline directory is empty")
  if not dirExists(dir):
    raise newException(ValueError, "Windows ARM baseline directory not found: " & dir)
  let disk = dir / "windows.qcow2"
  if not fileExists(disk):
    raise newException(ValueError,
      "Windows ARM baseline directory must contain windows.qcow2: " & dir)
  absolutePath(dir)

proc requireWindowsArmGolden*(dir: string): string =
  ## ADMISSION check: return the absolute directory only when it is a
  ## FINISHED golden — a disk *and* the manifest that says what it was built
  ## from. Everything that consumes a golden goes through here.
  ##
  ## The manifest is the completion marker, and requiring it is the point.
  ## ``windows.qcow2`` alone identifies nothing: the golden build creates it
  ## EMPTY as its first act and writes the manifest as its LAST, so every
  ## directory a failed build leaves behind — and MA3's contract is that
  ## failed builds are retained for diagnosis — holds a plausible-looking
  ## disk and no manifest. MEASURED on m3 2026-09-15: six such directories
  ## sat under ``golden/`` after MA4's runs, 12-15 GB each, every one of them
  ## accepted by the structural check as a baseline to boot CI jobs from.
  ##
  ## That is the same class of trap this campaign exists to remove. The lane
  ## was down for weeks because a golden could not be identified, and the
  ## rule that came out of it is that an artifact must be identifiable AS
  ## one. A disk that could be a crash site is not an identification.
  let base = validateWindowsArmVmDir(dir)
  if not fileExists(base / QwaGoldenManifestName):
    raise newException(ValueError,
      "Windows ARM baseline directory " & base & " holds " &
      QwaBaseDiskName & " but no " & QwaGoldenManifestName & ", so it is " &
      "NOT a finished golden — most likely a build that failed and was " &
      "retained for diagnosis. The manifest is written last, as the " &
      "completion marker. Point at a directory a golden build finished " &
      "into, or rebuild.")
  absolutePath(base)

proc ephemeralName*(prefix: string, epochMs: int64, pid: int): string =
  prefix & "-" & $epochMs & "-" & $pid

proc ephemeralDirFor*(stateDir, name: string): string =
  stateDir / "instances" / name

proc ephemeralPidFromName*(name: string): int =
  ## The creating process id is the last ``-``-separated field of
  ## ``<prefix>-<epochMs>-<pid>``. Returns 0 when it cannot be parsed.
  let idx = name.rfind('-')
  if idx < 0 or idx == name.high:
    return 0
  try: parseInt(name[idx + 1 .. ^1])
  except ValueError: 0

when defined(posix):
  # BSD advisory locks (``flock``). Unlike ``lockf``/fcntl locks — which are
  # owned by the process and so are invisible to a same-process probe — a
  # ``flock`` is owned by the open file description. A separate ``open`` of
  # the same lock file therefore conflicts even within one process, which
  # makes the liveness check behave identically whether ``prune`` runs in the
  # launcher's process or (as in production) a different one. The OS drops the
  # lock automatically when the owning fd is closed, including on crash.
  proc c_flock(fd: cint, op: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}
  const
    LockExclusive = cint(2)   ## LOCK_EX
    LockNonBlock = cint(4)    ## LOCK_NB
    LockUnlock = cint(8)      ## LOCK_UN

proc qwaInstanceLockPath*(vmDir: string): string =
  vmDir / QwaInstanceLockName

proc qwaDiskImagePath*(vmDir: string): string =
  ## The disk QEMU boots from: the thin ``overlay.qcow2`` when present
  ## (overlay mode), otherwise the whole-file ``windows.qcow2`` (clone mode
  ## and legacy instances).
  let overlay = vmDir / QwaOverlayDiskName
  if fileExists(overlay): overlay else: vmDir / QwaBaseDiskName

proc pidAlive*(pid: int): bool =
  ## Best-effort liveness check. ``kill(pid, 0)`` succeeds while the process
  ## exists (or fails with EPERM, which still means it is alive).
  ##
  ## DO NOT "SIMPLIFY" THIS TO A ``ps`` PROBE. On macOS 26 (measured on m3,
  ## 26.5.1 / 25F80) ``ps -p <pid>`` writes ``ps: time: requires entitlement``
  ## and exits 1 for its default column set — even for a process that is very
  ## much alive — so the idiomatic ``ps -p $pid >/dev/null 2>&1`` shell probe
  ## reports EVERY pid dead on such a host. Asking for an explicit column
  ## (``ps -p $pid -o pid=``) exits 0 again. ``kill(pid, 0)`` is unaffected.
  if pid <= 0:
    return false
  when defined(posix):
    let rc = posix.kill(Pid(pid), cint(0))
    if rc == 0:
      return true
    return errno == EPERM
  else:
    return false

proc instanceDirOwnerAlive*(vmDir: string): bool =
  ## True when the launcher that owns ``vmDir`` is still running. Preference
  ## order:
  ##   1. The per-instance advisory lock (``.instance.lock``). If it is held
  ##      by another process the owner is alive; if we can take it the owner
  ##      is gone. This is race-free and immune to PID recycling.
  ##   2. Legacy instances predate the lock file: fall back to the creator
  ##      PID embedded in the directory name. Prune callers pair this with an
  ##      age guard so a recycled PID cannot mask a genuine orphan.
  when defined(posix):
    let lockPath = qwaInstanceLockPath(vmDir)
    if fileExists(lockPath):
      let fd = posix.open(lockPath.cstring, O_RDWR, Mode(0o600))
      if fd < 0:
        # Cannot open the lock; assume alive rather than risk deleting a
        # running instance.
        return true
      defer: discard posix.close(fd)
      # Non-blocking test lock. Success => nobody holds it => owner is dead.
      if c_flock(fd, LockExclusive or LockNonBlock) == 0:
        discard c_flock(fd, LockUnlock)
        return false
      return true
    else:
      return pidAlive(ephemeralPidFromName(extractFilename(vmDir)))
  else:
    return pidAlive(ephemeralPidFromName(extractFilename(vmDir)))

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

proc qwaMonitorSocketPath*(vmDir: string): string =
  ## The QEMU monitor socket published by the machine argv for ``vmDir``.
  ##
  ## Exported because the golden build watches for guest power-off HERE and
  ## not over SSH: ``sysprep /shutdown`` kills the guest, and with it every
  ## SSH session that could have reported the fact. Derived from the same
  ## expression the argv uses so the two cannot drift.
  shortSocketPath("vmh-qwa-mon", vmDir)

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

proc qwaMachineArgs(vmDir, disk: string, sshPort, cpus, memoryMB,
                    diskBootIndex: int): seq[string] =
  ## The machine shape shared by the per-job boot and the golden install
  ## boot. Everything here is headless already — that is what makes an
  ## unattended install possible without UTM or a console session.
  let tpmSock = shortSocketPath("vmh-qwa-tpm", vmDir)
  let serialLog = vmDir / "serial.log"
  let monitorSock = qwaMonitorSocketPath(vmDir)
  @[
    "-accel", "hvf",
    "-machine", "virt,highmem=on",
    "-cpu", "host",
    "-m", $memoryMB,
    "-smp", $cpus,
    "-drive", "id=disk0,file=" & disk & ",format=qcow2,if=none,cache=writeback,discard=unmap",
    "-device", "nvme,drive=disk0,serial=winarm0,bootindex=" & $diskBootIndex,
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
    "-rtc", "base=utc"
  ]

proc buildQemuWindowsArmArgs*(vmDir: string, sshPort: int,
                              cpus: int = 4, memoryMB: int = 8192): seq[string] =
  ## Per-job boot: one guest command, then teardown. ``-no-reboot`` turns a
  ## guest-initiated reboot into an exit, which is what the one-shot
  ## lifecycle wants.
  result = qwaMachineArgs(vmDir, qwaDiskImagePath(vmDir), sshPort, cpus,
                          memoryMB, diskBootIndex = 1)
  result.add("-no-reboot")
  result.add(qemuFirmwareArgs(vmDir))

proc buildQemuWindowsArmInstallArgs*(vmDir, windowsIso, autounattendIso: string,
                                     sshPort: int, cpus: int = 4,
                                     memoryMB: int = 8192): seq[string] =
  ## Golden install boot. Three deliberate differences from the per-job boot:
  ##
  ## * ``-no-reboot`` is omitted. Windows setup reboots several times between
  ##   media boot and OOBE, and exiting on the first one leaves a half
  ##   installed disk that looks like a hung build.
  ## * Both ISOs are attached over xHCI, since the aarch64 ``virt`` machine
  ##   has no built-in USB or IDE controller to hang a CD-ROM off.
  ## * The install media takes boot priority and the target disk goes last,
  ##   so the firmware boots the ISO while the empty NVMe disk is still
  ##   unbootable, and prefers the disk once Windows is installed on it.
  ## * A ``usb-kbd`` is attached. The per-job boot needs no input device, but
  ##   the install boot cannot start without one: ``\EFI\BOOT\BOOTAA64.EFI``
  ##   on the install ISO is ``cdboot.efi``, and it waits for a keypress
  ##   before handing over to Windows Setup. See ``QwaInstallMediaKey`` and
  ##   ``answerInstallMediaKeyPrompt`` — the key itself is injected through
  ##   the monitor socket, but there has to be a keyboard for it to arrive on.
  result = qwaMachineArgs(vmDir, vmDir / QwaBaseDiskName, sshPort, cpus,
                          memoryMB, diskBootIndex = 2)
  result.add(@[
    "-device", "qemu-xhci,id=usb",
    "-device", "usb-kbd,bus=usb.0",
    "-drive", "id=installcd,file=" & windowsIso & ",media=cdrom,readonly=on,if=none",
    "-device", "usb-storage,bus=usb.0,drive=installcd,bootindex=0",
    "-drive", "id=unattendcd,file=" & autounattendIso & ",media=cdrom,readonly=on,if=none",
    "-device", "usb-storage,bus=usb.0,drive=unattendcd,bootindex=1"
  ])
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

proc copyFirmwareAndTpm(base, destDir: string) =
  ## Clone the small per-instance firmware bits (UEFI vars ``.fd``, option
  ## ROMs) and seed a writable TPM state directory. These are raw/pflash
  ## files that cannot use a qcow2 backing chain, but they are only a few MB
  ## so a clonefile/copy is cheap.
  for kind, path in walkDir(base):
    if kind != pcFile:
      continue
    let name = extractFilename(path)
    if name.endsWith(".fd") or name.endsWith(".rom") or name.endsWith(".bin"):
      cloneOneFile(path, destDir / name)
  if dirExists(base / "tpm"):
    copyDir(base / "tpm", destDir / "tpm")
    try: removeFile(destDir / "tpm" / ".lock")
    except CatchableError: discard
  else:
    createDir(destDir / "tpm")

proc createEphemeralCopy*(baselineDir, destDir: string) =
  ## Clone mode: a full independent ``windows.qcow2`` per instance
  ## (APFS clonefile on macOS, byte copy elsewhere). Retained as a fallback
  ## for ``VMH_QEMU_WINDOWS_ARM_DISK_MODE=clone``.
  let base = validateWindowsArmVmDir(baselineDir)
  if dirExists(destDir):
    removeDir(destDir)
  createDir(destDir)
  cloneOneFile(base / QwaBaseDiskName, destDir / QwaBaseDiskName)
  copyFirmwareAndTpm(base, destDir)

type
  GoldenSpaceVerdict* = object
    ## Outcome of the pre-build free-space check. Split into "cannot
    ## finish" and "can finish but may starve the fleet" because those want
    ## different answers: the first must stop the build, the second is the
    ## operator's call.
    fatal*: bool
    message*: string

proc qwaGoldenFloorGB*(diskGB: int): int =
  ## Free space below which a golden build cannot be expected to finish.
  ##
  ## A qcow2 cannot outgrow its requested size, so a small requested disk
  ## lowers the floor; beyond the estimated install peak, extra requested
  ## size costs nothing because the image stays sparse.
  ## ``VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB`` overrides the whole computation
  ## for operators who know better than this estimate.
  let override = getEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB").strip()
  if override.len > 0:
    try:
      let v = parseInt(override)
      if v >= 0:
        return v
    except ValueError:
      discard
  min(max(diskGB, 1), QwaGoldenInstallPeakGB) + QwaGoldenBuildSlackGB

proc goldenBuildSpaceVerdict*(freeGB, diskGB: int): GoldenSpaceVerdict =
  ## Pure policy so it can be exercised without a filesystem.
  let floorGB = qwaGoldenFloorGB(diskGB)
  let comfortableGB = floorGB + QwaFleetPeakGB
  if freeGB < floorGB:
    return GoldenSpaceVerdict(fatal: true, message:
      "refusing to start a golden build: " & $freeGB & "GB free, need at " &
      "least " & $floorGB & "GB (estimated install peak for a " & $diskGB &
      "GB image, plus slack). Reclaim space, or set " &
      "VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB if this estimate is wrong.")
  if freeGB < comfortableGB:
    return GoldenSpaceVerdict(fatal: false, message:
      "golden build starting with " & $freeGB & "GB free, below the " &
      $comfortableGB & "GB that leaves room for a saturated fleet (" &
      $QwaFleetPeakGB & "GB). The build should finish, but concurrent CI " &
      "instances may exhaust the disk while it runs.")
  GoldenSpaceVerdict(fatal: false, message: "")

proc freeSpaceGB*(path: string): int =
  ## Free space available to an unprivileged writer, in whole GB. Returns
  ## -1 when it cannot be determined, which callers treat as "unknown" and
  ## must not treat as "full".
  when defined(posix):
    var st: Statvfs
    if statvfs(path.cstring, st) != 0:
      return -1
    let avail = uint64(st.f_frsize) * uint64(st.f_bavail)
    int(avail div (1024'u64 * 1024'u64 * 1024'u64))
  else:
    -1

proc checkGoldenBuildSpace*(path: string, diskGB: int): string =
  ## Raise when a golden build cannot fit; otherwise return a warning to
  ## surface (empty when there is nothing to say). An undeterminable free
  ## figure is not treated as a failure — refusing to build because a
  ## statvfs call failed would be worse than the risk it guards against.
  let freeGB = freeSpaceGB(path)
  if freeGB < 0:
    return "could not determine free space at " & path &
           "; proceeding without a space precondition"
  let verdict = goldenBuildSpaceVerdict(freeGB, diskGB)
  if verdict.fatal:
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning, verdict.message)
  verdict.message

proc prepareGoldenBuildDir*(buildDir: string) =
  ## Create the directory a golden build writes into.
  ##
  ## Refuses to reuse one that already holds a golden disk. In overlay mode a
  ## live instance's ``overlay.qcow2`` names the golden's ``windows.qcow2`` as
  ## its qcow2 backing store, and qcow2 does not verify that a backing file
  ## still holds what the overlay was created against. Rebuilding over one
  ## therefore does *not* fail — every running guest silently continues
  ## against a different disk than the one its writes were taken from. So a
  ## rebuild is an addition: a fresh versioned directory, adopted by moving
  ## the pointer once it validates, never an overwrite.
  if dirExists(buildDir) and fileExists(buildDir / QwaBaseDiskName):
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
      "refusing to build a golden into " & buildDir & ": it already holds " &
      QwaBaseDiskName & ". Live overlays may name that file as their qcow2 " &
      "backing store, and replacing it corrupts them with no error. Build " &
      "into a new versioned directory and move the pointer instead.")
  createDir(buildDir)

proc createGoldenDisk*(qemuImgCmd, buildDir: string, diskGB: int) =
  ## Allocate the empty qcow2 the Windows installer writes into.
  if diskGB <= 0:
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
      "golden disk size must be positive, got " & $diskGB & "GB")
  let disk = buildDir / QwaBaseDiskName
  let createArgs = @[qemuImgCmd, "create", "-f", "qcow2", disk, $diskGB & "G"]
  let r = runProcessCapture(createArgs, timeoutSec = 120)
  if r.exitCode != 0:
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
      "qemu-img create (golden disk " & disk & ") failed (exit " &
      $r.exitCode & "): " & r.stdout & r.stderr)

proc createEphemeralOverlay*(baselineDir, destDir, qemuImgCmd: string) =
  ## Overlay mode (default): create a thin ``overlay.qcow2`` whose qcow2
  ## backing file is the immutable golden ``windows.qcow2``. The golden is
  ## never copied and is shared read-only across every concurrent instance;
  ## the overlay records only the guest's writes. ``qemu-img create`` fails
  ## fast if the backing image is missing or unreadable.
  let base = validateWindowsArmVmDir(baselineDir)
  if dirExists(destDir):
    removeDir(destDir)
  createDir(destDir)
  # Resolve symlinks, not just relative segments. ``base`` comes from
  # validateWindowsArmVmDir, which uses absolutePath and so preserves a
  # symlink in the path. qcow2 stores the backing path as given, so an
  # overlay created through a `golden/win-arm-runner -> win-arm-runner-<id>`
  # pointer would record the pointer — and repointing it at the next build
  # would corrupt exactly the live instances the versioned scheme exists to
  # protect. Recording the resolved path makes a pointer flip affect only
  # instances created after it.
  let backing = expandFilename(base / QwaBaseDiskName)
  let overlay = destDir / QwaOverlayDiskName
  let createArgs = @[qemuImgCmd, "create",
    "-f", "qcow2",
    "-b", backing,
    "-F", "qcow2",
    overlay]
  let r = runProcessCapture(createArgs, timeoutSec = 120)
  if r.exitCode != 0:
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
      "qemu-img create (CoW overlay over " & backing & ") failed (exit " &
      $r.exitCode & "): " & r.stdout & r.stderr)
  copyFirmwareAndTpm(base, destDir)

proc qwaDiskMode*(): string =
  ## ``overlay`` (default) or ``clone``, from
  ## ``VMH_QEMU_WINDOWS_ARM_DISK_MODE``.
  let m = getEnv("VMH_QEMU_WINDOWS_ARM_DISK_MODE").strip().toLowerAscii()
  if m == QwaDiskModeClone: QwaDiskModeClone else: QwaDiskModeOverlay

proc createEphemeralInstance*(b: QemuWindowsArmBackend,
                              baselineDir, destDir: string) =
  ## Provision an ephemeral instance disk using the configured disk mode,
  ## then take the per-instance advisory lock so ``prune`` can tell a live
  ## instance from an orphaned one.
  if qwaDiskMode() == QwaDiskModeClone:
    createEphemeralCopy(baselineDir, destDir)
  else:
    createEphemeralOverlay(baselineDir, destDir, b.qemuImgCmd)

proc acquireInstanceLock*(b: QemuWindowsArmBackend, name, vmDir: string) =
  ## Create + hold ``<vmDir>/.instance.lock`` for the instance's lifetime.
  ## The fd is kept open in ``instanceLockFds``; if this launcher exits or
  ## crashes the OS drops the lock, which is exactly the liveness signal
  ## ``prune`` relies on.
  when defined(posix):
    let lockPath = qwaInstanceLockPath(vmDir)
    let fd = posix.open(lockPath.cstring, O_CREAT or O_RDWR, Mode(0o600))
    if fd < 0:
      return
    if c_flock(fd, LockExclusive or LockNonBlock) != 0:
      discard posix.close(fd)
      return
    b.instanceLockFds[name] = fd

proc releaseInstanceLock*(b: QemuWindowsArmBackend, name: string) =
  when defined(posix):
    if name in b.instanceLockFds:
      let fd = b.instanceLockFds[name]
      discard c_flock(fd, LockUnlock)
      discard posix.close(fd)
      b.instanceLockFds.del(name)

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

proc startQemuArgvInBackground*(b: QemuWindowsArmBackend, vmDir: string,
                                args: seq[string]): int =
  var p = startProcess(b.qemuCmd, args = args,
                       # Keep QEMU as our direct child so the PID stored in the
                       # VmHandle is the process stopAndCleanup must terminate.
                       options = {poUsePath, poParentStreams},
                       workingDir = vmDir)
  result = p.processID

proc startQemuInBackground*(b: QemuWindowsArmBackend, vmDir: string,
                            sshPort, cpus, memoryMB: int): int =
  b.startQemuArgvInBackground(vmDir,
    buildQemuWindowsArmArgs(vmDir, sshPort, cpus, memoryMB))

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

proc startQemuWithAllocatedPortUsing*(b: QemuWindowsArmBackend, vmDir: string,
                                      makeArgs: proc (port: int): seq[string]):
                                      tuple[sshPort: int, pid: int] =
  ## Keep the inter-process allocation lock until QEMU has claimed the chosen
  ## port. This closes the race between probing a free port and QEMU binding
  ## it when multiple ephemeral guests start at the same time.
  ##
  ## Parameterised by the argument vector so the golden install boot — which
  ## differs from the per-job boot only in its media and boot order — shares
  ## this allocation, rather than growing a second one that could hand the
  ## same port to a concurrent CI instance.
  var allocationLock = acquirePortAllocationLock(b.stateDir)
  defer: releasePortAllocationLock(allocationLock)

  for attempt in 0 ..< QemuPortAllocationAttempts:
    let preferred = if attempt == 0: b.sshPort else: 0
    let port = pickTcpPort(preferred)
    let pid = b.startQemuArgvInBackground(vmDir, makeArgs(port))
    if waitForTcpPortClaim(pid, port, QemuPortClaimTimeoutMs):
      return (sshPort: port, pid: pid)
    stopStartedProcess(pid)

  raise newVmHarnessError($b.id, lpStartup,
    "QemuWindowsArmBackend: QEMU failed to claim an allocated SSH port after " &
    $QemuPortAllocationAttempts & " attempts")

proc startQemuWithAllocatedPort*(b: QemuWindowsArmBackend, vmDir: string,
                                 cpus, memoryMB: int):
                                 tuple[sshPort: int, pid: int] =
  b.startQemuWithAllocatedPortUsing(vmDir,
    proc (port: int): seq[string] =
      buildQemuWindowsArmArgs(vmDir, port, cpus, memoryMB))

# ---------------------------------------------------------------------------
# Golden build orchestration — Runner-Fleet-M3-ARM-Wave MA3.
#
# Everything below drives an unattended Windows ARM64 install to a validated,
# self-describing golden directory. The argument vector, the rebuild-safety
# guard, the disk allocation and the free-space precondition are above; this
# is the part that actually runs them, in order, under one deadline.
# ---------------------------------------------------------------------------

proc qemuProcessGone*(pid: int): bool =
  ## True once the QEMU we started is no longer running. ``childProcessExited``
  ## reaps a direct child, so a zombie is not mistaken for a live guest;
  ## ``pidAlive`` covers a pid we did not fork.
  if pid <= 0:
    return true
  childProcessExited(pid) or not pidAlive(pid)

proc queryQemuMonitor*(monitorPath, command: string,
                       timeoutMs: int = 2000): string =
  ## Send one command to QEMU's monitor socket and return what it says.
  ##
  ## Returns "" when the socket is absent or unusable. That is not an error
  ## condition to the caller: QEMU's default action on a guest power-off is
  ## to EXIT, which takes the socket with it, so a vanished socket is itself
  ## part of the signal this exists to read.
  when defined(posix):
    if monitorPath.len == 0 or not pathExists(monitorPath):
      return ""
    var sock: Socket
    try:
      sock = newSocket(net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                       net.Protocol.IPPROTO_IP)
    except CatchableError:
      return ""
    try:
      sock.connectUnix(monitorPath)
    except CatchableError:
      try: sock.close()
      except CatchableError: discard
      return ""
    defer:
      try: sock.close()
      except CatchableError: discard
    var text = ""
    let deadline = epochTime() + timeoutMs.float / 1000.0
    try:
      # Ask FIRST, then read lines.
      #
      # The monitor greets with a banner that ends in a bare ``(qemu) ``
      # prompt carrying no newline, so there is nothing to "drain" before
      # asking — a reader that waited for the greeting to finish would wait
      # for output that only arrives once something has been asked. Reading
      # is line-oriented on purpose: ``recv`` with a byte count and a timeout
      # insists on filling the WHOLE buffer before it returns, so asking it
      # for 4 KiB of a 40-byte reply times out on a perfectly healthy
      # monitor — which reads exactly like a dead guest.
      sock.send(command & "\n")
      var emptyLines = 0
      while epochTime() < deadline:
        let remainingMs = max(1, int((deadline - epochTime()) * 1000.0))
        var line = ""
        sock.readLine(line, timeout = remainingMs)
        if line.len == 0:
          inc emptyLines
          if emptyLines >= 3:
            break   # the peer went away
          continue
        emptyLines = 0
        text.add(line)
        text.add("\n")
        if "VM status:" in line:
          break
    except CatchableError:
      discard
    text
  else:
    ""

proc sendQemuMonitorCommand*(monitorPath, command: string,
                             timeoutMs: int = 500): bool =
  ## Send one command to QEMU's monitor and report whether the monitor took
  ## it. Separate from ``queryQemuMonitor`` because there is no reply to
  ## recognise: a ``sendkey`` is answered with nothing but a fresh ``(qemu) ``
  ## prompt, which carries no newline.
  ##
  ## It still DRAINS for ``timeoutMs`` before hanging up, and that is not
  ## politeness. A monitor is a stream peer being written to by something
  ## that does not expect its reader to vanish mid-reply; closing on it with
  ## a reply in flight is a hangup during someone else's ``write``. The one
  ## measured consequence so far was in the unit tier's fake monitor, which
  ## wedged in ``send`` and stopped accepting connections at all — so the
  ## power-off watch that runs AFTER the keypress phase saw a dead monitor
  ## and a live process, and reported a powered-off guest as running until
  ## the deadline. Draining costs one bounded wait per keypress and removes
  ## the whole class.
  when defined(posix):
    if monitorPath.len == 0 or not pathExists(monitorPath):
      return false
    var sock: Socket
    try:
      sock = newSocket(net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                       net.Protocol.IPPROTO_IP)
    except CatchableError:
      return false
    try:
      sock.connectUnix(monitorPath)
    except CatchableError:
      try: sock.close()
      except CatchableError: discard
      return false
    defer:
      try: sock.close()
      except CatchableError: discard
    try:
      sock.send(command & "\n")
    except CatchableError:
      return false
    # Drain whatever the monitor says back, until the bound. The last thing
    # it writes is a bare ``(qemu) `` prompt with no newline, so this always
    # ends on the timeout rather than on a recognised reply — that is the
    # shape of the protocol, not a missed case.
    let drainUntil = epochTime() + timeoutMs.float / 1000.0
    try:
      while epochTime() < drainUntil:
        let remainingMs = max(1, int((drainUntil - epochTime()) * 1000.0))
        var line = ""
        sock.readLine(line, timeout = remainingMs)
        if line.len == 0:
          break     # the monitor hung up
    except CatchableError:
      discard
    true
  else:
    false

proc goldenDiskProgressed*(diskPath: string,
                           thresholdBytes: int64 = QwaInstallProgressBytes):
                           bool =
  ## True once the target qcow2 has grown past ``thresholdBytes``, which means
  ## the guest is writing to it — the one observation available off-band that
  ## says Windows Setup got past the boot-media prompt and started.
  try:
    getFileSize(diskPath) > thresholdBytes
  except CatchableError:
    false

proc monitorTextSaysPoweredOff*(text: string): bool =
  ## Read a QEMU monitor ``info status`` reply.
  ##
  ## The monitor answers ``VM status: running`` while the guest is up. A
  ## guest that has powered itself off is reported as ``paused (shutdown)``
  ## when QEMU was told to stay alive across it. Only the status LINE is
  ## examined: the greeting banner and the echoed command share the stream,
  ## and "shutdown" appears in the command we just sent to nothing of the
  ## sort.
  if text.len == 0:
    return false
  let lower = text.toLowerAscii()
  let idx = lower.rfind("vm status:")
  if idx < 0:
    return false
  let line = lower[idx + len("vm status:") .. ^1].split('\n')[0]
  "shutdown" in line

proc guestPoweredOff*(monitorPath: string, qemuPid: int): bool =
  ## One power-off observation, taken through the monitor socket and NEVER
  ## over SSH. ``sysprep /shutdown`` powers the guest off underneath every
  ## SSH session it has, so SSH cannot report the event it causes.
  let text = queryQemuMonitor(monitorPath, "info status")
  if text.len > 0 and "vm status:" in text.toLowerAscii():
    return monitorTextSaysPoweredOff(text)
  # No monitor to ask. QEMU exits on guest power-off unless told otherwise,
  # so a gone socket plus a gone process is the same event seen from outside.
  qemuProcessGone(qemuPid)

proc sleepUntilNextPoll(deadline: float, pollMs: int): bool =
  ## Sleep for at most ``pollMs``, and never past ``deadline``. Returns false
  ## once the deadline has arrived, so a caller's bound is the deadline it was
  ## given rather than "the deadline, rounded up to the next poll".
  let remainingSec = deadline - epochTime()
  if remainingSec <= 0:
    return false
  sleep(min(pollMs, int(remainingSec * 1000.0) + 1))
  true

proc waitForGuestPowerOff*(monitorPath: string, qemuPid: int,
                           deadline: float,
                           pollMs: int = QwaPowerOffPollMs): bool =
  ## Poll for power-off until ``deadline`` (an absolute ``epochTime``).
  while true:
    if guestPoweredOff(monitorPath, qemuPid):
      return true
    if not sleepUntilNextPoll(deadline, pollMs):
      return false

proc answerInstallMediaKeyPrompt*(monitorPath, diskPath: string, qemuPid: int,
                                  deadline: float,
                                  windowSec: int = QwaInstallKeyPressWindowSec,
                                  intervalMs: int = QwaInstallKeyPressIntervalMs,
                                  key: string = QwaInstallMediaKey): int =
  ## Answer ``cdboot.efi``'s "Press any key to boot from CD or DVD" prompt on
  ## the install boot, and then STOP. Returns how many keypresses were
  ## delivered.
  ##
  ## Both halves matter. Without a keypress the install never starts: the
  ## headless machine shape has no input device, so the prompt times out,
  ## ``BdsDxe`` reports ``failed to start Boot0001 ...: Time out`` and falls
  ## through to the EFI shell. Without STOPPING, Setup's own reboots — which
  ## rely on that same prompt timing out to fall past the still-first install
  ## media and onto the disk it is installing to — would be answered too, and
  ## Setup would restart from the media instead of continuing.
  ##
  ## So the window is bounded three ways: the disk starting to grow (Setup is
  ## past the prompt and writing), the given ``windowSec``, and the overall
  ## build deadline. It never outlives the shortest of them.
  result = 0
  if windowSec <= 0:
    return
  let windowEnd = min(epochTime() + windowSec.float, deadline)
  while epochTime() < windowEnd:
    if qemuProcessGone(qemuPid):
      return
    if goldenDiskProgressed(diskPath):
      return
    if sendQemuMonitorCommand(monitorPath, "sendkey " & key):
      inc result
    if not sleepUntilNextPoll(windowEnd, intervalMs):
      return

proc buildInstallSentinelProbe*(): string =
  ## A remote command that prints ``QwaInstallDoneMarker`` exactly when the
  ## sentinel ``autounattend.xml`` writes from its last FirstLogonCommand is
  ## present, and fails otherwise.
  "powershell.exe -NoLogo -NoProfile -Command \"if (Test-Path -LiteralPath '" &
    QwaInstallSentinelPath & "') { Write-Output '" & QwaInstallDoneMarker &
    "'; exit 0 } else { exit 1 }\""

proc installSentinelPresent*(b: QemuWindowsArmBackend, port: int): bool =
  ## One probe. Requires BOTH a zero exit and the marker on stdout: an ssh
  ## transport that succeeds without running anything must not read as a
  ## finished install.
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  let cmd = b.buildSshpassSshArgs(pwdFile, port, buildInstallSentinelProbe())
  let r = runProcessCapture(cmd, timeoutSec = 60)
  r.exitCode == 0 and QwaInstallDoneMarker in r.stdout

proc waitForInstallSentinel*(b: QemuWindowsArmBackend, port: int,
                             deadline: float,
                             pollMs: int = QwaSentinelPollMs): bool =
  ## Wait for the unattended install to declare itself finished.
  ##
  ## Not "wait for SSH": OpenSSH comes up partway through the
  ## FirstLogonCommands chain, so a guest that answers SSH may still be
  ## installing Git, PowerShell 7 and the NetKVM driver. The sentinel is
  ## written last, and only if sshd is genuinely running.
  while true:
    if b.installSentinelPresent(port):
      return true
    if not sleepUntilNextPoll(deadline, pollMs):
      return false

proc buildSysprepCommand*(modeVm: bool = true): seq[string] =
  ## ``/generalize`` is load-bearing and must never be dropped: without it
  ## every ephemeral clone of the golden shares one machine SID.
  ##
  ## ``/mode:vm`` matches what the checked-in recipe README documents as the
  ## invocation that produced a working golden. It skips the first-boot
  ## hardware-detection pass, which is sound here precisely because every
  ## instance boots the identical QEMU machine shape this file builds.
  result = @[QwaSysprepExePath, "/generalize", "/oobe", "/shutdown"]
  if modeVm:
    result.add("/mode:vm")
  result.add("/unattend:" & QwaSysprepAnswerGuestPath)

proc buildSysprepRemoteCommand*(modeVm: bool = true): string =
  ## Launch sysprep so that it OUTLIVES the SSH session that starts it.
  ##
  ## ``/shutdown`` powers the guest off under that session, and a generalize
  ## takes 10-20 minutes, so a session-bound invocation is one hangup away
  ## from a half-generalized disk that still looks like a golden.
  ##
  ## ``Start-Process`` does NOT achieve that, which is the assumption this
  ## code shipped on and MA4's host run disproved. Windows OpenSSH puts every
  ## process of a session into a JOB OBJECT and terminates the job when the
  ## session ends; a ``Start-Process`` child stays inside that job. MEASURED
  ## on m3 2026-09-15 with a harmless long-running process: launched with
  ## ``Start-Process`` it was GONE two seconds after the session closed
  ## (0 survivors); launched through ``Win32_Process.Create`` it was still
  ## running 25 seconds later. The real consequence was worse than the probe:
  ## sysprep logged four lines, reached "Beginning action execution from
  ## Cleanup.xml", and died one second in — after which the build sat waiting
  ## for a power-off from a process that no longer existed.
  ##
  ## ``Win32_Process.Create`` is the fix because the new process is created
  ## by the WMI provider host, not by this session, so it is not in the
  ## session's job at all. A non-zero ``ReturnValue`` exits non-zero so the
  ## harness reports a sysprep that never started, rather than waiting.
  ## NO ``$`` ANYWHERE IN THE COMMAND. ``provision-openssh.ps1`` sets sshd's
  ## ``DefaultShell`` to powershell.exe, so what arrives over SSH is parsed
  ## by an OUTER PowerShell before the inner ``powershell.exe -Command``
  ## string ever exists — and that outer parse expands ``$`` inside double
  ## quotes. MEASURED on m3 2026-09-15: a first cut that stashed the result
  ## in ``$r`` arrived in the guest as ``rc=' + .ReturnValue``, a parse
  ## error, because ``$r`` had already been substituted away as an undefined
  ## variable. Every other remote command this file builds happens to be
  ## ``$``-free; this one has to be so deliberately, and the gate asserts it.
  let argv = buildSysprepCommand(modeVm)
  var commandLine = argv[0]
  for a in argv[1 .. ^1]:
    commandLine.add(" " & a)
  "powershell.exe -NoLogo -NoProfile -Command \"Write-Output '" &
    QwaSysprepCreateMarker & "'; if ((Invoke-CimMethod -ClassName " &
    "Win32_Process -MethodName Create -Arguments @{CommandLine = " &
    powershellLiteral(commandLine) & "}).ReturnValue -ne 0) " &
    "{ exit 1 }; exit 0\""

proc buildSysprepRunningProbe*(): string =
  ## A remote command that succeeds only while ``sysprep.exe`` is actually
  ## running in the guest.
  "powershell.exe -NoLogo -NoProfile -Command \"if (Get-Process sysprep " &
    "-ErrorAction SilentlyContinue) { Write-Output '" &
    QwaSysprepRunningMarker & "'; exit 0 } else { exit 1 }\""

proc runGuestSysprep*(b: QemuWindowsArmBackend, port: int,
                      modeVm: bool = true): ExecResult =
  ## Kick sysprep off. The returned status says whether the LAUNCH was
  ## accepted, not whether the golden generalized — that is what the power-off
  ## observation is for.
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  let cmd = b.buildSshpassSshArgs(pwdFile, port,
                                  buildSysprepRemoteCommand(modeVm))
  var last = ExecResult(exitCode: -1)
  for attempt in 1 .. QemuSshAttempts:
    last = runProcessCapture(cmd, timeoutSec = 300)
    if not transientSshFailure(last) or attempt == QemuSshAttempts:
      return last
    sleep(QemuSshRetryDelayMs)
  last

proc sysprepRunning*(b: QemuWindowsArmBackend, port: int): bool =
  ## One probe. Requires BOTH a zero exit and the marker on stdout.
  let pwdFile = writePasswordFile(b.sshPassword)
  defer:
    try: removeFile(pwdFile)
    except CatchableError: discard
  let cmd = b.buildSshpassSshArgs(pwdFile, port, buildSysprepRunningProbe())
  let r = runProcessCapture(cmd, timeoutSec = 60)
  r.exitCode == 0 and QwaSysprepRunningMarker in r.stdout

proc sysprepTookHold*(b: QemuWindowsArmBackend, port: int,
                      monitorPath: string, qemuPid: int,
                      deadline: float,
                      windowSec: int = QwaSysprepTakeHoldSec,
                      pollMs: int = QwaSysprepTakeHoldPollMs): bool =
  ## Confirm that sysprep is STILL THERE shortly after being launched.
  ##
  ## The launch reporting success says only that the guest accepted the
  ## command. MEASURED on m3 2026-09-15: a sysprep launched into the SSH
  ## session's job object is killed about a second after the session closes,
  ## having logged four lines and generalized nothing — and the build then
  ## waits out its entire deadline for a power-off from a process that no
  ## longer exists. That is a 90-minute silence for a failure that is visible
  ## in ten seconds, so it is checked instead of assumed.
  ##
  ## "Powered off already" counts as taking hold: a generalize normally runs
  ## for minutes, but a build must not fail because sysprep beat the first
  ## poll to the finish line.
  let windowEnd = min(epochTime() + windowSec.float, deadline)
  while true:
    if guestPoweredOff(monitorPath, qemuPid):
      return true
    if b.sysprepRunning(port):
      return true
    if not sleepUntilNextPoll(windowEnd, pollMs):
      return false

proc machineSidFromUserSid*(sid: string): string =
  ## The machine SID is an account SID with its trailing RID removed.
  ##
  ## Two clones of a golden that was NOT generalized report the same value
  ## here, which is the whole point of gating on ``/generalize``. Returns ""
  ## for anything that is not a well-formed ``S-1-5-21-…-RID``.
  let parts = sid.strip().split('-')
  if parts.len < 5 or not parts[0].toLowerAscii().startsWith("s"):
    return ""
  for p in parts[1 .. ^1]:
    if p.len == 0:
      return ""
    for c in p:
      if c notin {'0' .. '9'}:
        return ""
  parts[0 .. ^2].join("-")

proc qwaFirmwareSearchDirs(): seq[string] =
  ## ``VMH_QEMU_FIRMWARE_DIR`` REPLACES the well-known list rather than being
  ## prepended to it, so an operator who names a firmware directory gets that
  ## firmware and not whatever a package manager happens to have installed.
  let explicit = getEnv("VMH_QEMU_FIRMWARE_DIR")
  if explicit.len > 0:
    return @[explicit]
  @["/opt/homebrew/share/qemu", "/usr/local/share/qemu",
    "/usr/share/qemu", "/usr/share/AAVMF",
    "/usr/share/edk2/aarch64", "/usr/share/edk2-armvirt"]

proc findFirmwareFile(names: openArray[string]): string =
  for dir in qwaFirmwareSearchDirs():
    for n in names:
      let c = dir / n
      if fileExists(c):
        return c
  ""

proc stageGoldenFirmware*(buildDir: string) =
  ## Give the build its own UEFI code + vars pair inside ``buildDir``.
  ##
  ## ``qemuFirmwareArgs`` resolves firmware from the VM directory, and a
  ## fresh golden directory has none. The vars file must be per-build and
  ## writable — Windows Setup writes its boot entry into it — so it is copied
  ## in rather than referenced in place.
  let codeDest = buildDir / "QEMU_EFI.fd"
  let varsDest = buildDir / "QEMU_VARS.fd"
  if not fileExists(codeDest):
    var code = getEnv("VMH_QEMU_EFI_CODE_TEMPLATE")
    if code.len == 0 or not fileExists(code):
      code = getEnv("VMH_QEMU_EFI_CODE")
    if code.len == 0 or not fileExists(code):
      code = findFirmwareFile(["edk2-aarch64-code.fd", "QEMU_EFI.fd",
                               "AAVMF_CODE.fd"])
    if code.len == 0:
      raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
        "no aarch64 UEFI firmware found for the golden build. Set " &
        "VMH_QEMU_EFI_CODE_TEMPLATE (or VMH_QEMU_FIRMWARE_DIR) to a " &
        "directory holding edk2-aarch64-code.fd; without firmware QEMU " &
        "boots nothing and the install hangs with no diagnostic.")
    copyFile(code, codeDest)
  if not fileExists(varsDest):
    var vars = getEnv("VMH_QEMU_EFI_VARS_TEMPLATE")
    if vars.len == 0 or not fileExists(vars):
      vars = findFirmwareFile(["edk2-arm-vars.fd", "QEMU_VARS.fd",
                               "AAVMF_VARS.fd"])
    if vars.len == 0:
      raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
        "no aarch64 UEFI variable-store template found for the golden " &
        "build. Set VMH_QEMU_EFI_VARS_TEMPLATE (or VMH_QEMU_FIRMWARE_DIR) " &
        "to a directory holding edk2-arm-vars.fd.")
    copyFile(vars, varsDest)
  try:
    setFilePermissions(varsDest, {fpUserRead, fpUserWrite})
  except CatchableError:
    discard

proc finalizeGoldenDir*(buildDir: string): string =
  ## Turn a finished install directory into a golden, and prove it is one.
  ##
  ## Dropping the CD-ROMs is the point: the install media are build INPUTS,
  ## not part of the artifact, and will not be present when the golden is
  ## consumed. The per-job argument vector for this directory is rebuilt here
  ## and asserted to attach none of them, so a change that made the run path
  ## depend on the ISOs fails the BUILD instead of the next cold boot on m3.
  for leftover in [QwaOverlayDiskName, QwaInstanceLockName]:
    try: removeFile(buildDir / leftover)
    except CatchableError: discard
  try: removeFile(buildDir / "tpm" / ".lock")
  except CatchableError: discard
  for a in buildQemuWindowsArmArgs(buildDir, 0):
    if "media=cdrom" in a or "usb-storage" in a:
      raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
        "the golden at " & buildDir & " would still boot with install " &
        "media attached (" & a & "). The ISOs are build inputs and are not " &
        "part of the artifact.")
  try:
    result = validateWindowsArmVmDir(buildDir)
  except ValueError as e:
    raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
      "the golden build did not produce a directory the consuming path " &
      "accepts: " & e.msg)

proc fileSha256*(path: string): string =
  ## Content digest via the platform's coreutils. Nim's stdlib ships only
  ## SHA-1, and a provenance record is exactly the place not to use it.
  for cmd in [@["shasum", "-a", "256", path], @["sha256sum", path]]:
    var r = ExecResult(exitCode: -1)
    try:
      r = runProcessCapture(cmd, timeoutSec = 900, mergeStderr = false)
    except CatchableError:
      continue
    if r.exitCode == 0:
      let fields = r.stdout.strip().splitWhitespace()
      if fields.len > 0 and fields[0].len == 64:
        return fields[0].toLowerAscii()
  raise newVmHarnessError($biQemuWindowsArm, lpProvisioning,
    "cannot compute a SHA-256 for " & path &
    ": neither shasum nor sha256sum produced a digest")

proc recipeCommitOf*(dir: string): tuple[commit: string, dirty: bool] =
  ## The recipe's git provenance, best effort. An unknown commit is recorded
  ## as "" rather than guessed — a manifest that lies about where a golden
  ## came from is worse than one that admits it does not know.
  result = (commit: "", dirty: false)
  if dir.len == 0 or not dirExists(dir):
    return
  try:
    let rev = runProcessCapture(@["git", "-C", dir, "rev-parse", "HEAD"],
                                timeoutSec = 30, mergeStderr = false)
    if rev.exitCode != 0:
      return
    result.commit = rev.stdout.strip()
    let st = runProcessCapture(
      @["git", "-C", dir, "status", "--porcelain", "--", dir],
      timeoutSec = 120, mergeStderr = false)
    result.dirty = st.exitCode == 0 and st.stdout.strip().len > 0
  except CatchableError:
    discard

type
  GoldenManifestInputs* = object
    ## Everything a golden of unknown provenance needs in order to say what
    ## it is. The artifact this work replaces had none of it, which is why
    ## nobody could tell what had been lost.
    baseline*: string
    buildDir*: string
    diskGB*: int
    windowsIso*: string
    autounattendIso*: string
    recipeDir*: string
    builtAt*: string
      ## RFC3339 UTC. Injectable so the record itself can be asserted on.

proc goldenManifestJson*(inp: GoldenManifestInputs): JsonNode =
  let recipe = recipeCommitOf(inp.recipeDir)
  var answerFiles = newJObject()
  for name in QwaRecipeAnswerFiles:
    let p = inp.recipeDir / name
    if fileExists(p):
      answerFiles[name] = %fileSha256(p)
  result = %*{
    "schema": QwaGoldenManifestSchema,
    "baseline": inp.baseline,
    "builtAt": (if inp.builtAt.len > 0: inp.builtAt
                else: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")),
    "vmHarnessVersion": QwaVmHarnessVersion,
    "diskGB": inp.diskGB,
    "windowsIso": {
      "path": inp.windowsIso,
      "sha256": (if fileExists(inp.windowsIso): fileSha256(inp.windowsIso)
                 else: "")
    },
    "autounattendIso": {
      "path": inp.autounattendIso,
      "sha256": (if fileExists(inp.autounattendIso):
                   fileSha256(inp.autounattendIso)
                 else: "")
    },
    "recipe": {
      "dir": inp.recipeDir,
      "commit": recipe.commit,
      "dirty": recipe.dirty
    },
    "answerFiles": answerFiles
  }

proc writeGoldenManifest*(inp: GoldenManifestInputs): string =
  let path = inp.buildDir / QwaGoldenManifestName
  writeFile(path, pretty(goldenManifestJson(inp)) & "\n")
  path

proc staleAnswerIsoRecipeFiles*(autounattendIso, recipeDir: string): seq[string] =
  ## Recipe files that are NEWER than the answer-file ISO said to carry them.
  ##
  ## The manifest digests two things that have to agree and are produced by
  ## different steps: the ISO the build actually consumed, and the RECIPE
  ## FILES on disk. Nothing regenerates the ISO when a recipe file changes —
  ## ``build/`` is a gitignored artifact built by hand — so the two can drift
  ## apart silently, and when they do the manifest claims provenance the
  ## golden does not have.
  ##
  ## MEASURED on m3 2026-09-15, before the first host run:
  ## ``guest-recipes/windows-arm-base/build/autounattend.iso`` was 7.6 MiB
  ## from 2026-07-06 while ``autounattend.xml``, ``repro-sysprep.xml`` and
  ## ``provision-openssh.ps1`` were from 2026-09-08 — it predated the
  ## Git-for-Windows, PowerShell-7 and credential-expiry changes entirely.
  ## A build from it would have installed the July recipe and recorded the
  ## September one.
  ##
  ## This is a staleness HEURISTIC, not a proof: it compares modification
  ## times, and cannot tell that an ISO rebuilt after an edit actually
  ## carries it. Proving that means reading the ISO's contents, which needs
  ## ISO tooling this path does not otherwise want. It catches the drift that
  ## was actually observed, and it costs one stat per file.
  if recipeDir.len == 0 or not fileExists(autounattendIso):
    return
  let isoTime = getLastModificationTime(autounattendIso)
  for name in QwaRecipeAnswerFiles:
    let p = recipeDir / name
    if fileExists(p) and getLastModificationTime(p) > isoTime:
      result.add(name)

type
  GoldenBuildSpec* = object
    buildDir*: string
      ## A NEW versioned directory. Never an existing golden — see
      ## ``prepareGoldenBuildDir``.
    baseline*: string
    windowsIso*: string
    autounattendIso*: string
    recipeDir*: string
    diskGB*: int
    cpus*: int
    memoryMB*: int
    deadlineSec*: int
    sysprepModeVm*: bool
    keyPressWindowSec*: int
      ## How long to keep answering the install media's keypress prompt. See
      ## ``answerInstallMediaKeyPrompt``; 0 disables it, which is only ever
      ## right for a test that wants to prove the prompt is what stalls a
      ## headless install.

proc newGoldenBuildSpec*(buildDir, windowsIso, autounattendIso: string,
                         baseline = "win-arm-runner",
                         recipeDir = "",
                         diskGB = QwaDefaultGoldenDiskGB,
                         cpus = 4, memoryMB = 8192,
                         deadlineSec = QwaDefaultGoldenDeadlineSec,
                         sysprepModeVm = true,
                         keyPressWindowSec = QwaInstallKeyPressWindowSec):
                         GoldenBuildSpec =
  GoldenBuildSpec(buildDir: buildDir, baseline: baseline,
                  windowsIso: windowsIso, autounattendIso: autounattendIso,
                  recipeDir: recipeDir, diskGB: diskGB, cpus: cpus,
                  memoryMB: memoryMB, deadlineSec: deadlineSec,
                  sysprepModeVm: sysprepModeVm,
                  keyPressWindowSec: keyPressWindowSec)

const QwaGoldenScreenshotName* = "screen.ppm"
  ## Where a failed golden build dumps the guest's framebuffer. The design
  ## claimed ramfb "is captured"; it was not, and could not be — ``-display
  ## none`` renders nowhere. MEASURED on m3 2026-09-15: the framebuffer was
  ## the artifact that turned a blind 90-minute timeout into a ten-second
  ## diagnosis, because a Windows guest says nothing at all on the serial
  ## port once the firmware hands over.

proc captureGuestScreen*(monitorPath, buildDir: string): string =
  ## Dump the guest framebuffer through the monitor's ``screendump``, and
  ## return the path when one landed. Best effort: a guest whose QEMU has
  ## already exited has no framebuffer to dump, and that is not a new failure.
  let dest = buildDir / QwaGoldenScreenshotName
  try: removeFile(dest)
  except CatchableError: discard
  if not sendQemuMonitorCommand(monitorPath, "screendump " & dest,
                                timeoutMs = 3000):
    return ""
  # screendump writes before it answers, but give a large framebuffer a
  # moment rather than racing it.
  for _ in 1 .. 10:
    if fileExists(dest) and getFileSize(dest) > 0:
      return dest
    sleep(200)
  if fileExists(dest): dest else: ""

proc goldenBuildDiagnostics*(buildDir: string): string =
  ## The tail every golden-build failure carries. A Windows install that goes
  ## wrong has no console and no SSH, so the serial log, QEMU's own log and
  ## the framebuffer dump are the entire diagnostic surface — and they are
  ## only useful if the failure path says where they are and leaves them
  ## there.
  result = " Diagnostics retained: " & (buildDir / "serial.log") &
    " (guest serial console) and " & (buildDir / "qemu.log")
  if fileExists(buildDir / QwaGoldenScreenshotName):
    result.add(" and " & (buildDir / QwaGoldenScreenshotName) &
      " (guest framebuffer at the moment of failure — read this FIRST; a " &
      "Windows guest is silent on the serial port once the firmware hands " &
      "over, so the screen is the only thing that says where it stopped)")
  result.add("; " & buildDir & " is left in place. Start the next attempt " &
    "in a NEW versioned directory — never reuse this one, and never " &
    "rebuild over a live golden.")

proc goldenBuildFailure*(buildDir, msg: string): ref VmHarnessError =
  ## Grab the framebuffer BEFORE composing the message: every raise below
  ## happens while QEMU is still alive (the teardown is in the caller's
  ## ``finally``), and once it exits the screen is gone for good.
  discard captureGuestScreen(qwaMonitorSocketPath(buildDir), buildDir)
  newVmHarnessError($biQemuWindowsArm, lpProvisioning,
                    msg & goldenBuildDiagnostics(buildDir))

proc buildWindowsArmGolden*(b: QemuWindowsArmBackend,
                            spec: GoldenBuildSpec): string =
  ## Drive an unattended Windows ARM64 install to a validated golden and
  ## return the directory holding it.
  ##
  ## The run is bounded by ONE deadline covering install, sysprep and
  ## power-off, and every exit that is not a finished golden leaves the build
  ## directory and both logs behind. The directory is inert until something
  ## points at it, so a failed build costs disk and nothing else: adoption is
  ## a separate pointer flip, never an overwrite.
  if spec.buildDir.len == 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "golden build: buildDir is empty")
  if not fileExists(spec.windowsIso):
    raise newVmHarnessError($b.id, lpProvisioning,
      "golden build: Windows ARM64 ISO not found: " & spec.windowsIso &
      ". The ISO is an operator-supplied input; the harness never " &
      "downloads it.")
  if not fileExists(spec.autounattendIso):
    raise newVmHarnessError($b.id, lpProvisioning,
      "golden build: answer-file ISO not found: " & spec.autounattendIso &
      ". Build it with guest-recipes/windows-arm-base/" &
      "build-autounattend-iso.sh.")
  # Refuse BEFORE spending an hour, not after: a golden built from a stale
  # ISO records the recipe files on disk and installs different ones.
  let stale = staleAnswerIsoRecipeFiles(spec.autounattendIso, spec.recipeDir)
  if stale.len > 0:
    raise newVmHarnessError($b.id, lpProvisioning,
      "golden build: the answer-file ISO " & spec.autounattendIso &
      " is OLDER than the recipe files it is supposed to carry (" &
      stale.join(", ") & "). The manifest digests the recipe files, so a " &
      "build from a stale ISO produces a golden whose manifest claims " &
      "provenance it does not have — MEASURED on m3 2026-09-15, where the " &
      "ISO on disk predated the Git, PowerShell and credential changes by " &
      "two months. Rebuild it with guest-recipes/windows-arm-base/" &
      "build-autounattend-iso.sh and start again.")
  let diskGB = if spec.diskGB > 0: spec.diskGB else: QwaDefaultGoldenDiskGB
  let cpus = if spec.cpus > 0: spec.cpus else: 4
  let memoryMB = if spec.memoryMB > 0: spec.memoryMB else: 8192
  let deadlineSec =
    if spec.deadlineSec > 0: spec.deadlineSec else: QwaDefaultGoldenDeadlineSec

  let warning = checkGoldenBuildSpace(parentDir(absolutePath(spec.buildDir)),
                                      diskGB)
  if warning.len > 0:
    stderr.writeLine("[vm-harness] " & warning)

  prepareGoldenBuildDir(spec.buildDir)
  let buildDir = absolutePath(spec.buildDir)
  stageGoldenFirmware(buildDir)
  createGoldenDisk(b.qemuImgCmd, buildDir, diskGB)

  let deadline = epochTime() + deadlineSec.float
  var swtpmPid = 0
  var qemuPid = 0
  try:
    swtpmPid = b.startSwtpmInBackground(buildDir)
    var started: tuple[sshPort: int, pid: int]
    try:
      started = b.startQemuWithAllocatedPortUsing(buildDir,
        proc (port: int): seq[string] =
          buildQemuWindowsArmInstallArgs(buildDir, spec.windowsIso,
                                         spec.autounattendIso, port,
                                         cpus, memoryMB))
    except CatchableError as e:
      raise goldenBuildFailure(buildDir,
        "the golden install boot did not start: " & e.msg & ".")
    qemuPid = started.pid

    # cdboot.efi will not hand over to Windows Setup until a key is pressed,
    # and this machine shape has no input device an operator could press one
    # on. Bounded, and it stops the moment Setup starts writing — see
    # answerInstallMediaKeyPrompt for why continuing would be worse than not
    # starting.
    let keysSent = answerInstallMediaKeyPrompt(
      qwaMonitorSocketPath(buildDir), buildDir / QwaBaseDiskName, qemuPid,
      deadline, windowSec = spec.keyPressWindowSec)
    if spec.keyPressWindowSec > 0 and keysSent == 0:
      stderr.writeLine("[vm-harness] golden build: not one keypress reached " &
        "the install boot's monitor at " & qwaMonitorSocketPath(buildDir) &
        ". If the install never starts, that is why: cdboot.efi waits for a " &
        "key it will never get.")

    if not b.waitForInstallSentinel(started.sshPort, deadline):
      raise goldenBuildFailure(buildDir,
        "the unattended install did not reach " & QwaInstallSentinelPath &
        " within " & $deadlineSec & "s. The sentinel is written by the LAST " &
        "FirstLogonCommand in autounattend.xml and only once sshd is " &
        "running, so a guest stuck at OOBE, a rejected answer file or a " &
        "failed OpenSSH provisioning all land here. Read serial.log FIRST: " &
        "if it ends in \"failed to start Boot0001\" and an EFI shell prompt, " &
        "Windows Setup never ran at all because cdboot.efi's keypress " &
        "prompt went unanswered (" & $keysSent & " keypresses were " &
        "delivered), not because the answer file is wrong.")

    let sysprep = b.runGuestSysprep(started.sshPort, spec.sysprepModeVm)
    if sysprep.exitCode != 0 and not transientSshFailure(sysprep):
      raise goldenBuildFailure(buildDir,
        "sysprep could not be launched in the guest (exit " &
        $sysprep.exitCode & "): " & sysprep.stdout & sysprep.stderr & ".")

    if not b.sysprepTookHold(started.sshPort, qwaMonitorSocketPath(buildDir),
                             qemuPid, deadline):
      raise goldenBuildFailure(buildDir,
        "sysprep was launched but was not running " &
        $QwaSysprepTakeHoldSec & "s later, and the guest has not powered " &
        "off. That is what a sysprep killed with the SSH session that " &
        "started it looks like: it logs a few lines to " &
        "C:\\Windows\\System32\\Sysprep\\Panther\\setupact.log, generalizes " &
        "nothing, and leaves the build waiting for a power-off that can " &
        "never come. Checked here so the failure costs seconds instead of " &
        "the whole deadline.")

    if not waitForGuestPowerOff(qwaMonitorSocketPath(buildDir), qemuPid,
                                deadline):
      raise goldenBuildFailure(buildDir,
        "sysprep /generalize /shutdown did not power the guest off before " &
        "the " & $deadlineSec & "s deadline. A guest still running here has " &
        "NOT been generalized, and every clone of the resulting disk would " &
        "share one machine SID.")
  finally:
    if qemuPid > 0:
      stopStartedProcess(qemuPid)
    if swtpmPid > 0:
      stopStartedProcess(swtpmPid)

  try:
    discard finalizeGoldenDir(buildDir)
  except VmHarnessError as e:
    raise goldenBuildFailure(buildDir, e.msg)
  discard writeGoldenManifest(GoldenManifestInputs(
    baseline: spec.baseline, buildDir: buildDir, diskGB: diskGB,
    windowsIso: spec.windowsIso, autounattendIso: spec.autounattendIso,
    recipeDir: spec.recipeDir))
  # The manifest is the completion marker, so the build only claims to have
  # produced a golden AFTER it has written one — and proves the result
  # passes the same admission check the consuming path applies, rather than
  # the weaker structural one finalizeGoldenDir uses internally.
  try:
    result = requireWindowsArmGolden(buildDir)
  except ValueError as e:
    raise goldenBuildFailure(buildDir,
      "the golden build did not produce a directory the consuming path " &
      "accepts: " & e.msg)

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
      requireWindowsArmGolden(source)
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
        requireWindowsArmGolden(baselineName)
      except ValueError as e:
        raise newVmHarnessError($b.id, lpRevert,
          "QemuWindowsArmBackend: " & e.msg)
  let name = ephemeralName(b.ephemeralPrefix, int64(epochTime() * 1000),
                           getCurrentProcessId())
  let vmDir = ephemeralDirFor(b.stateDir, name)
  b.createEphemeralInstance(baselineDir, vmDir)
  b.acquireInstanceLock(name, vmDir)
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
      stopStartedProcess(parseInt(pidText))
    if vm.name in b.qemuPids:
      b.qemuPids.del(vm.name)
    let swtpmPidText = vm.extra.getOrDefault("swtpmPid", "")
    if swtpmPidText.len > 0:
      stopStartedProcess(parseInt(swtpmPidText))
    if vm.name in b.swtpmPids:
      b.swtpmPids.del(vm.name)
    # Release the per-instance lock before removing the directory so the fd
    # and its lock file go away together.
    b.releaseInstanceLock(vm.name)
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
      qemuImgCmd = getEnv("VMH_QEMU_WINDOWS_ARM_QEMU_IMG_CMD", "qemu-img"),
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
