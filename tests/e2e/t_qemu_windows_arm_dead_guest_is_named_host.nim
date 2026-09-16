## Runner-Fleet-M3-ARM-Wave MA8 gate:
## ``t_qemu_windows_arm_dead_guest_is_named`` — HOST TIER. Boots a REAL
## Windows-ARM golden with the KNOWN REPRODUCER on the argv and requires the
## harness to report a dead QEMU as a dead QEMU, in seconds.
##
## THE BEFORE NUMBER, which is the whole point of this file. MA4's review
## restored ``-no-reboot`` to production code and re-ran
## ``t_qemu_windows_arm_per_job_boot`` on m3 on 2026-09-16. The gate failed
## correctly — but it took **5 minutes 38 seconds** against 3m13s for a healthy
## run, and the message it produced still LED with SSH:
##
##   GuestBootFailureError: SSH did not become ready on 127.0.0.1:2223 within
##   300s (the guest's firmware started 1 time(s); a healthy first boot of a
##   generalized golden shows two)
##
## QEMU had exited about 38 seconds in. Everything after that was the harness
## polling a port nobody was listening on, because nothing on the run path ever
## consulted the pid it had just been handed. This gate measures the same
## reproducer with the liveness check in place and requires SECONDS.
##
## WHY THE REPRODUCER IS BUILT HERE RATHER THAN SHIPPED. ``-no-reboot`` is gone
## from the production per-job vector (MA4) and must stay gone. So this file
## reconstructs the PRE-MA4 vector FROM the shipped one — drop ``-action
## reboot=…`` and ``-qmp …``, add ``-no-reboot`` — which keeps the reproducer
## honest (every other token is whatever production emits today) and keeps
## production code untouched. A ``/generalize``d golden MUST reboot once
## between its specialize and oobeSystem passes, so that vector makes a REAL
## QEMU exit rc=0 on a REAL guest. Nothing is simulated.
##
## THIS TEST NEVER PASSES QUIETLY. Every precondition it lacks is named, with
## the environment variable that supplies it.
##
## Preconditions:
##
##   a macOS aarch64 host with qemu-system-aarch64 and swtpm
##   a finished golden directory (``windows.qcow2`` + ``golden-manifest.json``)
##   read access to the golden's firmware files — in practice this means root
##     on m3, where ``QEMU_VARS.fd`` is mode 0600 root (MA4 ``:status22:(c)``)
##
## The golden is located in this order:
##
##   VMH_WINDOWS_ARM_GOLDEN=<dir>   an explicit golden directory
##   <state dir>/golden/win-arm-runner   the promoted pointer
##
## MOCKING NOTE (workspace policy). Nothing is mocked. Real QEMU, real swtpm, a
## real overlay of a real golden, the real wait the run path uses.

import std/[os, strutils, tables, times, unittest]
import vm_harness

const
  GoldenEnv = "VMH_WINDOWS_ARM_GOLDEN"
  DeadGuestBudgetSec = 120.0
    ## The measured pre-MA8 failure on this exact reproducer was 338s against
    ## a 300s SSH deadline. The check needs about one poll interval after the
    ## exit — on m3 that is ~40s total, dominated by the guest's own ~38s run
    ## to the reboot it is forbidden. 120s is a generous ceiling that is still
    ## nowhere near the deadline, so a REMOVED check cannot pass this.

proc candidateGolden(): string =
  if getEnv(GoldenEnv).len > 0:
    return getEnv(GoldenEnv)
  defaultStateDir() / "golden" / "win-arm-runner"

proc readable(path: string): bool =
  try:
    let f = open(path, fmRead)
    f.close()
    true
  except IOError, OSError:
    false

