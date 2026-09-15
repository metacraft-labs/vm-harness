## Runner-Fleet-M3-ARM-Wave MA3 gate: ``t_qemu_windows_arm_golden_build``
## — UNIT TIER. Runs anywhere; needs no hypervisor, no Windows and no ISO.
##
## The host tier of the same gate (a real install -> sysprep -> golden run,
## and two clones with DISTINCT machine SIDs) lives in
## ``tests/e2e/t_qemu_windows_arm_golden_build_host.nim`` and is wired into
## ``scripts/run-host-tests.sh``. It SKIPS with an explicit message naming
## what it needs. This file must not be read as covering it.
##
## WHY THIS GATE EXISTS. The Windows-ARM golden the ``eph-win-arm64`` lane ran
## on was promoted by hand, existed in no build graph, had no backup and no
## manifest. It was lost between 2026-07-20 and 2026-08-24, taking the lane
## down with it, and nothing in this repository could rebuild it. The recipe
## is now the artifact, so the build path is the ONLY path — which makes the
## assertions below the difference between a lane that can be restored on
## demand and one that cannot.
##
## WHAT IS ASSERTED HERE, and why each is a regression of a real hazard:
##
##  1. The install boot attaches both ISOs over xHCI, orders the install media
##     ahead of the still-empty target disk, and omits ``-no-reboot``.
##  2. A build into a directory already holding a golden is REFUSED — qcow2
##     does not verify a backing file, so rebuilding in place corrupts every
##     live overlay with no error anywhere.
##  3. An overlay records the RESOLVED backing path, never the pointer
##     symlink, or the promotion flip corrupts the instances the versioned
##     scheme exists to protect.
##  4. The sentinel the harness polls for, and the sysprep answer file it
##     names, are the ones the CHECKED-IN recipe actually writes and stages.
##     Both are cross-repo-file assertions, so drift on either side fails.
##  5. Power-off is observed on the MONITOR socket, never over SSH — SSH dies
##     with the guest that ``sysprep /shutdown`` just powered off.
##  6. Every wait is bounded by the deadline it was given, and every failure
##     leaves the build directory, the guest serial log and QEMU's own log
##     behind, and SAYS WHERE THEY ARE. A Windows install that goes wrong has
##     no console and no SSH; those two files are the entire diagnostic
##     surface.
##  7. The finished golden carries a manifest identifying what it was built
##     from, and boots with NO reference to the install media.
##
## The suites "QemuWindowsArmBackend golden build" and "Golden build space
## precondition" were MOVED here intact from
## ``tests/unit/t_qemu_windows_arm_backend.nim`` so that a grep for the gate
## name lands on every assertion it owns. No test was dropped and no
## assertion weakened in the move.
##
## MOCKING NOTE (workspace policy: every mock must be justified). Three fakes
## appear below and each replaces something that cannot exist in a unit tier:
##   * a fake QEMU — this test binary re-executed with a flag, following the
##     existing ``PortListenerHelperEnv`` pattern in
##     ``t_qemu_windows_arm_backend.nim``. It binds the REAL forwarded port
##     and serves a REAL unix monitor socket, so the port-claim handshake and
##     the monitor conversation under test are genuine; only the guest is
##     absent.
##   * a fake ``swtpm`` — creates the real control socket the startup path
##     waits for.
##   * a fake ``sshpass`` — a shell script. The SSH ARGUMENT VECTOR, the
##     probe command and the sysprep command it receives are the real ones,
##     and the script asserts on them; only Windows is absent.
## Everything else is real: a real ``qemu-img`` allocates the real qcow2, the
## real recipe files are read off disk, and the real ``shasum`` computes the
## manifest digests.

import std/[json, net, os, osproc, posix, sequtils, strutils, tempfiles,
            times, unittest]
import vm_harness

const
  FakeQemuEnv = "VMH_GOLDEN_FAKE_QEMU"
  FakeSshLogEnv = "VMH_GOLDEN_FAKE_SSH_LOG"
  FakeSshDirEnv = "VMH_GOLDEN_FAKE_SSH_DIR"
  PowerOffFlagName = ".fake-poweroff"

proc argValue(flag: string): string =
  for i in 1 ..< paramCount():
    if paramStr(i) == flag:
      return paramStr(i + 1)
  ""

