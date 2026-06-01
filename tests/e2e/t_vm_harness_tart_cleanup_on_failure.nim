## e2e_vm_harness_tart_cleanup_on_failure (M2 verification).
##
## Asserts the M0 ``try/finally`` orchestrator runs ``stopAndCleanup``
## on the Tart backend even when the gate's exec command fails with a
## non-zero exit. The post-condition is that the ephemeral VM is gone
## from ``tart list``; no stale ``repro-vm-tart-linux-*`` survives the
## failing run.
##
## We use ``/bin/false`` (always-exit-1) as the gate command. The
## verdict from runGate must be ``FAIL`` (not ``ERROR``), and the
## ephemeral name returned by ``revertToBaseline`` must NOT appear in
## ``tart list`` after the test.
##
## Skips on non-macOS hosts and when ``tart`` / ``sshpass`` aren't on
## PATH.

import std/[options, os, strutils, sugar, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_tart_cleanup_on_failure: macOS host required"
  quit(0)

suite "e2e_vm_harness_tart_cleanup_on_failure":
  test "failing gate still triggers tart stop + delete via finally":
    let b = newTartBackend(guestOs = goLinux)
    if not b.probeAvailability():
      echo "[skip] tart or sshpass missing on PATH"
      skip()
    else:
      let outDir = createTempDir("vmh-tart-cleanup-", "")
      defer: removeDir(outDir)

      b.provisionBaseline(BaselineSpec(
        name: "tart-cleanup-test",
        sourceImage: b.goldenImage,
        guestOs: goLinux, guestArch: gaArm64))

      # Stash the list of VMs before the run so we can diff afterwards.
      let beforeVms = b.listTartVms()

      let envelope = newOutputEnvelope(outDir)
      envelope.logProvision("tart cleanup-on-failure starting")
      let gate = GateSpec(
        name: "tart-cleanup-failure",
        baseline: "tart-cleanup-test",
        env: initTable[string, string](),
        cmd: @["/bin/false"],
        timeoutSec: 30)
      let result = runGate(b, gate, envelope)

      # The gate command exited non-zero so the verdict is FAIL (not ERROR).
      check result.verdict == vFail
      check result.exec.isSome
      check result.exec.get().exitCode != 0

      # The ephemeral VM was deleted by stopAndCleanup. Compare the post-
      # run VM list against the pre-run one: no NEW ephemerals with our
      # prefix should remain.
      let afterVms = b.listTartVms()
      let newOnes = collect(newSeq):
        for v in afterVms:
          if v.startsWith(b.ephemeralPrefix) and v notin beforeVms: v
      check newOnes.len == 0

      # DONE sentinel reports FAIL.
      check fileExists(outDir / "DONE")
      check readFile(outDir / "DONE").strip() == "FAIL"