proc missingPreconditions(golden: string): seq[string] =
  ## Every unmet precondition, named. Collected rather than short-circuited so
  ## one run tells the operator everything that is missing.
  when not defined(macosx):
    result.add("a macOS host (this gate drives qemu-system-aarch64 under " &
               "HVF; the Linux equivalent is the libvirt path)")
  when not (defined(arm64) or defined(arm)):
    result.add("an aarch64 host (a Windows ARM64 guest cannot run under " &
               "HVF on x86_64)")
  if not dirExists(golden):
    result.add("a Windows-ARM golden directory. Looked at " & golden &
               ". Set " & GoldenEnv & "=<dir> to name one explicitly, or " &
               "promote one onto <state dir>/golden/win-arm-runner (MA4's " &
               "pointer flip). Build one with " &
               "tests/e2e/t_qemu_windows_arm_golden_build_host.nim")
  else:
    try:
      let resolved = requireWindowsArmGolden(golden)
      # MA4's review found the sibling host gate dies with a raw OSError from
      # copyFirmwareAndTpm when it is run as a non-root operator, which reads
      # like a broken test rather than a missing precondition. Announce it
      # here, where every other precondition announces itself.
      for f in ["QEMU_VARS.fd", "QEMU_EFI.fd", QwaBaseDiskName]:
        if fileExists(resolved / f) and not readable(resolved / f):
          result.add("read access to " & (resolved / f) & " (it is mode 0600 " &
                     "root on m3, so run this gate under sudo)")
    except ValueError as e:
      result.add(golden & " is not a finished golden: " & e.msg)
  # The golden is not the only root-owned thing on the path. MEASURED in this
  # gate's review 2026-09-16, against a golden copy that HAD been made
  # readable: the run got past every check above and then died
  # ``Unhandled exception: QemuWindowsArmBackend: cannot open port allocation
  # lock <state dir>/.qemu-port-allocation.lock [OSError]`` inside
  # ``startQemuWithAllocatedPortUsing`` — the same "a [FAILED] that looks like
  # a broken test rather than a missing precondition" shape the loop above was
  # written to remove, one file further along. It is mode 0600 root on m3
  # because the deployed service created it.
  let portLock = defaultStateDir() / ".qemu-port-allocation.lock"
  if fileExists(portLock) and not readable(portLock):
    result.add("read access to " & portLock & " (the SSH-port allocation " &
               "lock; the deployed service created it mode 0600 root, so " &
               "run this gate under sudo)")

proc preMa4PerJobArgs(vmDir: string, sshPort: int): seq[string] =
  ## The per-job vector as it stood BEFORE MA4, reconstructed from the vector
  ## production emits today so that only the reproducer differs.
  let shipped = buildQemuWindowsArmArgs(vmDir, sshPort)
  var i = 0
  while i < shipped.len:
    if shipped[i] == "-action" or shipped[i] == "-qmp":
      i += 2      # drop the flag and its value
      continue
    result.add(shipped[i])
    inc i
  result.add("-no-reboot")