proc argStartingWith(prefix: string): string =
  for i in 1 .. paramCount():
    if paramStr(i).startsWith(prefix):
      return paramStr(i)
  ""

proc fakeQemuForwardedPort(): int =
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
  raise newException(ValueError, "fake QEMU received no SSH hostfwd")

proc maybeRunFakeQemu() =
  ## This binary, re-executed as ``qemu-system-aarch64``.
  ##
  ## It does the three things the orchestration genuinely interacts with: it
  ## writes the serial and QEMU logs at the paths the argv names (so "the
  ## failure path retains the logs" is asserted against the real argv, not a
  ## hard-coded guess), it binds the forwarded SSH port so the real
  ## port-claim handshake completes, and it serves a real unix monitor socket
  ## answering ``info status``. It reports the guest as powered off once a
  ## ``.fake-poweroff`` flag appears in its working directory — which is what
  ## the fake sshpass creates when it is handed the sysprep command.
  if getEnv(FakeQemuEnv) != "1":
    return
  let serialArg = argStartingWith("file:")
  if serialArg.len > 0:
    writeFile(serialArg["file:".len .. ^1],
              "fake guest serial console output\n")
  let qemuLog = argValue("-D")
  if qemuLog.len > 0:
    writeFile(qemuLog, "fake qemu log\n")

  var listener = newSocket()
  listener.bindAddr(Port(fakeQemuForwardedPort()), "127.0.0.1")
  listener.listen()

  let monitorArg = argStartingWith("unix:")
  if monitorArg.len == 0:
    # Never fail quietly: a fake that silently stops being a monitor makes
    # every power-off assertion below pass for the wrong reason.
    writeFile("fake-qemu-error", "no -monitor unix: argument in:\n" &
                                 commandLineParams().join("\n"))
    sleep(120_000)
    quit(QuitSuccess)
  let monitorPath = monitorArg["unix:".len ..< monitorArg.find(",server=on")]
  removeFile(monitorPath)
  var monitor = newSocket(net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                          net.Protocol.IPPROTO_IP)
  monitor.bindUnix(monitorPath)
  monitor.listen()
  while true:
    # Raw accept: std/net's own ``accept`` stringifies the peer address, and
    # an AF_UNIX peer has none, so it raises on a perfectly good connection.
    let fd = posix.accept(monitor.getFd(), nil, nil)
    if cint(fd) < 0:
      continue
    var client = newSocket(fd, net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                           net.Protocol.IPPROTO_IP)
    try:
      client.send("QEMU 9.2.0 monitor - type 'help' for more information\n" &
                  "(qemu) ")
      # Serve commands in a LOOP and never hang up first, because a real HMP
      # monitor does not. That is load-bearing rather than cosmetic: a reader
      # that asks ``recv`` for a fixed byte count is rescued by the peer
      # closing (EOF ends the wait and the short reply is returned), so a fake
      # that hung up after one reply would let the recv-fills-the-whole-buffer
      # trap straight back in unnoticed — and the first REAL host run would
      # sit through the whole 90-minute deadline reporting a running guest as
      # not-powered-off. Holding the connection open is what makes this test
      # able to tell the two readers apart.
      while true:
        var line = ""
        client.readLine(line, timeout = 30_000)
        if line.len == 0:
          break   # the client hung up; wait for the next connection
        let status =
          if fileExists(getCurrentDir() / PowerOffFlagName):
            "VM status: paused (shutdown)"
          else:
            "VM status: running"
        client.send(line & "\r\n" & status & "\r\n(qemu) ")
    except CatchableError:
      discard
    try: client.close()
    except CatchableError: discard

maybeRunFakeQemu()

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc socketExists(path: string): bool =
  ## ``os.fileExists`` is false for a unix socket (it is not a regular file),
  ## which is why the backend uses a stat-based check and why this one has to.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc recipeDir(): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "windows-arm-base"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc writeFakeSwtpm(path: string) =
  ## Creates the control socket ``startSwtpmInBackground`` waits for, then
  ## stays alive as the real one does.
  writeExecutable(path, """#!/bin/sh
for a in "$@"; do
  case "$a" in
    type=unixio,path=*) : > "${a#type=unixio,path=}" ;;
  esac
done
sleep 120
""")

