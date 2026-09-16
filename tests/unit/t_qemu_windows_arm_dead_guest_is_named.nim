## Runner-Fleet-M3-ARM-Wave MA8 gate: ``t_qemu_windows_arm_dead_guest_is_named``
## — UNIT TIER. Runs anywhere; needs no hypervisor, no Windows and no ISO.
##
## The host tier of the same gate lives in
## ``tests/e2e/t_qemu_windows_arm_dead_guest_is_named_host.nim`` and is wired
## into ``scripts/run-host-tests.sh``. It boots a REAL golden with
## ``-no-reboot`` restored — the known reproducer — and requires the failure to
## arrive in seconds. It SKIPS loudly when there is no golden. This file must
## not be read as covering it.
##
## WHY THIS GATE EXISTS. The per-job run path had no liveness check on the QEMU
## process at all. ``waitForFirstBootSshReady`` polled SSH and counted firmware
## banners and never once consulted the pid it had just been handed, so a QEMU
## that exited kept a port nobody was listening on being polled until the whole
## ``sshReadyTimeoutSec`` ran out. MEASURED TWICE on m3:
##
##   * 2026-09-15, the original ``-no-reboot`` defect: QEMU exited rc=0 at 38s;
##     the harness failed at 301s with ``SSH did not become ready on
##     127.0.0.1:2223 within 300s``.
##   * 2026-09-16, MA4's review restoring ``-no-reboot`` to test the new host
##     gate: the gate failed correctly but took 5m38s, against 3m13s for a
##     healthy run, and its message still LED with SSH.
##
## Both times the information needed to report the truth immediately was
## available and simply not consulted. That is the third instance of this exact
## shape in one campaign — MA0's provider reported success for a guest that had
## died, MA6's listener stopped listening with nothing logged — which is why
## this is a liveness check on the run path rather than a better error string.
##
## WHAT IS ASSERTED HERE:
##
##  1. The exit-status primitives are real: ``childExitInfo`` reaps a direct
##     child ONCE and keeps what ``waitpid`` said, so the status survives to be
##     printed; a signalled death is distinguished from an exit code; a pid
##     that was never ours degrades to "gone, status unavailable" rather than
##     lying in either direction.
##  2. THE CORE. A per-job boot whose QEMU exits fails in SECONDS, through the
##     real ``revertToBaseline``, and the message names the PROCESS and its
##     exit status — not SSH.
##  3. The firmware-boot bound could NOT have caught it: a process that exits
##     leaves the banner count frozen, not growing. Both signals survive and
##     neither substitutes for the other.
##  4. The check cannot turn a working boot into a failing one (MA8's
##     ``:risk:``): it is "the process we started is gone", never "SSH is
##     slow". A live QEMU with the pid passed still reaches SSH, and a wait
##     given no pid still behaves exactly as it did before.
##  5. The diagnostics the message names EXIST. Before this, the failure text
##     pointed at ``<vmDir>/serial.log`` — a path ``stopAndCleanup`` had just
##     deleted.
##  6. ``waitForSshReady``, the public wrapper MA4's review found had no caller
##     and no test, forwards the check and is now exercised.
##
## MOCKING NOTE (workspace policy: every mock must be justified). This file
## uses the SHARED fake QEMU in ``tests/unit/qwa_fake_qemu.nim`` — extracted
## verbatim from MA3/MA4's gate rather than re-implemented, because MA4's
## review established that fake is genuine (real QMP wire JSON, a real
## capabilities negotiation, the real forwarded port, and its reboot decision
## taken from the argv it was handed). A weaker double would have made this
## gate vacuous. What MA8 adds to it is a clock on which it can DIE, which is
## deliberately independent of ``-no-reboot``: the liveness check must name a
## process that is gone whatever ended it. The `/bin/sh` children in the first
## suite are not mocks at all — they are real processes, exiting for real.

## The include below brings the fake QEMU/swtpm/sshpass, ``goldenBackend`` and
## every std import this file needs. See that file for why it is ``include``d
## rather than imported.
include qwa_fake_qemu

proc spawnAndAwaitDeath(shell: string): int =
  ## Start a real child that ends quickly and poll ``childExitInfo`` until it
  ## says so — which is exactly how the run path's wait loop learns the same
  ## fact, so the polling here is the code under test, not a workaround.
  var p = startProcess("/bin/sh", args = @["-c", shell],
                       options = {poUsePath, poParentStreams})
  result = p.processID
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    if childExitInfo(result).exited:
      return
    sleep(20)
  doAssert false, "the helper child never exited: " & shell

