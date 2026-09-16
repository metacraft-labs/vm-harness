## The Windows-ARM fake QEMU harness, shared by the unit-tier gates that need
## to drive the real backend against a process that behaves like QEMU.
##
## THIS FILE IS ``include``d, NOT IMPORTED, and that is deliberate. The fake
## QEMU is THIS TEST BINARY re-executed with ``$VMH_GOLDEN_FAKE_QEMU=1``
## (``getAppFilename()`` is handed to the backend as ``qemuCmd``), following
## the existing ``PortListenerHelperEnv`` pattern in
## ``t_qemu_windows_arm_backend.nim``. A textual include is what makes the
## re-exec entry point land in each gate's own binary; an import could not.
##
## It was extracted VERBATIM from
## ``tests/unit/t_qemu_windows_arm_golden_build.nim`` (MA3/MA4) when MA8 added
## a second gate needing the same fake. Extracting rather than re-implementing
## is the point: MA4's review established that this fake is GENUINE — it
## speaks real QMP wire JSON, refuses every command until ``qmp_capabilities``
## exactly as QEMU 10.1.5 does, binds the REAL forwarded port, serves a REAL
## unix monitor socket, and takes its reboot decision from the argv it was
## handed. A second, weaker double would have made the new gate vacuous.
##
## MOCKING NOTE (workspace policy: every mock must be justified). Three fakes
## live here and each replaces something that cannot exist in a unit tier:
##   * a fake QEMU — see above. Only the GUEST is absent; the port-claim
##     handshake, the monitor conversation and the QMP negotiation are real.
##   * a fake ``swtpm`` — creates the real control socket the startup path
##     waits for.
##   * a fake ``sshpass`` — a shell script. The SSH ARGUMENT VECTOR, the probe
##     command and the sysprep command it receives are the real ones, and the
##     script asserts on them; only Windows is absent.
## Everything else is real: a real ``qemu-img`` allocates the real qcow2, the
## real recipe files are read off disk, and the real ``shasum`` computes the
## manifest digests.

import std/[json, net, os, osproc, posix, strutils, tables,
            tempfiles, times, unittest]
import vm_harness