proc writeFakeSshpass(path: string) =
  ## Answers the two remote commands the golden build issues. The command it
  ## matches on is the REAL one the backend built.
  writeExecutable(path, """#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
if [ -n "${VMH_GOLDEN_FAKE_SSH_LOG:-}" ]; then
  printf '%s\n' "$last" >> "$VMH_GOLDEN_FAKE_SSH_LOG"
fi
case "$last" in
  *repro-install-done*)
    if [ -f "$VMH_GOLDEN_FAKE_SSH_DIR/sentinel" ]; then
      echo "VMH-INSTALL-DONE"
      exit 0
    fi
    exit 1
    ;;
  *sysprep.exe*)
    : > "$VMH_GOLDEN_FAKE_SSH_DIR/sysprep-launched"
    printf '%s\n' "$last" > "$VMH_GOLDEN_FAKE_SSH_DIR/sysprep-command"
    if [ -n "${VMH_GOLDEN_FAKE_SSH_VMDIR:-}" ]; then
      : > "$VMH_GOLDEN_FAKE_SSH_VMDIR/.fake-poweroff"
    fi
    exit 0
    ;;
esac
exit 1
""")

proc goldenBackend(tmp: string; qemuCmd = ""): QemuWindowsArmBackend =
  let swtpm = tmp / "swtpm"
  let sshpass = tmp / "sshpass"
  writeFakeSwtpm(swtpm)
  writeFakeSshpass(sshpass)
  newQemuWindowsArmBackend(
    qemuCmd = (if qemuCmd.len > 0: qemuCmd else: getAppFilename()),
    swtpmCmd = swtpm,
    sshpassCmd = sshpass,
    stateDir = tmp / "state",
    sshPort = 0)

# ---------------------------------------------------------------------------
# Moved intact from tests/unit/t_qemu_windows_arm_backend.nim.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# New in MA3: the orchestration.
# ---------------------------------------------------------------------------

suite "Golden build: the harness agrees with the checked-in recipe":
  ## These are cross-file assertions on purpose. The sentinel and the sysprep
  ## answer file are a CONTRACT between Nim code and an XML answer file that
  ## nothing else links together; if either side is edited alone the build
  ## polls forever for a file that is never written, and a Windows install
  ## that never finishes is indistinguishable from one that is merely slow.

  test "the sentinel polled for is the one autounattend.xml writes":
    let xml = readFile(recipeDir() / "autounattend.xml")
    check QwaInstallSentinelPath in xml
    # ...and it is written by the FirstLogonCommands pass, not merely
    # mentioned in a comment.
    let firstLogon = xml.find("<FirstLogonCommands>")
    check firstLogon >= 0
    check xml.find(QwaInstallSentinelPath, firstLogon) > firstLogon
    # The recipe writes it only after sshd is confirmed running; that
    # condition is what makes the sentinel mean "install finished" rather
    # than "Windows booted".
    check "Get-Service -Name sshd" in xml

  test "the sysprep answer file named is the one the recipe stages on C:":
    let xml = readFile(recipeDir() / "autounattend.xml")
    check QwaSysprepAnswerGuestPath in xml
    check fileExists(recipeDir() / "repro-sysprep.xml")
    # The ISO-to-C: copy the FirstLogonCommands perform is what puts it
    # there; sysprep is invoked with /unattend: pointing at the destination.
    check ("copy /Y %i:\\repro-sysprep.xml " & QwaSysprepAnswerGuestPath) in xml

  test "sysprep carries every flag the golden depends on":
    let argv = buildSysprepCommand()
    check argv[0] == QwaSysprepExePath
    # /generalize is load-bearing: without it every ephemeral clone of this
    # golden shares one machine SID.
    check "/generalize" in argv
    check "/oobe" in argv
    check "/shutdown" in argv
    check ("/unattend:" & QwaSysprepAnswerGuestPath) in argv
    # /mode:vm is what the checked-in recipe README documents as the
    # invocation that produced a working golden, and is sound only because
    # every instance boots the identical machine shape this backend builds.
    check "/mode:vm" in argv
    check "/mode:vm" notin buildSysprepCommand(modeVm = false)
    # Dropping /generalize must not be reachable by flipping that knob.
    check "/generalize" in buildSysprepCommand(modeVm = false)

  test "sysprep is launched detached from the ssh channel that starts it":
    # /shutdown powers the guest off under the channel that issued it, and a
    # generalize runs 10-20 minutes. A channel-bound invocation is one
    # host-side timeout away from a half-generalized disk that still looks
    # like a golden.
    let remote = buildSysprepRemoteCommand()
    check "Start-Process" in remote
    for flag in ["/generalize", "/oobe", "/shutdown", "/mode:vm",
                 "/unattend:" & QwaSysprepAnswerGuestPath]:
      check flag in remote
    check QwaSysprepExePath in remote

  test "the install probe cannot be satisfied by an echo of itself":
    let probe = buildInstallSentinelProbe()
    check QwaInstallSentinelPath in probe
    check "Test-Path" in probe
    # The marker the probe PRINTS is deliberately not a substring of the
    # command, so an ssh wrapper that echoes its argument cannot look like a
    # finished install.
    check QwaInstallDoneMarker notin QwaInstallSentinelPath
    check probe.count(QwaInstallDoneMarker) == 1
    check "Write-Output" in probe