proc goldenFor(tmp, name: string): string =
  ## A real golden: a real qcow2 and the manifest that makes it admissible.
  result = tmp / name
  createDir(result)
  createGoldenDisk("qemu-img", result, 1)
  writeFile(result / "QEMU_EFI.fd", "efi code")
  writeFile(result / "QEMU_VARS.fd", "efi vars")
  writeFile(result / QwaGoldenManifestName, "{}")

suite "t_qemu_windows_arm_dead_guest_is_named: the exit-status primitives":
  ## The failure message is only as good as what the harness can still say
  ## about a process that has already gone. ``waitpid`` may only succeed ONCE
  ## per child, and the pre-MA8 code threw the status away on that one call.

  test "a child that exited is reaped, and its exit CODE survives":
    let pid = spawnAndAwaitDeath("exit 7")
    let first = childExitInfo(pid)
    check first.exited
    check first.statusKnown
    check first.exitCode == 7
    check first.termSignal == 0
    check describeChildExit(first) == "exit status 7"
    # The status must survive the reap. Every later caller asks the same
    # question and must get the same answer, or the message that needs it is
    # composed after somebody else has consumed it.
    let second = childExitInfo(pid)
    check second.exited
    check second.statusKnown
    check second.exitCode == 7
    check qemuProcessGone(pid)
    forgetChildExit(pid)

  test "a child killed by a signal is named as killed, not as an exit code":
    let pid = spawnAndAwaitDeath("kill -9 $$; sleep 30")
    let info = childExitInfo(pid)
    check info.exited
    check info.statusKnown
    check info.termSignal == 9
    check describeChildExit(info) == "killed by signal 9"
    forgetChildExit(pid)

  test "a live child is not reported gone, and rc=0 is still a real status":
    var p = startProcess("/bin/sh", args = @["-c", "sleep 30"],
                         options = {poUsePath, poParentStreams})
    let pid = p.processID
    let alive = childExitInfo(pid)
    check not alive.exited
    check describeChildExit(alive) == "still running"
    check not qemuProcessGone(pid)
    # rc=0 is what the real defect produced, so it must not read as "no
    # status": QEMU exiting cleanly is still QEMU being gone.
    discard posix.kill(Pid(pid), SIGTERM)
    discard p.waitForExit(timeout = 5000)
    p.close()
    forgetChildExit(pid)

  test "a pid that was never ours is gone, and says the status is unavailable":
    # ``spawnAndAwaitDeath`` leaves a zombie; reap it through the normal path
    # first, then forget it so the fallback branch is what answers.
    let pid = spawnAndAwaitDeath("exit 3")
    check childExitInfo(pid).exitCode == 3
    forgetChildExit(pid)
    let after = childExitInfo(pid)
    check after.exited
    check not after.statusKnown
    check describeChildExit(after) ==
      "exit status unavailable (the process had already been reaped)"
    # And "gone" is still the answer, which is the property the run path
    # actually depends on.
    check qemuProcessGone(pid)

  test "a nonsense pid is gone rather than an exception":
    check qemuProcessGone(0)
    check qemuProcessGone(-1)
    check childExitInfo(0).exited