const
  FakeQemuEnv = "VMH_GOLDEN_FAKE_QEMU"
  FakeSshLogEnv = "VMH_GOLDEN_FAKE_SSH_LOG"
  FakeSshDirEnv = "VMH_GOLDEN_FAKE_SSH_DIR"
  PowerOffFlagName = ".fake-poweroff"
  MonitorLogName = ".fake-monitor-commands"
  FakeFreezeEnv = "VMH_GOLDEN_FAKE_QEMU_FREEZE_FIRST_BOOT"
  FakeBootCountName = ".fake-boots"
  FakeSwtpmLogEnv = "VMH_GOLDEN_FAKE_SWTPM_LOG"
  # The per-job boot's reboot lifecycle (MA4).
  FakeFirstBootRebootEnv = "VMH_GOLDEN_FAKE_QEMU_FIRST_BOOT_REBOOT"
    ## Model a generalized golden: reboot ONCE before sshd exists.
  FakeBootLoopEnv = "VMH_GOLDEN_FAKE_QEMU_BOOT_LOOP"
    ## Model a guest that restarts forever and never reaches sshd.
  FakeQmpRefuseEnv = "VMH_GOLDEN_FAKE_QMP_REFUSE"
    ## Model a QEMU that will not take ``set-action``.
  # The per-job boot's liveness check (MA8).
  FakeDieAfterSecEnv = "VMH_GOLDEN_FAKE_QEMU_DIE_AFTER_SEC"
    ## Model a QEMU that EXITS partway through the first boot, before sshd
    ## has ever existed. Deliberately NOT tied to ``-no-reboot``: that flag is
    ## only the cause that was caught in the act on 2026-09-15, and the
    ## liveness check has to report the process being gone whatever killed
    ## it. The value is seconds, and must outlast the port-claim handshake
    ## (``QemuPortClaimTimeoutMs``) or the failure under test is replaced by
    ## "QEMU failed to claim an allocated SSH port".
  FakeDieExitCodeEnv = "VMH_GOLDEN_FAKE_QEMU_DIE_EXIT_CODE"
    ## The status it exits with. Defaults to 0, because rc=0 is what the real
    ## defect produced and a NON-zero status would make the check easy in a
    ## way the real failure is not.
  FakeDieBySignalEnv = "VMH_GOLDEN_FAKE_QEMU_DIE_BY_SIGNAL"
    ## Exit by raising a signal on itself instead, so the "killed by signal
    ## N" half of the exit-status decoding is exercised against a real
    ## ``waitpid`` status rather than a hand-built one.
  QmpLogName = ".fake-qmp-commands"
  SshReadyFlagName = "ssh-ready"
  FakeFirmwareBanner =
    "UEFI firmware (version edk2-fake built at 00:00:00 on Jan 1 1980)\n"
    ## One per firmware boot, carrying ``QwaFirmwareBannerMarker`` verbatim.

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
  if getEnv(FakeFreezeEnv) == "1":
    # A guest that FREEZES on its first boot and installs on its second.
    #
    # This is the only shape in which the freeze watchdog can be driven end
    # to end: on the first boot this fake writes the serial log once and then
    # goes quiet for good, which is exactly the signature the two frozen
    # host runs had (serial log still for 23 minutes, target disk for 30).
    # It writes the install sentinel only on a LATER boot, so nothing but a
    # real power cycle can make the build succeed.
    let bootFlag = getCurrentDir() / FakeBootCountName
    if fileExists(bootFlag):
      let sshDir = getEnv(FakeSshDirEnv)
      if sshDir.len > 0:
        writeFile(sshDir / "sentinel", "")
    else:
      writeFile(bootFlag, "first boot\n")
  let serialArg = argStartingWith("file:")
  let serialPath =
    if serialArg.len > 0: serialArg["file:".len .. ^1] else: ""
  if serialPath.len > 0:
    # One firmware banner per boot, as EDK2 prints it and as
    # ``qwaFirmwareBootCount`` counts it. The fake has to speak this now that
    # a reboot no longer ends QEMU: the serial log is the ONLY place a reboot
    # is visible from outside the guest.
    writeFile(serialPath,
              FakeFirmwareBanner & "fake guest serial console output\n")
  let qemuLog = argValue("-D")
  if qemuLog.len > 0:
    writeFile(qemuLog, "fake qemu log\n")

  var listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  # A power cycle restarts this fake on the SAME forwarded port the previous
  # incarnation had just released, so the bind is retried rather than taken
  # for granted; a fake that died here would look like a guest that never
  # came back.
  block bindPort:
    for attempt in 1 .. 40:
      try:
        listener.bindAddr(Port(fakeQemuForwardedPort()), "127.0.0.1")
        break bindPort
      except OSError:
        if attempt == 40:
          raise
        sleep(100)
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

  # ---- QMP, when the argv publishes one ----------------------------------
  #
  # Only the PER-JOB vector does. This fake serves it for one reason: HMP has
  # no ``set-action``, so the transition back to one-shot reboot semantics is
  # a QMP conversation and nothing else can observe it. The negotiation is
  # modelled faithfully — greeting, then every command REFUSED until
  # ``qmp_capabilities`` — because a client that skipped it would work
  # against a lenient fake and fail against a real QEMU.
  var qmpListener: Socket = nil
  let qmpArg = argValue("-qmp")
  if qmpArg.startsWith("unix:") and qmpArg.find(",server=on") > 0:
    let qmpPath = qmpArg["unix:".len ..< qmpArg.find(",server=on")]
    removeFile(qmpPath)
    qmpListener = newSocket(net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                            net.Protocol.IPPROTO_IP)
    qmpListener.bindUnix(qmpPath)
    qmpListener.listen()

  # ---- The guest's reboot timeline ---------------------------------------
  #
  # A real ``/generalize``d golden reboots ONCE before ``sshd`` has ever
  # existed, between its specialize and oobeSystem passes. That reboot is the
  # whole reason the per-job argv changed, so the fake performs it — and
  # takes the same decision on it that QEMU takes, READ OFF THE ARGV IT WAS
  # HANDED. That is what lets this tier tell a bootable argument vector from
  # an unbootable one, which is exactly what it could not do before.
  let firstBootReboot = getEnv(FakeFirstBootRebootEnv) == "1"
  let bootLoop = getEnv(FakeBootLoopEnv) == "1"
  let sshDir = getEnv(FakeSshDirEnv)
  var runtimeRebootAction =
    if "-no-reboot" in commandLineParams(): "shutdown"
    elif argValue("-action") == "reboot=shutdown": "shutdown"
    else: "reset"
  var nextRebootAt =
    if firstBootReboot or bootLoop: epochTime() + 1.2 else: 0.0

  # ---- Death that is nothing to do with the reboot policy (MA8) -----------
  #
  # ``-no-reboot`` is only the cause that was caught in the act. The liveness
  # check has to name a QEMU that is gone WHATEVER ended it, so this fake can
  # also just die on a clock.
  let dieAfterSec =
    try:
      if getEnv(FakeDieAfterSecEnv).len > 0:
        parseFloat(getEnv(FakeDieAfterSecEnv))
      else: 0.0
    except ValueError:
      0.0
  let dieAt = if dieAfterSec > 0.0: epochTime() + dieAfterSec else: 0.0

  proc fakeQemuExit(code: int) =
    # A real QEMU unlinks its own control sockets on a clean exit (MEASURED
    # against qemu-system-aarch64 10.1.5 in MA4's review). Doing the same
    # keeps the harness honest — a stale socket left behind would let a
    # "capture the screen of a dead guest" path connect to nothing forever —
    # and keeps this fake out of the /tmp socket litter MA7 sweeps up.
    try: removeFile(monitorPath)
    except CatchableError: discard
    if qmpListener != nil:
      let qmpArgValue = argValue("-qmp")
      try:
        removeFile(qmpArgValue["unix:".len ..< qmpArgValue.find(",server=on")])
      except CatchableError: discard
    let sig = getEnv(FakeDieBySignalEnv)
    if sig.len > 0:
      # Raise it on ourselves so waitpid reports a REAL WIFSIGNALED status.
      discard posix.kill(posix.getpid(), cint(parseInt(sig)))
      sleep(2000)
    quit(code)

  proc simulateGuestReboot() =
    if runtimeRebootAction == "shutdown":
      # -no-reboot, by either spelling: QEMU EXITS. On the first boot of a
      # generalized golden that happens before sshd exists, which is the
      # 2026-09-15 defect, reproduced here from the real argument vector.
      fakeQemuExit(QuitSuccess)
    if serialPath.len > 0:
      let f = open(serialPath, fmAppend)
      f.write(FakeFirmwareBanner)
      f.close()
    if bootLoop:
      nextRebootAt = epochTime() + 0.4
    else:
      nextRebootAt = 0.0
      # sshd is started by the FirstLogonCommands that run AFTER the reboot.
      if sshDir.len > 0:
        writeFile(sshDir / "ssh-ready", "")

  proc serveQmpClient() =
    let fd = posix.accept(qmpListener.getFd(), nil, nil)
    if cint(fd) < 0:
      return
    var client = newSocket(fd, net.Domain.AF_UNIX, net.SockType.SOCK_STREAM,
                           net.Protocol.IPPROTO_IP)
    var negotiated = false
    proc reply(node: JsonNode) =
      client.send($node & "\n")
    proc ok(): JsonNode =
      result = newJObject()
      result["return"] = newJObject()
    proc err(desc: string): JsonNode =
      result = newJObject()
      result["error"] = %*{"class": "GenericError", "desc": desc}
    try:
      reply(%*{"QMP": {"version": {"qemu": {"major": 10, "minor": 1,
                                            "micro": 5}},
                       "capabilities": ["oob"]}})
      while true:
        var line = ""
        client.readLine(line, timeout = 500)
        if line.len == 0:
          break
        let log = open(getCurrentDir() / QmpLogName, fmAppend)
        log.writeLine(line)
        log.close()
        var request: JsonNode
        try:
          request = parseJson(line)
        except CatchableError:
          reply(err("not JSON"))
          continue
        let cmd =
          if request.kind == JObject and request.hasKey("execute"):
            request["execute"].getStr
          else: ""
        if cmd == "qmp_capabilities":
          negotiated = true
          reply(ok())
        elif not negotiated:
          reply(err("Expecting capabilities negotiation with " &
                    "'qmp_capabilities'"))
        elif cmd == "set-action":
          if getEnv(FakeQmpRefuseEnv) == "1":
            reply(err("fake QEMU refuses set-action"))
          else:
            if request.hasKey("arguments") and
               request["arguments"].hasKey("reboot"):
              runtimeRebootAction = request["arguments"]["reboot"].getStr
            reply(ok())
        else:
          reply(err("fake QEMU does not implement " & cmd))
    except CatchableError:
      discard
    try: client.close()
    except CatchableError: discard

  proc serveMonitorClient() =
    # Raw accept: std/net's own ``accept`` stringifies the peer address, and
    # an AF_UNIX peer has none, so it raises on a perfectly good connection.
    let fd = posix.accept(monitor.getFd(), nil, nil)
    if cint(fd) < 0:
      return
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

  # One loop over both control sockets, plus the reboot clock. A real QEMU
  # serves whichever the harness connects to next; the harness's own calls are
  # sequential, so serving one client at a time is faithful.
  while true:
    if dieAt > 0.0 and epochTime() >= dieAt:
      fakeQemuExit(try: parseInt(getEnv(FakeDieExitCodeEnv, "0"))
                   except ValueError: 0)
    if nextRebootAt > 0.0 and epochTime() >= nextRebootAt:
      simulateGuestReboot()
    var readable: TFdSet
    FD_ZERO(readable)
    FD_SET(cint(monitor.getFd()), readable)
    var maxFd = cint(monitor.getFd())
    if qmpListener != nil:
      FD_SET(cint(qmpListener.getFd()), readable)
      maxFd = max(maxFd, cint(qmpListener.getFd()))
    var tv = Timeval(tv_sec: posix.Time(0), tv_usec: Suseconds(200_000))
    if posix.select(maxFd + 1, addr readable, nil, nil, addr tv) <= 0:
      continue
    if qmpListener != nil and FD_ISSET(cint(qmpListener.getFd()), readable) != 0:
      serveQmpClient()
    if FD_ISSET(cint(monitor.getFd()), readable) != 0:
      serveMonitorClient()

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
  ## stays alive as the real one does. Records every start in
  ## ``$VMH_GOLDEN_FAKE_SWTPM_LOG`` when that is set, because a power cycle
  ## has to bring swtpm back as well as QEMU and "it was started twice" is
  ## the only way to see that from outside.
  writeExecutable(path, """#!/bin/sh
for a in "$@"; do
  case "$a" in
    type=unixio,path=*) : > "${a#type=unixio,path=}" ;;
  esac
done
if [ -n "${VMH_GOLDEN_FAKE_SWTPM_LOG:-}" ]; then
  printf 'started %s\n' "$*" >> "$VMH_GOLDEN_FAKE_SWTPM_LOG"
fi
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
  *"echo ready"*)
    # The per-job readiness probe. Gated on a flag the fake QEMU creates
    # AFTER its simulated reboot, because that is when the real guest's
    # FirstLogonCommands start sshd -- a probe that answered before the
    # reboot would make the whole reboot question invisible.
    if [ -f "$VMH_GOLDEN_FAKE_SSH_DIR/ssh-ready" ]; then
      echo "ready"
      exit 0
    fi
    exit 1
    ;;
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

proc goldenBackend(tmp: string; qemuCmd = "";
                   sshReadyTimeoutSec = 300): QemuWindowsArmBackend =
  ## ``sshReadyTimeoutSec`` is shortened only by the per-job tests, and only
  ## so a BROKEN per-job argv fails this suite in seconds instead of sitting
  ## out the production deadline — which is what the run path itself does
  ## today against a QEMU that has already exited (MA8). The shipped default
  ## is pinned in "the shipped SSH-ready deadline is the production one".
  let swtpm = tmp / "swtpm"
  let sshpass = tmp / "sshpass"
  writeFakeSwtpm(swtpm)
  writeFakeSshpass(sshpass)
  newQemuWindowsArmBackend(
    qemuCmd = (if qemuCmd.len > 0: qemuCmd else: getAppFilename()),
    swtpmCmd = swtpm,
    sshpassCmd = sshpass,
    stateDir = tmp / "state",
    sshPort = 0,
    sshReadyTimeoutSec = sshReadyTimeoutSec)
