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
  MonitorLogName = ".fake-monitor-commands"

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
      #
      # Two more fidelity properties, both learned the hard way when the
      # orchestration gained a SECOND monitor client (the keypress that
      # answers cdboot.efi, one connection per key, before the power-off
      # watch ever opens its own):
      #
      #  * The IDLE timeout below is short. A real HMP monitor serves ONE
      #    client at a time and notices a hangup at once. A fake that sat in
      #    a 30-second read after its first client hung up would leave every
      #    later connection accepted by the kernel and answered by nobody.
      #  * This fake WEDGES inside ``send`` if a client closes with a reply
      #    still in flight — measured: it stops accepting entirely. A real
      #    QEMU drops such a client instead. That is why
      #    ``sendQemuMonitorCommand`` drains before hanging up.
      #
      # Either one produces the same misleading symptom: a guest that HAS
      # powered off reading as "still running" until the deadline, which is
      # indistinguishable in the log from the real recv bug this fake exists
      # to catch. The end-to-end test's assertion that ``info status`` still
      # gets through AFTER the keypress phase is what pins both.
      while true:
        var line = ""
        client.readLine(line, timeout = 500)
        if line.len == 0:
          break   # the client hung up; wait for the next connection
        # Record every command so a test can assert what the orchestration
        # actually said to the monitor — the keypress that answers
        # cdboot.efi's prompt is only observable here.
        let log = open(getCurrentDir() / MonitorLogName, fmAppend)
        log.writeLine(line)
        log.close()
        # `screendump <path>` writes the framebuffer, as the real monitor
        # does. Without this the failure path's framebuffer capture would
        # have nothing to assert on — and the capture exists precisely
        # because a Windows guest is mute on the serial port.
        if line.strip().startsWith("screendump "):
          try:
            writeFile(line.strip()[len("screendump ") .. ^1],
                      "P6\n1 1\n255\n\0\0\0")
          except CatchableError:
            discard
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
  *VMH-SYSPREP-RUNNING*)
    # The "is sysprep still alive?" probe. Gated on a file so a test can say
    # which answer it wants -- the whole point of the check is that a launch
    # reporting success and a sysprep actually running are different facts.
    if [ -f "$VMH_GOLDEN_FAKE_SSH_DIR/sysprep-running" ]; then
      echo "VMH-SYSPREP-RUNNING"
      exit 0
    fi
    exit 1
    ;;
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

    # A KEYBOARD. MEASURED on m3 2026-09-15: without one the install cannot
    # start. \EFI\BOOT\BOOTAA64.EFI on a Windows install ISO is cdboot.efi,
    # which waits for a keypress and returns EFI_TIMEOUT when none arrives;
    # the firmware then logs `failed to start Boot0001 ...: Time out` and
    # drops to the EFI shell, and the build sits out its whole deadline
    # having installed nothing. -display none plus an output-only
    # `-serial file:` leaves the machine with no input device at all, so the
    # keyboard has to be added here and the key injected on the monitor.
    check "usb-kbd,bus=usb.0" in args
    # It has to hang off the controller the install boot creates, and after
    # it: a keyboard on no bus is a QEMU startup failure, not a warning.
    check args.find("qemu-xhci,id=usb") < args.find("usb-kbd,bus=usb.0")
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
    # And no keyboard, and no xHCI to hang one off. This argument vector is
    # already DEPLOYED on m3; the install boot's keypress workaround must not
    # leak into the per-job shape that every CI job boots.
    check not args.anyIt("usb-kbd" in it)
    check not args.anyIt("qemu-xhci" in it)

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

  test "the recipe opens sshd on EVERY firewall profile, and asserts it":
    # MEASURED on m3 2026-09-15, and it cost a whole build deadline against a
    # perfectly provisioned guest. `Add-WindowsCapability OpenSSH.Server`
    # installs an inbound allow for TCP 22 scoped to the PRIVATE profile
    # only. QEMU's user-mode network is unidentified, so Windows classifies
    # it PUBLIC, whose policy is BlockInbound. Everything inside the guest
    # reads healthy — sshd Running, 0.0.0.0:22 LISTENING, NIC up on
    # 10.0.2.15 — and every forwarded SYN is dropped before it reaches sshd.
    #
    # The old recipe created a rule only when NONE existed, so the
    # capability's Private-only rule made it a no-op on exactly this path.
    # Nothing host-side can observe any of this: the harness's only view of
    # the guest is the SSH that is blocked. So it is asserted on the recipe.
    let ps1 = readFile(recipeDir() / "provision-openssh.ps1")
    check "-Profile Any" in ps1
    check "New-NetFirewallRule" in ps1
    # It must not be conditional on there being no rule already — that is
    # the defect.
    check "if (-not (Get-NetFirewallRule" notin ps1
    # And it must FAIL provisioning when the rule is not what it asked for:
    # a golden whose sshd is firewalled off is indistinguishable from one
    # that never finished installing.
    check "is not an Any-profile allow" in ps1

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

  test "sysprep outlives the ssh session that starts it":
    # /shutdown powers the guest off under the session that issued it, and a
    # generalize runs 10-20 minutes. A session-bound invocation is one hangup
    # away from a half-generalized disk that still looks like a golden.
    #
    # `Start-Process` is NOT session-independent, which is the assumption
    # this code shipped on until MA4's host run disproved it. Windows OpenSSH
    # puts every process of a session into a job object and kills the job
    # when the session ends; a Start-Process child stays in that job.
    # MEASURED on m3 2026-09-15 with a harmless long-running process:
    # Start-Process -> 0 survivors two seconds after the session closed,
    # Win32_Process.Create -> still running 25 seconds later, because the WMI
    # provider host creates it and it is therefore in no session job at all.
    let remote = buildSysprepRemoteCommand()
    check "Win32_Process" in remote
    check "Invoke-CimMethod" in remote
    check "-MethodName Create" in remote
    # And NOT the thing that was measured not to work.
    check "Start-Process" notin remote
    # A refused creation has to exit non-zero: a sysprep that never started
    # must be reported, not waited for.
    check ".ReturnValue -ne 0" in remote
    check "exit 1" in remote

    for flag in ["/generalize", "/oobe", "/shutdown", "/mode:vm",
                 "/unattend:" & QwaSysprepAnswerGuestPath]:
      check flag in remote
    check QwaSysprepExePath in remote

  test "no remote command carries a bare $, which the guest would eat":
    # provision-openssh.ps1 sets sshd's DefaultShell to powershell.exe, so an
    # OUTER PowerShell parses what arrives over SSH before the inner
    # `powershell.exe -Command "..."` string exists — and that outer parse
    # expands $ inside double quotes. MEASURED on m3 2026-09-15: a sysprep
    # launch that stashed its result in $r arrived in the guest as
    # `rc=' + .ReturnValue`, a parse error, and the build died at the very
    # last step of a 20-minute install. Nothing about the fake sshpass can
    # catch that, so the constraint is asserted on the strings themselves.
    for pair in {
        "buildSysprepRemoteCommand": buildSysprepRemoteCommand(),
        "buildSysprepRemoteCommand(modeVm = false)":
          buildSysprepRemoteCommand(modeVm = false),
        "buildSysprepRunningProbe": buildSysprepRunningProbe(),
        "buildInstallSentinelProbe": buildInstallSentinelProbe()}:
      checkpoint(pair[0] & ": " & pair[1])
      check '$' notin pair[1]

  test "the sysprep liveness probe cannot be satisfied by an echo of itself":
    let probe = buildSysprepRunningProbe()
    check "Get-Process sysprep" in probe
    # The marker printed differs from anything in the probe's own subject, so
    # an ssh wrapper that echoes its argument cannot look like a live sysprep
    # — the same trap QwaInstallDoneMarker exists to avoid.
    check QwaSysprepRunningMarker notin "Get-Process sysprep"
    check QwaSysprepRunningMarker == "VMH-SYSPREP-RUNNING"

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