suite "t_qemu_windows_arm_dead_guest_is_named: the wait":
  ## ``waitForFirstBootSshReady`` in isolation. The three bounds are
  ## independent and each is checked for not having swallowed the others.

  setup:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeDieAfterSecEnv)
    delEnv(FakeDieExitCodeEnv)
    delEnv(FakeDieBySignalEnv)

  teardown:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeDieAfterSecEnv)
    delEnv(FakeDieExitCodeEnv)
    delEnv(FakeDieBySignalEnv)

  test "a dead QEMU ends the wait at once, with its exit status":
    let tmp = createTempDir("vmh-qwa-deadwait-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    let pid = spawnAndAwaitDeath("exit 0")
    # A deadline far longer than this may take: the point is that the process
    # ends the wait, not the clock.
    let started = epochTime()
    let outcome = b.waitForFirstBootSshReady(0, 120, "", qemuPid = pid)
    check outcome.outcome == fbQemuExited
    check outcome.qemuExit.statusKnown
    check outcome.qemuExit.exitCode == 0
    check epochTime() - started < 30.0
    forgetChildExit(pid)

  test "with no pid named, the deadline is still the only bound":
    ## Behaviour preservation, asserted rather than assumed: every existing
    ## caller that does not pass a pid must wait exactly as it did before.
    let tmp = createTempDir("vmh-qwa-nopid-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")   # no ssh-ready flag: SSH never comes
    let started = epochTime()
    let outcome = b.waitForFirstBootSshReady(0, 1, "")
    check outcome.outcome == fbSshTimedOut
    check epochTime() - started < 30.0

  test "the reboot bound is NOT a substitute, and neither bound ate the other":
    ## A guest that RESTARTS FOREVER and a guest that is GONE are different
    ## failures and MA8 exists because the second was being reported as
    ## neither. The reboot bound must still fire on a live guest...
    let tmp = createTempDir("vmh-qwa-bothbounds-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    let serial = tmp / QwaSerialLogName
    var banners = ""
    for _ in 1 .. QwaFirstBootMaxFirmwareBoots + 1:
      banners.add(FakeFirmwareBanner)
    writeFile(serial, banners)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")

    var live = startProcess("/bin/sh", args = @["-c", "sleep 60"],
                            options = {poUsePath, poParentStreams})
    let livePid = live.processID
    let loop = b.waitForFirstBootSshReady(0, 120, serial, qemuPid = livePid)
    check loop.outcome == fbRebootLoop
    check loop.firmwareBoots == QwaFirstBootMaxFirmwareBoots + 1
    discard posix.kill(Pid(livePid), SIGTERM)
    discard live.waitForExit(timeout = 5000)
    live.close()
    forgetChildExit(livePid)

    # ...and a DEAD process must win over a serial log that looks perfectly
    # healthy, because a QEMU that exits leaves the banner count FROZEN. With
    # only the reboot bound, this is a 120-second silence.
    writeFile(serial, FakeFirmwareBanner)
    let deadPid = spawnAndAwaitDeath("exit 0")
    let started = epochTime()
    let dead = b.waitForFirstBootSshReady(0, 120, serial, qemuPid = deadPid)
    check dead.outcome == fbQemuExited
    check dead.firmwareBoots == 1        # frozen, not growing
    check epochTime() - started < 30.0
    forgetChildExit(deadPid)

  test "waitForSshReady forwards the check to the same place":
    ## The public wrapper MA4's review found had no in-tree caller and no test
    ## of its own. It is kept rather than deprecated — collapsing three
    ## outcomes into a bool is a legitimate thing for an out-of-tree caller to
    ## want — but it must not be a way to opt out of the liveness check by
    ## accident, so it takes the pid too.
    let tmp = createTempDir("vmh-qwa-wrapper-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    let pid = spawnAndAwaitDeath("exit 0")
    let started = epochTime()
    check not b.waitForSshReady(0, 120, qemuPid = pid)
    check epochTime() - started < 30.0
    forgetChildExit(pid)
    # And with no pid it is the plain deadline question it has always been.
    check not b.waitForSshReady(0, 1)

suite "t_qemu_windows_arm_dead_guest_is_named: the per-job boot":
  ## END TO END through the real ``revertToBaseline``, the real per-job argv, a
  ## real ``qemu-img`` overlay, and the shared fake QEMU — told to die partway
  ## through the first boot.

  setup:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeQmpRefuseEnv)
    delEnv(FakeDieAfterSecEnv)
    delEnv(FakeDieExitCodeEnv)
    delEnv(FakeDieBySignalEnv)

  teardown:
    delEnv(FakeQemuEnv)
    delEnv(FakeSshDirEnv)
    delEnv(FakeFirstBootRebootEnv)
    delEnv(FakeBootLoopEnv)
    delEnv(FakeQmpRefuseEnv)
    delEnv(FakeDieAfterSecEnv)
    delEnv(FakeDieExitCodeEnv)
    delEnv(FakeDieBySignalEnv)

  test "a guest whose QEMU exits is failed in seconds, naming the process":
    ## THE GATE. With the liveness check removed this test does not merely
    ## report a worse message — it sits out the whole ``sshReadyTimeoutSec``
    ## below and then blames SSH, which is precisely the 2026-09-15 and
    ## 2026-09-16 measurements on m3.
    let tmp = createTempDir("vmh-qwa-deadguest-", "")
    defer: removeDir(tmp)
    # 120s, not the production 300s, purely so a FALSIFIED build fails in two
    # minutes instead of five. It is still 20x the time the check needs, so
    # "seconds, not the deadline" is a real assertion at this length.
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 120)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")   # no ssh-ready flag: sshd never exists
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeDieAfterSecEnv, "4.0")    # outlasts the port-claim handshake
    putEnv(FakeDieExitCodeEnv, "0")      # rc=0, as the real defect produced

    let golden = goldenFor(tmp, "win-arm-runner-0800")
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))

    var raised = false
    var msg = ""
    var handedOut: VmHandle = nil
    let started = epochTime()
    try:
      handedOut = b.revertToBaseline("win-arm-runner")
    except GuestBootFailureError as e:
      raised = true
      msg = e.msg
    let elapsed = epochTime() - started
    if handedOut != nil:
      # Only reachable under a falsification. Reap it: a leaked fake QEMU
      # inherits this process's stdout and would hang the suite.
      b.stopAndCleanup(handedOut, deleteVm = true)
    check raised
    echo "[t_qemu_windows_arm_dead_guest_is_named] failed after " &
         $(int(elapsed * 1000)) & "ms of a " & $b.sshReadyTimeoutSec &
         "s SSH deadline"

    # IN SECONDS, NOT AT THE DEADLINE. The fake dies at 4s and the wait polls
    # every 3s, so ~7s is the expected shape; 40 leaves room for a loaded
    # builder while staying nowhere near the 120s deadline.
    check elapsed < 40.0

    # THE MESSAGE NAMES THE CAUSE, NOT THE SYMPTOM.
    check "EXITED" in msg
    check "exit status 0" in msg
    check "there is no guest" in msg
    # It must not be reported as an SSH timeout. That sentence is the one an
    # operator spent five minutes waiting for and then mis-diagnosed from.
    check "SSH did not become ready" notin msg
    # And the diagnostics it points at have to be REAL FILES. The pre-MA8
    # message named <vmDir>/serial.log, which stopAndCleanup had just deleted.
    check "Diagnostics retained in " in msg
    let diagDir = msg[msg.find("Diagnostics retained in ") +
                      len("Diagnostics retained in ") .. ^1].split(":")[0]
    check dirExists(diagDir)
    check fileExists(diagDir / QwaSerialLogName)
    check fileExists(diagDir / "qemu.log")
    check QwaFirmwareBannerMarker in readFile(diagDir / QwaSerialLogName)

    # The instance itself is still reaped — a failed boot per job would
    # otherwise leave a disk image behind every time.
    check dirExists(b.stateDir / "instances")
    var leftovers = 0
    for kind, _ in walkDir(b.stateDir / "instances"):
      if kind == pcDir:
        inc leftovers
    check leftovers == 0

  test "a guest whose QEMU is KILLED is named as killed, with the signal":
    ## ``-no-reboot`` is one cause. The check has to report the process being
    ## gone whatever ended it, so this one is shot rather than exiting.
    let tmp = createTempDir("vmh-qwa-killedguest-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 120)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeDieAfterSecEnv, "4.0")
    putEnv(FakeDieBySignalEnv, "9")

    let golden = goldenFor(tmp, "win-arm-runner-0801")
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))
    var msg = ""
    var handedOut: VmHandle = nil
    let started = epochTime()
    try:
      handedOut = b.revertToBaseline("win-arm-runner")
    except GuestBootFailureError as e:
      msg = e.msg
    let elapsed = epochTime() - started
    if handedOut != nil:
      b.stopAndCleanup(handedOut, deleteVm = true)
    check "killed by signal 9" in msg
    check "SSH did not become ready" notin msg
    check elapsed < 40.0

  test "a LIVE guest's failure keeps its framebuffer, not just its logs":
    ## ``captureGuestScreen`` was MA4's single highest-value diagnostic — it
    ## turned a blind 90-minute timeout into a ten-second diagnosis — and it
    ## was reachable only from the BUILD path. A Windows guest is mute on the
    ## serial port once the firmware hands over, so on a guest that is ALIVE
    ## but stuck the screen is the only thing that says where it stopped.
    ##
    ## Driven through the one per-job failure that leaves QEMU running: a
    ## guest that answers SSH but refuses ``set-action``.
    let tmp = createTempDir("vmh-qwa-screen-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 45)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeFirstBootRebootEnv, "1")
    putEnv(FakeQmpRefuseEnv, "1")

    let golden = goldenFor(tmp, "win-arm-runner-0803")
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))
    var msg = ""
    var handedOut: VmHandle = nil
    try:
      handedOut = b.revertToBaseline("win-arm-runner")
    except GuestBootFailureError as e:
      msg = e.msg
    if handedOut != nil:
      b.stopAndCleanup(handedOut, deleteVm = true)
    check "one-shot reboot semantics could not be restored" in msg
    check QwaGoldenScreenshotName in msg
    check "read this FIRST" in msg
    let diagDir = msg[msg.find("Diagnostics retained in ") +
                      len("Diagnostics retained in ") .. ^1].split(":")[0]
    check fileExists(diagDir / QwaGoldenScreenshotName)
    check readFile(diagDir / QwaGoldenScreenshotName).startsWith("P6")
    check fileExists(diagDir / QwaSerialLogName)

  test "a LIVE guest still boots — the check reads the process, not SSH":
    ## MA8's ``:risk:`` as an assertion. The check must be "the process we
    ## started is gone" and never "SSH is slow", or it turns a slow but
    ## healthy boot into a failure. Same argv, same fake, same mandatory
    ## reboot as MA4's end-to-end test — only without the death clock.
    let tmp = createTempDir("vmh-qwa-liveguest-", "")
    defer: removeDir(tmp)
    let b = goldenBackend(tmp, sshReadyTimeoutSec = 45)
    createDir(tmp / "ssh")
    putEnv(FakeSshDirEnv, tmp / "ssh")
    putEnv(FakeQemuEnv, "1")
    putEnv(FakeFirstBootRebootEnv, "1")

    let golden = goldenFor(tmp, "win-arm-runner-0802")
    b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                     sourceImage: golden, cpus: 1,
                                     memoryMB: 64))
    let vm = b.revertToBaseline("win-arm-runner")
    let vmDir = vm.extra["vmDir"]
    try:
      check vm.extra["firmwareBoots"] == "2"
      check vm.extra["rebootAction"] == QwaOneShotRebootAction
      # Nothing was retained, because nothing failed.
      check not dirExists(b.stateDir / QwaFailedBootDirName)
    finally:
      b.stopAndCleanup(vm, deleteVm = true)
    check not dirExists(vmDir)