suite "t_qemu_windows_arm_dead_guest_is_named (host tier)":

  test "a QEMU that exits is reported as a dead process, in seconds":
    let golden = candidateGolden()
    let missing = missingPreconditions(golden)
    if missing.len > 0:
      echo "[skip] t_qemu_windows_arm_dead_guest_is_named (host tier) needs:"
      for m in missing:
        echo "         - " & m
      echo "       Nothing was booted and nothing was asserted. This is a " &
           "SKIP, not a pass."
      skip()
    else:
      let b = QemuWindowsArmBackend(newBackend(biQemuWindowsArm))
      doAssert b.probeAvailability(),
        "qemu-system-aarch64, swtpm or sshpass is missing from PATH"

      let resolved = requireWindowsArmGolden(golden)
      echo "[t_qemu_windows_arm_dead_guest_is_named] golden: " & resolved

      # The golden is IMMUTABLE: every instance boots from an overlay whose
      # backing file is this disk, and a write-through would corrupt every
      # other live instance with no error anywhere.
      let diskBefore = fileSha256(resolved / QwaBaseDiskName)

      let name = ephemeralName(b.ephemeralPrefix,
                               int64(epochTime() * 1000),
                               getCurrentProcessId())
      let vmDir = ephemeralDirFor(b.stateDir, name)
      b.createEphemeralInstance(resolved, vmDir)
      b.acquireInstanceLock(name, vmDir)
      let swtpmPid = b.startSwtpmInBackground(vmDir)
      let started = b.startQemuWithAllocatedPortUsing(vmDir,
        proc (port: int): seq[string] = preMa4PerJobArgs(vmDir, port))

      var vm = VmHandle(backend: b, name: name, baseline: "win-arm-runner",
                        extra: {"vmDir": vmDir, "qemuPid": $started.pid,
                                "swtpmPid": $swtpmPid}.toTable)
      try:
        # THE PRODUCTION WAIT, at the PRODUCTION deadline. Shortening
        # sshReadyTimeoutSec here would prove nothing: the claim under test is
        # that the failure arrives long before it.
        let t0 = epochTime()
        let outcome = b.waitForFirstBootSshReady(
          started.sshPort, b.sshReadyTimeoutSec,
          vmDir / QwaSerialLogName, qemuPid = started.pid)
        let elapsed = epochTime() - t0
        echo "[t_qemu_windows_arm_dead_guest_is_named] outcome " &
             $outcome.outcome & " after " & $int(elapsed) & "s of a " &
             $b.sshReadyTimeoutSec & "s SSH deadline; " &
             describeChildExit(outcome.qemuExit) & "; firmware boots " &
             $outcome.firmwareBoots
        echo "[t_qemu_windows_arm_dead_guest_is_named] BEFORE MA8 the same " &
             "reproducer took 5m38s and reported \"SSH did not become ready\""

        # IT IS THE PROCESS, NAMED AS THE PROCESS.
        check outcome.outcome == fbQemuExited
        # ...and it really did exit on its own, cleanly, which is what made
        # the pre-MA8 message so misleading: nothing had crashed.
        check outcome.qemuExit.exited
        if outcome.qemuExit.statusKnown:
          check outcome.qemuExit.termSignal == 0

        # IN SECONDS, NOT AT THE DEADLINE.
        check elapsed < DeadGuestBudgetSec
        check elapsed < b.sshReadyTimeoutSec.float

        # AND THE FIRMWARE-BOOT BOUND COULD NOT HAVE CAUGHT IT. MEASURED on m3
        # for this exact vector: exactly ONE banner, then silence. A process
        # that exits leaves the count FROZEN, which is why MA4's review was
        # right that the banner counter is not a substitute.
        check outcome.firmwareBoots == 1
        check outcome.firmwareBoots <= QwaFirstBootMaxFirmwareBoots

        # AND THE DIAGNOSTICS THE MESSAGE NAMES SURVIVE THE REAP. The pre-MA8
        # failure text pointed at <vmDir>/serial.log, which `stopAndCleanup`
        # had just deleted. This is the same call `revertToBaseline` makes on
        # its failure path, against a REAL instance directory with a REAL
        # EDK2 serial log in it. (The message itself is asserted at the unit
        # tier: making the production per-job path fail would mean shipping
        # the reproducer, which is exactly what MA4 undid.)
        let diagDir = retainFailedBootDiagnostics(b.stateDir, name, vmDir)
        check diagDir.len > 0
        check fileExists(diagDir / QwaSerialLogName)
        check QwaFirmwareBannerMarker in readFile(diagDir / QwaSerialLogName)
        check fileExists(diagDir / "qemu.log")
        check "Diagnostics retained in " in qwaPerJobDiagnostics(diagDir)
        echo "[t_qemu_windows_arm_dead_guest_is_named] diagnostics: " & diagDir
      finally:
        b.stopAndCleanup(vm, deleteVm = true)

      check not dirExists(vmDir)
      check fileSha256(resolved / QwaBaseDiskName) == diskBefore

      # The production vector is NOT the reproducer, asserted here so this
      # file can never be read as evidence that -no-reboot came back.
      let shipped = buildQemuWindowsArmArgs(vmDir, 2223)
      check "-no-reboot" notin shipped
      check "-action" in shipped