suite "Golden build: sysprep has to still be there a moment later":
  ## MA4's second host run: the launch reported success, sysprep logged four
  ## lines, reached "Beginning action execution from Cleanup.xml" and died
  ## one second in, killed with the SSH session's job object. The build then
  ## waited 20 minutes for a power-off from a process that no longer existed,
  ## with a perfectly installed guest sitting at its desktop.

  test "a live sysprep is seen, and the wait returns at once":
    let tmp = createTempDir("vmh-qwa-sysprep-live-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sysprep-running", "")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    check b.sysprepRunning(2250)
    let start = epochTime()
    check b.sysprepTookHold(2250, "/nonexistent-vmh-monitor.sock",
                            alive.processID, epochTime() + 60.0,
                            windowSec = 60, pollMs = 5_000)
    check epochTime() - start < 10.0

  test "a guest that already powered off counts as having taken hold":
    # A generalize normally runs for minutes, but the build must not fail
    # because sysprep beat the first poll to the finish line.
    let tmp = createTempDir("vmh-qwa-sysprep-off-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")            # deliberately NOT reporting running
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var gone = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard gone.waitForExit()
    let pid = gone.processID
    gone.close()
    check not b.sysprepRunning(2251)
    check b.sysprepTookHold(2251, "/nonexistent-vmh-monitor.sock", pid,
                            epochTime() + 60.0, windowSec = 60,
                            pollMs = 5_000)

  test "a sysprep that died with its ssh session is caught, and bounded":
    let tmp = createTempDir("vmh-qwa-sysprep-dead-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    # Neither running nor powered off, and the window — not the build's whole
    # deadline — is what bounds the answer.
    check not b.sysprepTookHold(2252, "/nonexistent-vmh-monitor.sock",
                                alive.processID, epochTime() + 600.0,
                                windowSec = 1, pollMs = 30_000)
    let elapsed = epochTime() - start
    check elapsed >= 0.9
    check elapsed < 20.0

  test "the take-hold wait is bounded by the build deadline too":
    let tmp = createTempDir("vmh-qwa-sysprep-deadline-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    defer: delEnv(FakeSshDirEnv)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    check not b.sysprepTookHold(2253, "/nonexistent-vmh-monitor.sock",
                                alive.processID, epochTime() - 1.0,
                                windowSec = 600, pollMs = 100)
    check epochTime() - start < 20.0

suite "Golden build: the install media keypress prompt":
  ## The defect MA4's first host run found, and the reason the fix has to
  ## stop as well as start. cdboot.efi will not hand over to Windows Setup
  ## until a key is pressed; the same prompt timing out on LATER boots is
  ## what makes Setup's own reboots fall past the still-first install media
  ## and onto the disk it is installing to. A keyer that never stopped would
  ## trade "the install never starts" for "the install restarts forever".

  test "the keypress window's default is the shipped one":
    # The e2e test below shortens it to keep the suite fast, so the default
    # has to be pinned somewhere that a shortened test cannot satisfy.
    let spec = newGoldenBuildSpec(buildDir = "/nonexistent",
                                  windowsIso = "/nonexistent",
                                  autounattendIso = "/nonexistent")
    check spec.keyPressWindowSec == QwaInstallKeyPressWindowSec
    check QwaInstallKeyPressWindowSec >= 60
    check QwaInstallMediaKey == "ret"

  test "a monitor command on an absent socket fails rather than raising":
    check not sendQemuMonitorCommand("/nonexistent-vmh-monitor.sock",
                                     "sendkey ret")

  test "keying STOPS once the guest starts writing to the target disk":
    # The load-bearing half. Setup's first reboot happens while the install
    # media is still ahead of the disk in BootOrder, so a key delivered then
    # restarts Setup from the ISO.
    let tmp = createTempDir("vmh-qwa-key-progress-", "")
    defer: removeDir(tmp)
    let disk = tmp / "windows.qcow2"
    writeFile(disk, newString(int(QwaInstallProgressBytes) + 1))
    check goldenDiskProgressed(disk)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    let sent = answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", disk, alive.processID,
      epochTime() + 30.0, windowSec = 30, intervalMs = 100)
    check sent == 0
    check epochTime() - start < 2.0

  test "keying is bounded by its own window when nothing ever happens":
    let tmp = createTempDir("vmh-qwa-key-window-", "")
    defer: removeDir(tmp)
    let disk = tmp / "windows.qcow2"
    writeFile(disk, "tiny")
    check not goldenDiskProgressed(disk)
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    discard answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", disk, alive.processID,
      epochTime() + 30.0, windowSec = 1, intervalMs = 30_000)
    let elapsed = epochTime() - start
    # Bounded by windowSec, and not rounded up to the next poll interval —
    # this window sits inside the overall build deadline and must not eat it.
    check elapsed >= 0.9
    check elapsed < 6.0

  test "keying is bounded by the overall build deadline too":
    let tmp = createTempDir("vmh-qwa-key-deadline-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    var alive = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                             options = {poUsePath})
    defer:
      alive.terminate()
      discard alive.waitForExit()
      alive.close()
    let start = epochTime()
    discard answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", alive.processID,
      epochTime() - 1.0, windowSec = 600, intervalMs = 100)
    check epochTime() - start < 2.0

  test "keying stops when the install boot has already died":
    let tmp = createTempDir("vmh-qwa-key-dead-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    var dead = startProcess("/bin/sh", args = @["-c", "exit 0"],
                            options = {poUsePath})
    discard dead.waitForExit()
    let pid = dead.processID
    dead.close()
    let start = epochTime()
    check answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", pid,
      epochTime() + 30.0, windowSec = 30, intervalMs = 100) == 0
    check epochTime() - start < 2.0

  test "a zero window presses nothing at all":
    let tmp = createTempDir("vmh-qwa-key-off-", "")
    defer: removeDir(tmp)
    writeFile(tmp / "windows.qcow2", "tiny")
    check answerInstallMediaKeyPrompt(
      tmp / "monitor.sock", tmp / "windows.qcow2", 0,
      epochTime() + 30.0, windowSec = 0) == 0

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

  test "an answer-file ISO older than the recipe it carries is refused":
    # FOUND on m3 2026-09-15, before the first host run, and it would have
    # poisoned every manifest produced from it:
    # guest-recipes/windows-arm-base/build/autounattend.iso was 7.6 MiB from
    # 2026-07-06 while the recipe files were from 2026-09-08 — it predated
    # the Git-for-Windows, PowerShell-7 and credential-expiry changes. The
    # manifest digests the RECIPE FILES; the guest installs what is on the
    # ISO. Nothing regenerates the ISO when a recipe file changes, because
    # build/ is a gitignored artifact built by hand, so the two drift in
    # silence and the golden claims provenance it does not have.
    let tmp = createTempDir("vmh-qwa-stale-iso-", "")
    defer: removeDir(tmp)
    let recipe = tmp / "recipe"
    createDir(recipe)
    let iso = tmp / "autounattend.iso"
    writeFile(iso, "an ISO built in July")
    for name in QwaRecipeAnswerFiles:
      writeFile(recipe / name, "edited in September")
    let isoTime = fromUnix(1_700_000_000)
    setLastModificationTime(iso, isoTime)
    for name in QwaRecipeAnswerFiles:
      setLastModificationTime(recipe / name, isoTime + initDuration(days = 60))

    check staleAnswerIsoRecipeFiles(iso, recipe).len == QwaRecipeAnswerFiles.len

    # And the build refuses BEFORE spending an hour on it.
    let b = newQemuWindowsArmBackend(qemuCmd = "/nonexistent-qemu",
                                     stateDir = tmp / "state")
    writeFile(tmp / "win.iso", "pretend windows iso")
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = tmp / "build", windowsIso = tmp / "win.iso",
        autounattendIso = iso, recipeDir = recipe, diskGB = 1))
    except VmHarnessError as e:
      raised = true
      check "OLDER than the recipe files" in e.msg
      check "build-autounattend-iso.sh" in e.msg
    check raised
    # It refused, so it must not have started a build directory either.
    check not dirExists(tmp / "build")

    # Rebuilt after the edits, it is accepted.
    setLastModificationTime(iso, isoTime + initDuration(days = 90))
    check staleAnswerIsoRecipeFiles(iso, recipe).len == 0

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

