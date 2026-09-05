## Gate: a booted Linux guest really sees the virtual TPM when
## ``BootMediaSpec.tpmEnabled`` is set, and really sees no TPM when it is
## not.
##
## *Why this gate has to boot something.* The argv assertions in
## ``tests/unit/t_tpm_device_args.nim`` prove the backend *asks* QEMU for
## a TPM. They cannot prove QEMU attached one, that swtpm answered, or
## that the guest's driver bound to it — and a vTPM that has never been
## observed from inside a guest is not evidence that any of that works.
## Every later attestation gate reads PCRs from inside a guest, so the
## thing that must be true is exactly the thing this file checks.
##
## *What the guest is.* ``nix/guest-linux-tpm.nix``: a stock nixpkgs
## ``bzImage`` plus a busybox initramfs, direct-kernel-booted with no
## disk, bootloader or partition table. It reaches its ``/init``, reports
## what it sees of ``/dev/tpm0``, and powers off — about 1.5 s under KVM
## with a TPM, about 3.5 s without one (the extra time is the initramfs's
## bounded wait for a device that never appears). The store path is
## exported as ``$VMH_TPM_GUEST_DIR`` by the flake's devShell, which is
## what lets this gate run with no network and no build step of its own.
##
## The load-bearing marker is ``VMH-TPM2-GETCAP-FAMILY``. It is not a
## sysfs readout: the guest writes a real 22-byte
## TPM2_GetCapability(TPM_PT_FAMILY_INDICATOR) command to ``/dev/tpm0``
## and hex-dumps the response, which for a TPM 2.0 ends in the ASCII
## family indicator ``322e3000`` = "2.0\0". Nothing but a real, running,
## responding TPM 2.0 produces those bytes.
##
## *Mocking.* None. Real ``qemu-system-x86_64``, real ``swtpm``, real
## Linux kernel, real ``/dev/tpm0``, real TPM 2.0 command/response. The
## only synthetic thing is the guest's userspace, and it is synthetic in
## the sense of "small", not in the sense of "stands in for the thing
## under test".
##
## On Linux this file has NO skip path. Every case runs or the gate is red.

import std/[os, posix, strutils, tables, unittest]

when not defined(linux):
  echo "[skip] t_guest_sees_tpm_device: the qemu-boot vTPM path is Linux-only"
  quit(0)

import vm_harness

const
  TestNamePrefix = "repro-test-tpm-guest-"
    ## Distinct from the default ``repro-test-boot-qemu-`` prefix so this
    ## gate's leak assertions can never be confused by a concurrently
    ## running boot-smoke gate — and so that nothing it sweeps could ever
    ## belong to this host's production CI.

  MarkerStart = "VMH-TPM-PROBE-START"
  MarkerPresent = "VMH-TPM-DEVICE=present"
  MarkerAbsent = "VMH-TPM-DEVICE=absent"
  MarkerDone = "VMH-TPM-PROBE-DONE"
  MarkerSysfsMajor2 = r"VMH-TPM-SYSFS-VERSION-MAJOR=2"
  # 8001 <size> 00000000 (success) … 00000100 (TPM_PT_FAMILY_INDICATOR)
  # 322e3000 ("2.0\0"). Anchored on both the property id and the value so
  # a response that merely contained the bytes somewhere cannot match.
  MarkerGetCapFamily = r"VMH-TPM2-GETCAP-FAMILY=8001[0-9a-f]+00000100322e3000"

proc guestDir(): string =
  ## The pinned guest bundle. Absent is a hard failure naming the remedy,
  ## never a skip: a vTPM gate that quietly does not run is the exact
  ## failure mode this gate exists to rule out.
  let fromEnv = getEnv("VMH_TPM_GUEST_DIR")
  if fromEnv.len > 0:
    return fromEnv
  ""

proc requireGuest(): string =
  let d = guestDir()
  doAssert d.len > 0,
    "VMH_TPM_GUEST_DIR is unset. It is exported by the vm-harness dev " &
    "shell; run this gate under `direnv exec . …` / `nix develop`, or " &
    "set it by hand to the output of `nix build .#guest-linux-tpm`."
  doAssert fileExists(d / "kernel"),
    "VMH_TPM_GUEST_DIR has no kernel: " & d
  doAssert fileExists(d / "initramfs.gz"),
    "VMH_TPM_GUEST_DIR has no initramfs.gz: " & d
  d

proc artifactDir(): string =
  let root = currentSourcePath().parentDir.parentDir.parentDir
  resolveArtifactDir(root)

