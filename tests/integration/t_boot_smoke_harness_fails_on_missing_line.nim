## Falsifiability gate for the boot-smoke harness (``boot_smoke.nim``).
##
## *Why this test is the important one.* Every consumer boot gate built
## on this repository — the ReproOS attestation gates for measured boot,
## UKI assembly, dm-verity root and sealed state among them — asserts by
## matching lines on a guest's serial console through ``runBootSmoke``.
## If that harness could report success without the line ever appearing,
## or could hang until the caller's own timeout instead of failing, then
## every one of those gates would be worthless and would *look* green
## while being so. So the harness is exercised here in both polarities:
##
##  - a positive control: the guest's real, ordered output matches; and
##  - the negative case: a line that the guest never prints is reported
##    as a failure, promptly, in a message that names the pattern.
##
## *The guest.* A 512-byte legacy boot sector written by
## ``writeSyntheticBootDisk``, which programs COM1 and prints three fixed
## markers. It is a real bootable disk executing real machine code under
## real firmware — not a fixture standing in for the thing under test —
## and it reaches its last marker in well under a second. So this gate is
## part of the deterministic ``scripts/run-tests.sh`` catalog and runs
## unconditionally on Linux: no artifact to build, no hypervisor needed
## (QEMU TCG), no opt-in.
##
## *Mocking.* None. A real ``qemu-system-x86_64`` boots a real disk and
## the assertions read the bytes the guest really wrote to COM1.

import std/[os, strutils, times, unittest]
import vm_harness

when not defined(linux):
  # QEMU direct boot is a Linux-host backend here and the boot backend
  # reads ``/proc`` for its process-ownership checks. On Linux this gate
  # never skips: a missing ``qemu-system-x86_64`` is a hard failure,
  # because "the harness could not be tested" must not be reported as
  # "the harness is fine".
  echo "[skip] t_boot_smoke_harness_fails_on_missing_line: " &
    "requires a Linux host (QEMU direct-boot backend)"
  quit(0)

proc scratchDir(stem: string): string =
  getTempDir() / ("vmh-boot-smoke-" & stem & "-" & $getCurrentProcessId())

suite "t_boot_smoke_harness_fails_on_missing_line":
  test "boot-smoke harness matches the guest's real ordered serial sequence":
    let dir = scratchDir("positive")
    createDir(dir)
    defer:
      try: removeDir(dir)
      except CatchableError: discard
    let disk = writeSyntheticBootDisk(dir / "synthetic.raw")

    let r = runBootSmoke(BootSmokeSpec(
      caseName: "positive-control",
      imagePath: disk,
      imageFormat: "raw",
      generation: 1,
      memoryMB: 256,
      cpus: 1,
      acceleration: baTcg,
      steps: syntheticBootSteps(loginTimeoutSec = 60)))

    if not r.ok:
      echo "[diag] ", r.failureMessage
      echo "[diag] serial log: ", r.serialLogPath
      echo serialLogExcerpt(r.serialLogPath)
    check r.ok
    check r.failedStepIndex == -1
    check r.matches.len == 3
    for m in r.matches:
      check m.matched
      check not m.timedOut
    # Ordered, not merely present: each match must have landed after
    # the previous one advanced the cursor.
    check r.matches[0].matchedText.contains(SyntheticStage1Marker)
    check r.matches[1].matchedText.contains(SyntheticStage2Marker)
    check r.matches[2].matchedText.contains("synthetic login: ")
    # The transcript is an artifact on success too, not only on failure.
    check fileExists(r.serialLogPath)
    check getFileSize(r.serialLogPath) > 0
    let transcript = readFile(r.serialLogPath)
    check SyntheticStage1Marker in transcript
    check SyntheticLoginMarker in transcript

  test "boot-smoke harness reports failure naming a line the guest never prints":
    let dir = scratchDir("negative")
    createDir(dir)
    defer:
      try: removeDir(dir)
      except CatchableError: discard
    let disk = writeSyntheticBootDisk(dir / "synthetic.raw")

    const NeverPrinted = "REPRO-BOOT-SMOKE-LINE-THAT-IS-NEVER-PRINTED"
    const MissTimeoutSec = 10

    let started = epochTime()
    let r = runBootSmoke(BootSmokeSpec(
      caseName: "missing-line",
      imagePath: disk,
      imageFormat: "raw",
      generation: 1,
      memoryMB: 256,
      cpus: 1,
      acceleration: baTcg,
      steps: @[
        BootSmokeStep(pattern: SyntheticStage1Marker, timeoutSec: 60,
                      label: "the guest really did boot"),
        BootSmokeStep(pattern: NeverPrinted, timeoutSec: MissTimeoutSec,
                      label: "a line the guest never prints"),
      ]))
    let wallMs = int((epochTime() - started) * 1000)

    # 1. It fails. It does not pass vacuously.
    check not r.ok
    check r.outcome == bsPatternNotSeen

    # 2. It fails at the RIGHT step: the guest's real first line was
    #    matched, and only the impossible one missed. A harness that
    #    matched nothing at all would also be "not ok" while being
    #    just as broken.
    check r.failedStepIndex == 1
    check r.matches.len == 2
    check r.matches[0].matched
    check not r.matches[1].matched
    check r.matches[1].timedOut

    # 3. The message names the line that was not seen, so a future
    #    gate failure is diagnosable without re-running it.
    check NeverPrinted in r.failureMessage
    check "a line the guest never prints" in r.failureMessage
    check ("timeout") in r.failureMessage

    # 4. It is timely: bounded by the per-line timeout it was given,
    #    not by the caller's outer timeout. Generous headroom for a
    #    loaded CI host, but far below "hung".
    check r.matches[1].elapsedMs >= MissTimeoutSec * 1000
    check r.matches[1].elapsedMs < (MissTimeoutSec + 20) * 1000
    check wallMs < (MissTimeoutSec + 60) * 1000

    # 5. The transcript is captured on the failure path too, and it
    #    proves the guest was alive — the miss is about the line, not
    #    about a guest that never started.
    check fileExists(r.serialLogPath)
    let transcript = readFile(r.serialLogPath)
    check SyntheticStage1Marker in transcript
    check NeverPrinted notin transcript

  test "boot-smoke harness refuses an empty expected-line sequence":
    # An assertion list with no assertions in it is the other way a
    # boot gate can be a no-op, so it is refused rather than passed.
    let r = runBootSmoke(BootSmokeSpec(
      caseName: "empty-sequence",
      imagePath: "/nonexistent/image.qcow2",
      steps: @[]))
    check not r.ok
    check r.outcome == bsSetupFailed
    check "asserts nothing" in r.failureMessage