suite "Golden build: power-off is read off the monitor, not off SSH":

  test "the monitor path watched is the one the argv publishes":
    let tmp = createTempDir("vmh-qwa-monitor-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "")
    let expected = "unix:" & qwaMonitorSocketPath(tmp) & ",server=on,wait=off"
    for args in [buildQemuWindowsArmArgs(tmp, 2242),
                 buildQemuWindowsArmInstallArgs(tmp, tmp / "a.iso",
                                                tmp / "b.iso", 2243)]:
      check "-monitor" in args
      check args[args.find("-monitor") + 1] == expected

  test "an info status reply is read off the status line only":
    check not monitorTextSaysPoweredOff("")
    check not monitorTextSaysPoweredOff(
      "QEMU 9.2.0 monitor\n(qemu) info status\r\nVM status: running\r\n(qemu) ")
    check monitorTextSaysPoweredOff(
      "QEMU 9.2.0 monitor\n(qemu) info status\r\n" &
      "VM status: paused (shutdown)\r\n(qemu) ")
    # The word can appear in the echoed command or the banner while the guest
    # is plainly still running; only the status line decides.
    check not monitorTextSaysPoweredOff(
      "(qemu) system_powerdown -- shutdown requested\r\nVM status: running\r\n")
    check not monitorTextSaysPoweredOff("no status here at all")

  test "a live guest answering the monitor is not reported as powered off":
    let tmp = createTempDir("vmh-qwa-poweroff-live-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "vm")
    writeFile(tmp / "vm" / "windows.qcow2", "")
    putEnv(FakeQemuEnv, "1")
    defer: delEnv(FakeQemuEnv)
    let started = b.startQemuWithAllocatedPort(tmp / "vm", 1, 64)
    defer: discard execCmd("/bin/kill -9 " & $started.pid & " 2>/dev/null")
    let monitorPath = qwaMonitorSocketPath(tmp / "vm")
    let waitUntil = epochTime() + 10.0
    while epochTime() < waitUntil and not socketExists(monitorPath):
      sleep(50)
    if fileExists(tmp / "vm" / "fake-qemu-error"):
      echo readFile(tmp / "vm" / "fake-qemu-error")
    check socketExists(monitorPath)

    # The guest says "running"; the process is alive. Not powered off.
    check not guestPoweredOff(monitorPath, started.pid)
    # Now it says "paused (shutdown)" — while the QEMU process is STILL
    # ALIVE. The monitor has to be what decides, or this reads as running.
    writeFile(tmp / "vm" / ".fake-poweroff", "")
    check guestPoweredOff(monitorPath, started.pid)
    # And it was the MONITOR that said so: the QEMU process is still running
    # at this instant, so the "socket gone plus process gone" fallback arm
    # cannot be what answered. Without this the assertion above would also be
    # satisfied by QEMU having simply died.
    check not qemuProcessGone(started.pid)
    check waitForGuestPowerOff(monitorPath, started.pid,
                               epochTime() + 5.0, pollMs = 100)
    check not qemuProcessGone(started.pid)

  test "a QEMU that exited with no monitor counts as powered off":
    # QEMU's default action on a guest power-off is to exit, taking the
    # socket with it, so the absence of both is the same event.
    let done = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard done.waitForExit()
    let gonePid = done.processID
    done.close()
    check guestPoweredOff("/nonexistent-vmh-monitor.sock", gonePid)

    let alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      try: alive.terminate()
      except CatchableError: discard
      alive.close()
    check not guestPoweredOff("/nonexistent-vmh-monitor.sock",
                              alive.processID)

  test "the power-off wait is bounded by the deadline it was given":
    let alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      try: alive.terminate()
      except CatchableError: discard
      alive.close()
    let start = epochTime()
    # A poll interval far LONGER than the deadline: the wait must be bounded
    # by the deadline it was given, not by the deadline rounded up to the
    # next poll. On a 90-minute build budget that difference is what decides
    # whether an operator gets an answer or watches a hung process.
    check not waitForGuestPowerOff("/nonexistent-vmh-monitor.sock",
                                   alive.processID,
                                   epochTime() + 1.0, pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 6.0

suite "Golden build: the install wait":

  test "the sentinel wait needs the marker, not merely a zero exit":
    let tmp = createTempDir("vmh-qwa-sentinel-", "")
    defer: removeDir(tmp)
    let silent = tmp / "sshpass-silent"
    writeExecutable(silent, "#!/bin/sh\nexit 0\n")
    let b = newQemuWindowsArmBackend(sshpassCmd = silent,
                                     stateDir = tmp / "state")
    # An SSH transport that succeeds without running anything must not read
    # as a finished install.
    check not b.installSentinelPresent(2244)

  test "the sentinel wait returns as soon as the install declares itself":
    let tmp = createTempDir("vmh-qwa-sentinel-ok-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    check not b.installSentinelPresent(2245)
    writeFile(tmp / "ssh" / "sentinel", "")
    check b.installSentinelPresent(2245)
    check b.waitForInstallSentinel(2245, epochTime() + 5.0, pollMs = 100)

  test "the sentinel wait is bounded, and probes more than once":
    let tmp = createTempDir("vmh-qwa-sentinel-deadline-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeSshLogEnv, tmp / "ssh.log")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeSshLogEnv)
    let start = epochTime()
    # Again with a poll interval longer than the deadline: an install wait
    # that overshoots by a poll is an install wait whose bound is a fiction.
    check not b.waitForInstallSentinel(2246, epochTime() + 1.0,
                                       pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 15.0
    let probes = readFile(tmp / "ssh.log").strip().splitLines()
    check probes.len >= 2
    for p in probes:
      check QwaInstallSentinelPath in p

suite "Golden build: finalize drops the install media":

  test "a finished directory validates and boots with no install media":
    let tmp = createTempDir("vmh-qwa-finalize-", "")
    defer: removeDir(tmp)
    let golden = tmp / "win-arm-runner-0100"
    createDir(golden)
    writeFile(golden / "windows.qcow2", "golden")
    writeFile(golden / "QEMU_EFI.fd", "")
    writeFile(golden / "QEMU_VARS.fd", "")
    # Build leftovers that must not be adopted as part of the artifact.
    writeFile(golden / QwaOverlayDiskName, "leftover overlay")
    writeFile(golden / QwaInstanceLockName, "")
    createDir(golden / "tpm")
    writeFile(golden / "tpm" / ".lock", "")

    let resolved = finalizeGoldenDir(golden)
    check resolved == absolutePath(golden)
    check not fileExists(golden / QwaOverlayDiskName)
    check not fileExists(golden / QwaInstanceLockName)
    check not fileExists(golden / "tpm" / ".lock")
    check validateWindowsArmVmDir(golden) == absolutePath(golden)

    # The ISOs are build INPUTS. Nothing in the consuming boot may reference
    # them, because on the host that consumes the golden they are not there.
    let boot = buildQemuWindowsArmArgs(golden, 2247)
    check not boot.anyIt("media=cdrom" in it)
    check not boot.anyIt("usb-storage" in it)
    check "id=disk0,file=" & golden / "windows.qcow2" &
          ",format=qcow2,if=none,cache=writeback,discard=unmap" in boot

  test "a build that produced no disk is refused, not promoted":
    let tmp = createTempDir("vmh-qwa-finalize-bad-", "")
    defer: removeDir(tmp)
    let empty = tmp / "win-arm-runner-0101"
    createDir(empty)
    var raised = false
    try:
      discard finalizeGoldenDir(empty)
    except VmHarnessError as e:
      raised = true
      check "windows.qcow2" in e.msg
    check raised

suite "Golden build: the manifest":
  ## The artifact that was lost had no way to say what it was built from.

  test "the recorded vm-harness version tracks the package version":
    let nimble = readFile(repoRoot() / "vm_harness.nimble")
    check ("version       = \"" & QwaVmHarnessVersion & "\"") in nimble

  test "a digest is a real SHA-256 of the file's CONTENT":
    let tmp = createTempDir("vmh-qwa-sha-", "")
    defer: removeDir(tmp)
    let empty = tmp / "empty"
    writeFile(empty, "")
    check fileSha256(empty) ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let abc = tmp / "abc"
    writeFile(abc, "abc")
    check fileSha256(abc) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "the manifest identifies the ISO, the recipe and the answer files":
    let tmp = createTempDir("vmh-qwa-manifest-", "")
    defer: removeDir(tmp)
    let golden = tmp / "win-arm-runner-0102"
    createDir(golden)
    let winIso = tmp / "win11-arm64.iso"
    let unattendIso = tmp / "autounattend.iso"
    writeFile(winIso, "pretend windows iso")
    writeFile(unattendIso, "pretend answer iso")

    let path = writeGoldenManifest(GoldenManifestInputs(
      baseline: "win-arm-runner", buildDir: golden, diskGB: 64,
      windowsIso: winIso, autounattendIso: unattendIso,
      recipeDir: recipeDir(), builtAt: "2026-09-15T00:00:00Z"))
    check path == golden / QwaGoldenManifestName
    let m = parseJson(readFile(path))

    check m["schema"].getStr == QwaGoldenManifestSchema
    check m["baseline"].getStr == "win-arm-runner"
    check m["builtAt"].getStr == "2026-09-15T00:00:00Z"
    check m["vmHarnessVersion"].getStr == QwaVmHarnessVersion
    check m["diskGB"].getInt == 64

    # The ISO is pinned by CONTENT, not by the path it happened to sit at.
    check m["windowsIso"]["sha256"].getStr == fileSha256(winIso)
    check m["autounattendIso"]["sha256"].getStr == fileSha256(unattendIso)
    check m["windowsIso"]["sha256"].getStr !=
          m["autounattendIso"]["sha256"].getStr

    # Every checked-in answer file the recipe contributes is digested.
    for name in QwaRecipeAnswerFiles:
      check m["answerFiles"].hasKey(name)
      check m["answerFiles"][name].getStr ==
        fileSha256(recipeDir() / name)
      check m["answerFiles"][name].getStr.len == 64

    # The recipe commit, when the recipe lives in a git checkout.
    let commit = m["recipe"]["commit"].getStr
    if dirExists(repoRoot() / ".git"):
      check commit.len == 40
      check commit.allIt(it in {'0' .. '9', 'a' .. 'f'})
    check m["recipe"]["dir"].getStr == recipeDir()

  test "a different ISO produces a different manifest":
    let tmp = createTempDir("vmh-qwa-manifest-diff-", "")
    defer: removeDir(tmp)
    createDir(tmp / "a")
    createDir(tmp / "b")
    writeFile(tmp / "iso-a", "iso a")
    writeFile(tmp / "iso-b", "iso b")
    writeFile(tmp / "unattend", "u")
    proc digestOf(iso, dir: string): string =
      discard writeGoldenManifest(GoldenManifestInputs(
        baseline: "win-arm-runner", buildDir: dir, diskGB: 64,
        windowsIso: iso, autounattendIso: tmp / "unattend",
        recipeDir: recipeDir(), builtAt: "2026-09-15T00:00:00Z"))
      parseJson(readFile(dir / QwaGoldenManifestName))["windowsIso"]["sha256"]
        .getStr
    check digestOf(tmp / "iso-a", tmp / "a") !=
          digestOf(tmp / "iso-b", tmp / "b")

  test "a machine SID is the account SID without its RID":
    # What the host tier compares across two clones. A golden that skipped
    # /generalize gives both clones the same value.
    check machineSidFromUserSid("S-1-5-21-1004336348-1177238915-682003330-500") ==
      "S-1-5-21-1004336348-1177238915-682003330"
    check machineSidFromUserSid(
      "  S-1-5-21-1004336348-1177238915-682003330-1001  ") ==
      "S-1-5-21-1004336348-1177238915-682003330"
    check machineSidFromUserSid("not-a-sid") == ""
    check machineSidFromUserSid("") == ""
    check machineSidFromUserSid("S-1-5") == ""

suite "Golden build: the whole run":

  setup:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeSshLogEnv)
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    # Keep the space precondition out of the way: it has its own suite, and
    # a busy CI host must not turn these into false failures.
    putEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB", "0")

  teardown:
    delEnv("VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB")
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeSshLogEnv)
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    delEnv("VMH_QEMU_EFI_CODE_TEMPLATE")
    delEnv("VMH_QEMU_EFI_VARS_TEMPLATE")
    delEnv("VMH_QEMU_FIRMWARE_DIR")

  test "a missing Windows ISO is refused before anything is allocated":
    let tmp = createTempDir("vmh-qwa-run-noiso-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "golden", windowsIso = tmp / "absent.iso",
        autounattendIso = tmp / "absent-unattend.iso"))
    except VmHarnessError as e:
      raised = true
      check "absent.iso" in e.msg
      check "operator-supplied" in e.msg
    check raised
    check not dirExists(tmp / "golden")

  test "a missing answer-file ISO names the script that builds it":
    let tmp = createTempDir("vmh-qwa-run-nounattend-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "golden", windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "absent-unattend.iso"))
    except VmHarnessError as e:
      raised = true
      check "build-autounattend-iso.sh" in e.msg
    check raised

  test "a build into a directory already holding a golden is refused":
    let tmp = createTempDir("vmh-qwa-run-inplace-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    let live = tmp / "win-arm-runner-live"
    createDir(live)
    writeFile(live / "windows.qcow2", "backs a live overlay")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = live, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1))
    except VmHarnessError as e:
      raised = true
      check "refusing to build a golden into" in e.msg
    check raised
    check readFile(live / "windows.qcow2") == "backs a live overlay"

  test "a failed install leaves the build directory and both logs behind":
    # A Windows install that goes wrong has no console and no SSH. If the
    # failure path tidies up, the run is undiagnosable and the next attempt
    # is a blind 60-minute retry.
    let tmp = createTempDir("vmh-qwa-run-failstart-", "")
    defer: removeDir(tmp)
    let deadQemu = tmp / "dead-qemu"
    writeExecutable(deadQemu, """#!/bin/sh
: > serial.log
: > qemu.log
exit 1
""")
    let b = goldenBackend(tmp, qemuCmd = deadQemu)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    let golden = tmp / "win-arm-runner-0200"
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1,
        deadlineSec = 20))
    except VmHarnessError as e:
      raised = true
      check (golden / "serial.log") in e.msg
      check (golden / "qemu.log") in e.msg
      check "left in place" in e.msg
      check "NEW versioned directory" in e.msg
    check raised
    check dirExists(golden)
    check fileExists(golden / "serial.log")
    check fileExists(golden / "qemu.log")
    # The disk really was allocated, so the guard above is the thing that
    # stops the directory being reused rather than an accident of emptiness.
    check fileExists(golden / QwaBaseDiskName)

  test "a missing UEFI firmware template fails with the fix in the message":
    # Without firmware QEMU boots nothing at all, and an install that never
    # starts looks exactly like one that is merely slow.
    let tmp = createTempDir("vmh-qwa-run-nofw-", "")
    let savedCode = getEnv("VMH_QEMU_EFI_CODE")
    createDir(tmp / "empty")
    putEnv("VMH_QEMU_FIRMWARE_DIR", tmp / "empty")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "absent.fd")
    delEnv("VMH_QEMU_EFI_CODE")
    defer:
      removeDir(tmp)
      delEnv("VMH_QEMU_FIRMWARE_DIR")
      if savedCode.len > 0: putEnv("VMH_QEMU_EFI_CODE", savedCode)
    var raised = false
    try:
      stageGoldenFirmware(tmp)
    except VmHarnessError as e:
      raised = true
      check "VMH_QEMU_EFI_CODE_TEMPLATE" in e.msg
      check "edk2-aarch64-code.fd" in e.msg
    check raised

  test "an explicit firmware directory is used instead of the search list":
    let tmp = createTempDir("vmh-qwa-run-fw-", "")
    let savedCode = getEnv("VMH_QEMU_EFI_CODE")
    let savedVars = getEnv("VMH_QEMU_EFI_VARS")
    createDir(tmp / "fw")
    writeFile(tmp / "fw" / "edk2-aarch64-code.fd", "code")
    writeFile(tmp / "fw" / "edk2-arm-vars.fd", "vars")
    createDir(tmp / "build")
    putEnv("VMH_QEMU_FIRMWARE_DIR", tmp / "fw")
    delEnv("VMH_QEMU_EFI_CODE")
    delEnv("VMH_QEMU_EFI_VARS")
    defer:
      removeDir(tmp)
      delEnv("VMH_QEMU_FIRMWARE_DIR")
      if savedCode.len > 0: putEnv("VMH_QEMU_EFI_CODE", savedCode)
      if savedVars.len > 0: putEnv("VMH_QEMU_EFI_VARS", savedVars)
    stageGoldenFirmware(tmp / "build")
    # A per-build, writable vars file: Windows Setup writes its boot entry
    # into it, and a shared one would be written by every guest at once.
    check readFile(tmp / "build" / "QEMU_EFI.fd") == "code"
    check readFile(tmp / "build" / "QEMU_VARS.fd") == "vars"
    check fpUserWrite in getFilePermissions(tmp / "build" / "QEMU_VARS.fd")
    # And the staged pair is what the boot argv resolves.
    let args = buildQemuWindowsArmArgs(tmp / "build", 2248)
    check args.anyIt("if=pflash" in it and
                     (tmp / "build" / "QEMU_VARS.fd") in it)

  test "install, sysprep and power-off drive through to a validated golden":
    ## The orchestration end to end, with no Windows and no hypervisor: a
    ## real qemu-img allocates the real disk, the real argument vector is
    ## handed to a fake QEMU that binds the real forwarded port and serves a
    ## real monitor socket, the real probe and sysprep commands go to a fake
    ## sshpass, and power-off is observed on the monitor while the QEMU
    ## process is still alive — so the assertion cannot pass by accident of
    ## the process having died.
    let tmp = createTempDir("vmh-qwa-run-ok-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "pretend windows iso")
    writeFile(tmp / "unattend.iso", "pretend answer iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sentinel", "")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")

    let golden = tmp / "win-arm-runner-0300"
    putEnv("VMH_GOLDEN_FAKE_SSH_VMDIR", golden)

    let produced = b.buildWindowsArmGolden(newGoldenBuildSpec(
      buildDir = golden, windowsIso = tmp / "win.iso",
      autounattendIso = tmp / "unattend.iso", recipeDir = recipeDir(),
      diskGB = 1, cpus = 1, memoryMB = 64, deadlineSec = 60))

    check produced == absolutePath(golden)
    # The consuming path accepts it...
    check validateWindowsArmVmDir(produced) == absolutePath(golden)
    # ...sysprep really was issued, with the real command...
    check fileExists(tmp / "ssh" / "sysprep-launched")
    let issued = readFile(tmp / "ssh" / "sysprep-command")
    check "Start-Process" in issued
    check "/generalize" in issued
    check ("/unattend:" & QwaSysprepAnswerGuestPath) in issued
    # ...the diagnostics are there even on the success path...
    check fileExists(golden / "serial.log")
    check fileExists(golden / "qemu.log")
    # ...and the golden says what it was built from.
    let m = parseJson(readFile(golden / QwaGoldenManifestName))
    check m["schema"].getStr == QwaGoldenManifestSchema
    check m["windowsIso"]["sha256"].getStr == fileSha256(tmp / "win.iso")
    check m["answerFiles"]["autounattend.xml"].getStr ==
      fileSha256(recipeDir() / "autounattend.xml")
    check m["builtAt"].getStr.len >= 20
    check m["diskGB"].getInt == 1
    # A second build into the same directory is refused, which is what makes
    # a rebuild an addition rather than an overwrite.
    expect VmHarnessError:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1))