proc tpmGuestSpec(caseName: string, tpm: bool,
                  steps: seq[BootSmokeStep]): BootSmokeSpec =
  let g = requireGuest()
  BootSmokeSpec(
    caseName: caseName,
    kernelPath: g / "kernel",
    initrdPath: g / "initramfs.gz",
    # Must match nix/guest-linux-tpm.nix's manifest.env. ``panic=1``
    # turns a kernel panic into an exit instead of a hang, so a broken
    # guest fails the gate at its per-step timeout rather than at the
    # suite's.
    kernelCmdline: "console=ttyS0 panic=1 loglevel=3",
    cpus: 2,
    memoryMB: 1024,
    acceleration: baAuto,
    tpmEnabled: tpm,
    steps: steps,
    artifactDir: artifactDir(),
    namePrefix: TestNamePrefix)

proc step(pattern, label: string, timeoutSec = 60): BootSmokeStep =
  BootSmokeStep(pattern: pattern, timeoutSec: timeoutSec, label: label)

proc liveSwtpms(): seq[string] =
  ## swtpm processes holding state under THIS gate's name prefix. Reads
  ## ``/proc``, so it observes the system rather than the code path that
  ## was supposed to clean up.
  let b = newQemuBootBackend(namePrefix = TestNamePrefix)
  for e in qemuBootSwtpmProcessesMatching(b.stateDir, TestNamePrefix):
    result.add($e.pid & " " & e.stateArg)

proc liveQemus(): seq[string] =
  for e in qemuBootProcessesMatching(TestNamePrefix):
    result.add($e.pid & " " & e.name)

suite "a booted Linux guest sees the vTPM when it is enabled":
  test "with tpmEnabled the guest reports /dev/tpm0 and a TPM 2.0 capability readout":
    let spec = tpmGuestSpec("tpm-enabled", tpm = true, steps = @[
      step(MarkerStart, "the guest reached its init"),
      step(MarkerPresent, "the kernel bound a TPM chardev at /dev/tpm0"),
      step(MarkerSysfsMajor2, "sysfs reports a TPM major version of 2"),
      step(MarkerGetCapFamily,
           "the TPM answered TPM2_GetCapability(FAMILY_INDICATOR) with \"2.0\""),
      step(MarkerDone, "the guest finished its probe"),
    ])
    let r = runBootSmoke(spec)
    if not r.ok:
      echo r.failureMessage
      echo serialLogExcerpt(r.serialLogPath)
    check r.ok
    check r.failedStepIndex == -1
    check r.matches.len == spec.steps.len

    # The transcript is an artifact and must outlive teardown.
    check fileExists(r.serialLogPath)
    let log = readFile(r.serialLogPath)
    check MarkerPresent in log
    check MarkerAbsent notin log

  test "without tpmEnabled the same guest reports no TPM device":
    let spec = tpmGuestSpec("tpm-disabled", tpm = false, steps = @[
      step(MarkerStart, "the guest reached its init"),
      step(MarkerAbsent, "the kernel found no TPM to bind"),
      step(MarkerDone, "the guest finished its probe"),
    ])
    let r = runBootSmoke(spec)
    if not r.ok:
      echo r.failureMessage
      echo serialLogExcerpt(r.serialLogPath)
    check r.ok

    # The negative polarity, asserted against the whole transcript rather
    # than only the steps: nothing anywhere in the boot claimed a TPM.
    check fileExists(r.serialLogPath)
    let log = readFile(r.serialLogPath)
    check MarkerAbsent in log
    check MarkerPresent notin log
    check "VMH-TPM2-GETCAP-FAMILY" notin log
    check "322e3000" notin log

  test "the TPM-less guest FAILS an assertion that demands a TPM":
    # Falsifiability. If this case passed, the two above would prove
    # nothing: the harness would be matching patterns that are always
    # satisfiable rather than the guest's actual bytes.
    let spec = tpmGuestSpec("tpm-disabled-demanding-tpm", tpm = false, steps = @[
      step(MarkerStart, "the guest reached its init"),
      step(MarkerPresent, "a TPM this boot deliberately does not have",
           timeoutSec = 15),
    ])
    let r = runBootSmoke(spec)
    check not r.ok
    check r.outcome == bsPatternNotSeen
    check r.failedStepIndex == 1
    check MarkerPresent in r.failureMessage