suite "t_qemu_windows_arm_dead_guest_is_named: retained diagnostics":
  ## The three files a failed per-job boot leaves behind, and the bound on how
  ## many of them a CI host accumulates.

  test "only the small files are copied, and the count is bounded":
    let tmp = createTempDir("vmh-qwa-diagkeep-", "")
    defer: removeDir(tmp)
    let stateDir = tmp / "state"
    createDir(stateDir)

    var kept: seq[string] = @[]
    for i in 1 .. QwaRetainedFailedBoots + 3:
      # ephemeralName embeds the creation epoch, so lexicographic order is
      # chronological order and the pruner can rely on it.
      let name = "vmh-qwa-" & align($i, 4, '0')
      let vmDir = tmp / name
      createDir(vmDir)
      writeFile(vmDir / QwaSerialLogName, FakeFirmwareBanner)
      writeFile(vmDir / "qemu.log", "qemu said things\n")
      # The disk must NOT be copied: retaining one per failed boot is how a CI
      # host fills up overnight.
      writeFile(vmDir / QwaOverlayDiskName, "a whole disk image")
      kept.add(retainFailedBootDiagnostics(stateDir, name, vmDir))

    check kept[^1].len > 0
    check fileExists(kept[^1] / QwaSerialLogName)
    check fileExists(kept[^1] / "qemu.log")
    check not fileExists(kept[^1] / QwaOverlayDiskName)

    var retained = 0
    for kind, _ in walkDir(stateDir / QwaFailedBootDirName):
      if kind == pcDir:
        inc retained
    check retained == QwaRetainedFailedBoots
    # The NEWEST are the ones kept.
    check dirExists(stateDir / QwaFailedBootDirName /
                    ("vmh-qwa-" & align($(QwaRetainedFailedBoots + 3), 4, '0')))
    check not dirExists(stateDir / QwaFailedBootDirName / "vmh-qwa-0001")

  test "an instance with nothing to keep retains nothing, and says so":
    let tmp = createTempDir("vmh-qwa-diagnone-", "")
    defer: removeDir(tmp)
    let stateDir = tmp / "state"
    createDir(stateDir)
    let vmDir = tmp / "empty-instance"
    createDir(vmDir)
    check retainFailedBootDiagnostics(stateDir, "empty-instance", vmDir) == ""
    check not dirExists(stateDir / QwaFailedBootDirName / "empty-instance")
    check "No diagnostics could be retained" in qwaPerJobDiagnostics("")

  test "the framebuffer is named FIRST when one was captured":
    let tmp = createTempDir("vmh-qwa-diagscreen-", "")
    defer: removeDir(tmp)
    createDir(tmp / "diag")
    check QwaGoldenScreenshotName notin qwaPerJobDiagnostics(tmp / "diag")
    writeFile(tmp / "diag" / QwaGoldenScreenshotName, "P6\n1 1\n255\n\0\0\0")
    let text = qwaPerJobDiagnostics(tmp / "diag")
    check QwaGoldenScreenshotName in text
    check "read this FIRST" in text