suite "Golden build: only a FINISHED golden is admissible":
  ## MEASURED on m3 2026-09-15, and the reason this suite exists: after MA4's
  ## five host runs, SIX directories sat under
  ## /private/var/lib/vm-harness/qemu-windows-arm/golden/ — 12-15 GB each,
  ## every one of them holding a windows.qcow2 and none of them holding a
  ## manifest, because the golden build creates the disk EMPTY as its first
  ## act and writes the manifest as its LAST. The structural check accepted
  ## all six as baselines to boot CI jobs from.
  ##
  ## MA3's contract deliberately RETAINS failed builds for diagnosis, so the
  ## directories are not the bug; admitting them is. This campaign exists
  ## because a golden could not be identified, and its rule is that an
  ## artifact must be identifiable AS one.

  test "a retained failed build is NOT admissible as a golden":
    let tmp = createTempDir("vmh-qwa-admit-failed-", "")
    defer: removeDir(tmp)
    # Exactly the shape of win-arm-runner-20260915T102158Z on m3: a large,
    # entirely plausible disk from an install that got part-way and stopped.
    writeFile(tmp / QwaBaseDiskName, "a 15 GB half-installed Windows")
    writeFile(tmp / "serial.log", "")
    writeFile(tmp / "qemu.log", "")
    createDir(tmp / "tpm")

    # The structural check still accepts it — it only ever asked whether
    # there is a disk, and that is all the overlay path needs to know.
    check validateWindowsArmVmDir(tmp) == absolutePath(tmp)

    # The admission check does not, and says why.
    var raised = false
    try:
      discard requireWindowsArmGolden(tmp)
    except ValueError as e:
      raised = true
      check QwaGoldenManifestName in e.msg
      check "NOT a finished golden" in e.msg
      check "failed" in e.msg
    check raised

  test "the consuming path refuses one too, rather than booting jobs off it":
    let tmp = createTempDir("vmh-qwa-admit-provision-", "")
    defer: removeDir(tmp)
    let failedBuild = tmp / "win-arm-runner-20260915T102158Z"
    createDir(failedBuild)
    writeFile(failedBuild / QwaBaseDiskName, "half an install")

    let b = newQemuWindowsArmBackend(qemuCmd = "/nonexistent-qemu",
                                     stateDir = tmp / "state")
    var raised = false
    try:
      b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                       sourceImage: failedBuild))
    except VmHarnessError as e:
      raised = true
      check QwaGoldenManifestName in e.msg
    check raised

  test "a finished golden is admissible":
    let tmp = createTempDir("vmh-qwa-admit-ok-", "")
    defer: removeDir(tmp)
    writeFile(tmp / QwaBaseDiskName, "golden")
    writeFile(tmp / QwaGoldenManifestName, "{}")
    check requireWindowsArmGolden(tmp) == absolutePath(tmp)

  test "an absent or diskless directory is refused before the manifest":
    let tmp = createTempDir("vmh-qwa-admit-empty-", "")
    defer: removeDir(tmp)
    expect ValueError:
      discard requireWindowsArmGolden(tmp / "nope")
    expect ValueError:
      discard requireWindowsArmGolden(tmp)
    # A manifest with no disk is not a golden either.
    writeFile(tmp / QwaGoldenManifestName, "{}")
    expect ValueError:
      discard requireWindowsArmGolden(tmp)

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

  test "an install that never finishes captures the guest's screen":
    ## MA4's first host run: Windows had installed, provisioned, written the
    ## sentinel and was sitting at its desktop, and the harness could not
    ## reach it. The serial log ended at the firmware handover and said
    ## nothing, because a Windows guest never writes to the serial port. The
    ## framebuffer is the only artifact that says where a headless install
    ## actually stopped, so the failure path has to grab it while QEMU is
    ## still alive — once it exits there is nothing left to dump.
    let tmp = createTempDir("vmh-qwa-run-screen-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")            # deliberately NO sentinel file
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeQemuEnv)
    let golden = tmp / "win-arm-runner-0400"
    var raised = false
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1, cpus = 1,
        memoryMB = 64, deadlineSec = 12, keyPressWindowSec = 1))
    except VmHarnessError as e:
      raised = true
      # The message names it, and names it as the thing to read first.
      check (golden / QwaGoldenScreenshotName) in e.msg
      check "framebuffer" in e.msg
      # ...and the sentinel diagnosis is in the message too, so an operator
      # who sees an EFI shell on that screen knows what it means.
      check "cdboot.efi" in e.msg
    check raised
    # The dump really landed, and it came from the monitor the argv publishes.
    check fileExists(golden / QwaGoldenScreenshotName)
    check readFile(golden / QwaGoldenScreenshotName).startsWith("P6")
    let monitorCmds = readFile(golden / MonitorLogName)
    check ("screendump " & (golden / QwaGoldenScreenshotName)) in monitorCmds

  test "a sysprep that does not take hold fails the build, fast and by name":
    ## The whole orchestration, with a guest that accepts the sysprep launch
    ## and then does nothing — which is exactly what MA4's second host run
    ## saw when sysprep was killed with the SSH session. Before this check
    ## the build spent its entire remaining deadline waiting for a power-off
    ## that could never come, and then blamed sysprep for not shutting down.
    let tmp = createTempDir("vmh-qwa-run-nohold-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    writeFile(tmp / "win.iso", "iso")
    writeFile(tmp / "unattend.iso", "iso")
    writeFile(tmp / "code.fd", "efi code")
    writeFile(tmp / "vars.fd", "efi vars")
    putEnv("VMH_QEMU_EFI_CODE_TEMPLATE", tmp / "code.fd")
    putEnv("VMH_QEMU_EFI_VARS_TEMPLATE", tmp / "vars.fd")
    createDir(tmp / "ssh")
    writeFile(tmp / "ssh" / "sentinel", "")   # the install finished...
    # ...but NO `sysprep-running` file, and no VMH_GOLDEN_FAKE_SSH_VMDIR, so
    # the launch is accepted and then nothing whatsoever happens.
    delEnv("VMH_GOLDEN_FAKE_SSH_VMDIR")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    defer:
      delEnv(FakeSshDirEnv)
      delEnv(FakeQemuEnv)
    let golden = tmp / "win-arm-runner-0500"
    var raised = false
    let start = epochTime()
    try:
      discard b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = golden, windowsIso = tmp / "win.iso",
        autounattendIso = tmp / "unattend.iso", diskGB = 1, cpus = 1,
        memoryMB = 64, deadlineSec = 25, keyPressWindowSec = 1))
    except VmHarnessError as e:
      raised = true
      # It has to say THIS, not "sysprep did not power the guest off": the
      # two have different fixes and only one of them is sysprep's fault.
      check "was launched but was not running" in e.msg
      check "killed with the SSH session" in e.msg
      check "setupact.log" in e.msg
    check raised
    # The launch really was issued — the guest is not being blamed for a
    # command it never received.
    check fileExists(tmp / "ssh" / "sysprep-launched")
    check epochTime() - start < 120.0

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

    # keyPressWindowSec is shortened from the shipped 180s only so the suite
    # stays fast: the fake guest never writes to the disk, so the early exit
    # on disk growth cannot fire and the window would run in full. The
    # shipped default is pinned in "the keypress window's default is the
    # shipped one".
    let produced = b.buildWindowsArmGolden(newGoldenBuildSpec(
      buildDir = golden, windowsIso = tmp / "win.iso",
      autounattendIso = tmp / "unattend.iso", recipeDir = recipeDir(),
      diskGB = 1, cpus = 1, memoryMB = 64, deadlineSec = 60,
      keyPressWindowSec = 2))

    check produced == absolutePath(golden)
    # The keypress that answers cdboot.efi really went to the monitor, and
    # it STOPPED before the power-off watch started: every `sendkey` precedes
    # every `info status`. A keyer still running during Setup's reboots is
    # the failure mode this ordering rules out.
    let monitorCmds = readFile(golden / MonitorLogName).strip().splitLines().
      mapIt(it.strip())
    var lastKey = -1
    var firstStatus = -1
    for i, cmd in monitorCmds:
      if cmd == "sendkey " & QwaInstallMediaKey:
        lastKey = i
      elif cmd == "info status" and firstStatus < 0:
        firstStatus = i
    check lastKey >= 0
    check firstStatus >= 0
    check lastKey < firstStatus
    # The consuming path accepts it — and by the ADMISSION check, not just
    # the structural one, so a build that produced a disk and no manifest
    # could not pass here either.
    check validateWindowsArmVmDir(produced) == absolutePath(golden)
    check requireWindowsArmGolden(produced) == absolutePath(golden)
    # ...sysprep really was issued, with the real command...
    check fileExists(tmp / "ssh" / "sysprep-launched")
    let issued = readFile(tmp / "ssh" / "sysprep-command")
    check "Win32_Process" in issued
    check "Start-Process" notin issued   # measured not to survive the session
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