suite "a vTPM boot leaves nothing behind":
  test "no swtpm, no QEMU, no run directory survives either polarity":
    # Runs both polarities back to back and then asserts against observed
    # system state. swtpm is the interesting one: it is NOT a child of
    # QEMU and nothing reaps it when the guest powers off, so only an
    # explicit teardown can make this pass.
    check liveSwtpms().len == 0
    check liveQemus().len == 0

    var runDirs: seq[string] = @[]
    for tpm in [true, false]:
      let spec = tpmGuestSpec("teardown-" & $tpm, tpm = tpm, steps = @[
        step(MarkerDone, "the guest finished its probe"),
      ])
      let r = runBootSmoke(spec)
      check r.ok
      runDirs.add(r.runDir)

    # Give SIGTERM a moment to be delivered before reading /proc.
    for _ in 0 ..< 40:
      if liveSwtpms().len == 0 and liveQemus().len == 0:
        break
      sleep(50)

    check liveSwtpms().len == 0
    check liveQemus().len == 0
    for d in runDirs:
      check not dirExists(d)
      # The swtpm state directory lives inside the run directory, so this
      # also proves no TPM state leaked.
      check not dirExists(d / "tpm")

  test "swtpm dies even when QEMU is SIGKILLed and cannot shut it down":
    # The case that makes the explicit swtpm kill in ``stopAndCleanup``
    # falsifiable at all. On the ordinary path QEMU sends swtpm a
    # CMD_SHUTDOWN over the control channel as it exits, so swtpm goes
    # away whether or not the harness lifts a finger — deleting the kill
    # leaves every clean-path assertion green. It is only when QEMU dies
    # without running its exit handlers that the harness is the only
    # thing that can reap swtpm. A production host that SIGKILLs a
    # runaway VM is exactly that situation.
    let b = newQemuBootBackend(namePrefix = TestNamePrefix)
    let g = requireGuest()
    var extra = initTable[string, string]()
    extra["initrdPath"] = g / "initramfs.gz"
    extra["kernelCmdline"] = "console=ttyS0 panic=1 loglevel=3"
    let vm = b.bootFromMedia(BootMediaSpec(
      name: TestNamePrefix & "sigkill-" & $getCurrentProcessId(),
      kind: bmkKernel,
      mediaPath: g / "kernel",
      cpus: 2, memoryMB: 1024, generation: 0,
      acceleration: baAuto, graphics: bgNone, tpmEnabled: true,
      serialLogPath: artifactDir() / "tpm-sigkill.serial.log",
      extra: extra))
    let swtpmPid = parseInt(vm.extra["swtpmPid"])
    let qemuPid = parseInt(vm.extra["qemuPid"])
    check processAlive(swtpmPid)

    discard kill(Pid(qemuPid), SIGKILL)
    for _ in 0 ..< 60:
      if not processAlive(qemuPid):
        break
      sleep(50)
    check not processAlive(qemuPid)
    # Nothing has asked swtpm to stop, and nothing will unless teardown
    # does it.
    check processAlive(swtpmPid)

    b.stopAndCleanup(vm)
    for _ in 0 ..< 60:
      if not processAlive(swtpmPid):
        break
      sleep(50)
    check not processAlive(swtpmPid)
    check liveSwtpms().len == 0
    check not dirExists(vm.extra["runDir"])
    check not pathExists(vm.extra["tpmSocketPath"])

  test "a setup failure after swtpm started still reaps it":
    # The other path with no QEMU to do the reaping: swtpm is up, QEMU
    # never comes up at all. Only ``bootFromMedia``'s partial-construction
    # guard can clean this up.
    let b = newQemuBootBackend(
      qemuCmd = "/nonexistent/qemu-system-x86_64",
      namePrefix = TestNamePrefix)
    let g = requireGuest()
    var extra = initTable[string, string]()
    extra["initrdPath"] = g / "initramfs.gz"
    let name = TestNamePrefix & "setupfail-" & $getCurrentProcessId()
    var raised = false
    try:
      discard b.bootFromMedia(BootMediaSpec(
        name: name, kind: bmkKernel, mediaPath: g / "kernel",
        cpus: 1, memoryMB: 512, generation: 0,
        acceleration: baTcg, graphics: bgNone, tpmEnabled: true,
        serialLogPath: artifactDir() / "tpm-setupfail.serial.log",
        extra: extra))
    except CatchableError:
      raised = true
    check raised

    for _ in 0 ..< 60:
      if liveSwtpms().len == 0:
        break
      sleep(50)
    check liveSwtpms().len == 0
    check not dirExists(b.runDirFor(name))
    check not pathExists(b.tpmSocketPathFor(name))

  test "a failed run leaves nothing behind either":
    # The path that matters most: an assertion failure, not a clean pass.
    let spec = tpmGuestSpec("teardown-on-failure", tpm = true, steps = @[
      step(MarkerStart, "the guest reached its init"),
      step("VMH-TPM-A-LINE-THIS-GUEST-NEVER-PRINTS",
           "a line the guest never prints", timeoutSec = 10),
    ])
    let r = runBootSmoke(spec)
    check not r.ok

    for _ in 0 ..< 40:
      if liveSwtpms().len == 0 and liveQemus().len == 0:
        break
      sleep(50)

    check liveSwtpms().len == 0
    check liveQemus().len == 0
    check not dirExists(r.runDir)
    # The serial transcript is deliberately NOT inside the run directory,
    # so a failure still leaves the evidence needed to diagnose it.
    check fileExists(r.serialLogPath)
    check MarkerStart in readFile(r.serialLogPath)
