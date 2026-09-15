## Runner-Fleet-M3-ARM-Wave MA4 gate: ``t_qemu_windows_arm_per_job_boot``
## — HOST TIER. Boots an EXISTING Windows-ARM golden through the exact path a
## CI job uses — ``provisionBaseline`` -> ``revertToBaseline`` ->
## ``execInGuest`` -> ``stopAndCleanup`` — and requires it to work.
##
## WHY THIS FILE EXISTS, and it is the most useful thing in it. On 2026-09-15
## the per-job argument vector could not boot a generalized golden at all:
## it passed ``-no-reboot``, a ``/generalize``d image MUST reboot once between
## its specialize and oobeSystem passes, ``sshd`` is started by the
## ``FirstLogonCommands`` that run AFTER that reboot, so QEMU exited rc=0
## about 38 seconds in and every instance died. That defect was in HEAD and in
## the vector deployed on m3, and THREE review passes certified "the per-job
## argv is byte-identical to HEAD" as a safety property — which it was, and it
## was also byte-identically unbootable.
##
## The unit tier asserts the ARGV. It now models the mandatory reboot too, so
## it can catch a straight regression of that flag. What it cannot do is say
## that a real Windows guest reaches sshd, that HVF tolerated the reset, or
## that the runtime transition back to one-shot reboot semantics really lands
## in QEMU. Only a real boot can, and until this file there was no gate that
## took one: MA3's ``t_qemu_windows_arm_golden_build_host`` does reach
## ``revertToBaseline``, but it has never been run (there is no
## ``test-logs/test-host.log`` on m3) and a single run of it is a ~60 minute
## Windows install.
##
## So this gate is deliberately CHEAP: it consumes a golden that already
## exists and takes about two minutes. It is the gate that should have caught
## the defect, and the one to run after any change to
## ``buildQemuWindowsArmArgs``, ``waitForFirstBootSshReady`` or
## ``revertToBaseline``.
##
## THIS TEST NEVER PASSES QUIETLY. Every precondition it lacks is named, with
## the environment variable that supplies it.
##
## Preconditions:
##
##   a macOS aarch64 host with qemu-system-aarch64, swtpm and sshpass
##   a finished golden directory (``windows.qcow2`` + ``golden-manifest.json``)
##
## The golden is located in this order:
##
##   VMH_WINDOWS_ARM_GOLDEN=<dir>   an explicit golden directory
##   <state dir>/golden/win-arm-runner   the promoted pointer
##
## where ``<state dir>`` is ``VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR`` or the
## per-user default. On m3 that pointer is
## ``/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner``.
##
## MOCKING NOTE (workspace policy). Nothing is mocked. Real QEMU, real swtpm,
## real OpenSSH into a real Windows guest, the real backend methods.

import std/[os, strutils, tables, unittest]
import vm_harness

const
  GoldenEnv = "VMH_WINDOWS_ARM_GOLDEN"

proc candidateGolden(): string =
  if getEnv(GoldenEnv).len > 0:
    return getEnv(GoldenEnv)
  defaultStateDir() / "golden" / "win-arm-runner"

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
      discard requireWindowsArmGolden(golden)
    except ValueError as e:
      result.add(golden & " is not a finished golden: " & e.msg)

suite "t_qemu_windows_arm_per_job_boot (host tier)":

  test "the per-job path boots a generalized golden and runs a command":
    let golden = candidateGolden()
    let missing = missingPreconditions(golden)
    if missing.len > 0:
      echo "[skip] t_qemu_windows_arm_per_job_boot (host tier) needs:"
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
      echo "[t_qemu_windows_arm_per_job_boot] golden: " & resolved

      # The golden is IMMUTABLE. Recording its digest before and after is not
      # ceremony: every instance boots from a qcow2 overlay whose backing file
      # is this disk, and a write-through would corrupt every other live
      # instance with no error anywhere.
      let diskBefore = fileSha256(resolved / QwaBaseDiskName)

      b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                       sourceImage: resolved))

      # Two instances, because the SID half of MA3's gate needs two and
      # because a second instance is the only way to see that the first one's
      # teardown left the golden usable.
      var sids: seq[string] = @[]
      var instanceDirs: seq[string] = @[]
      for i in 1 .. 2:
        let vm = b.revertToBaseline("win-arm-runner")
        let vmDir = vm.extra["vmDir"]
        instanceDirs.add(vmDir)
        try:
          # THE ASSERTION THIS GATE EXISTS FOR: SSH was reached at all. With
          # -no-reboot on the argv, revertToBaseline raised
          # GuestBootFailureError here after the whole sshReadyTimeoutSec.
          echo "[t_qemu_windows_arm_per_job_boot] instance " & $i &
               ": ssh ready after " & vm.extra["sshReadySec"] & "s, " &
               vm.extra["firmwareBoots"] & " firmware boot(s)"

          # The guest really did reboot on the way up, and the harness saw
          # it. Two banners is what a generalized golden's first boot costs;
          # anything less means the image was not generalized and the SID
          # assertion below would be passing for the wrong reason.
          let boots = parseInt(vm.extra["firmwareBoots"])
          check boots >= 2
          check boots <= QwaFirstBootMaxFirmwareBoots

          # A real command, answered verbatim.
          let r = b.execInGuest(vm, initTable[string, string](),
                                @["cmd.exe", "/c", "echo MA4-PER-JOB-PROOF"],
                                timeoutSec = 120)
          check r.exitCode == 0
          check "MA4-PER-JOB-PROOF" in r.stdout

          # And arithmetic, so a guest that merely echoes its argument cannot
          # look like a guest that ran anything.
          let calc = b.execInGuest(vm, initTable[string, string](),
                                   @["cmd.exe", "/c", "set /a 6*7"],
                                   timeoutSec = 120)
          check calc.exitCode == 0
          check "42" in calc.stdout

          # ONE-SHOT REBOOT SEMANTICS ARE BACK. The argv started this guest
          # rebootable so it could finish its oobeSystem pass; by the time a
          # job could run on it, a guest-initiated reboot must END the guest
          # instead of restarting it. The handle says the transition
          # happened, and the QMP socket it names must still be there for an
          # operator to check.
          check vm.extra["rebootAction"] == QwaOneShotRebootAction
          check vm.extra["qmpSocket"] == qwaQmpSocketPath(vmDir)
          # Idempotent re-assertion against the LIVE guest: if QMP were not
          # actually reachable, the transition in revertToBaseline could not
          # have landed either.
          let again = setQemuRebootAction(vm.extra["qmpSocket"],
                                          QwaOneShotRebootAction)
          check again.ok

          let sid = b.execInGuest(vm, initTable[string, string](),
                                  @["cmd.exe", "/c", "whoami /user"],
                                  timeoutSec = 120)
          check sid.exitCode == 0
          for token in sid.stdout.splitWhitespace():
            if token.toUpperAscii().startsWith("S-1-5-21-"):
              sids.add(machineSidFromUserSid(token))
              break
        finally:
          b.stopAndCleanup(vm, deleteVm = true)

      # /generalize really re-minted the machine SID, measured on two
      # independent instances of the same golden.
      echo "[t_qemu_windows_arm_per_job_boot] machine SIDs: " &
           sids.join(", ")
      check sids.len == 2
      check sids[0].len > 0
      check sids[0] != sids[1]

      # Teardown left nothing behind...
      for d in instanceDirs:
        check not dirExists(d)
      # ...and the golden is untouched, so the next instance and every live
      # overlay still have the disk they were promised.
      check fileSha256(resolved / QwaBaseDiskName) == diskBefore
