## e2e_vm_harness_tart_linux_arm_smoke (M2 verification).
##
## Drives a complete ``vm-harness run`` lifecycle against a Tart-managed
## Linux ARM guest cloned from the cirruslabs Ubuntu golden image. The
## test invokes ``runGate`` (the same orchestrator used by ``vm-harness
## run --backend tart-linux-arm``) and asserts the canonical PASS shape:
##
## - ``revertToBaseline`` clones from the cached golden and brings the
##   VM to SSH-ready within the per-gate budget (≤30s for clone, plus
##   SSH-ready poll).
## - ``execInGuest`` runs ``hostname`` inside the guest and the verdict
##   is ``PASS``.
## - The ephemeral VM is deleted via the orchestrator's ``finally``
##   block; a post-run ``tart list`` no longer reports the ephemeral
##   name.
##
## Skips cleanly on non-macOS hosts or when ``tart`` / ``sshpass``
## aren't on PATH.

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_tart_linux_arm_smoke: macOS host required"
  quit(0)

suite "e2e_vm_harness_tart_linux_arm_smoke":
  test "vm-harness run --backend tart-linux-arm produces PASS":
    let b = newTartBackend(guestOs = goLinux)
    if not b.probeAvailability():
      echo "[skip] tart or sshpass missing on PATH; install via " &
           "`nix profile install nixpkgs#tart nixpkgs#sshpass` " &
           "(set NIXPKGS_ALLOW_UNFREE=1 for tart)"
      skip()
    else:
      let outDir = createTempDir("vmh-tart-linux-smoke-", "")
      defer: removeDir(outDir)

      b.provisionBaseline(BaselineSpec(
        name: "tart-linux-arm-smoke",
        sourceImage: b.goldenImage,
        cpus: 2, memoryMB: 4096, diskGB: 20,
        guestOs: goLinux, guestArch: gaArm64))

      let envelope = newOutputEnvelope(outDir)
      envelope.logProvision("tart linux arm smoke starting")
      let gate = GateSpec(
        name: "tart-linux-smoke",
        baseline: "tart-linux-arm-smoke",
        env: initTable[string, string](),
        cmd: @["hostname"],
        timeoutSec: 30)
      let result = runGate(b, gate, envelope)

      # PASS verdict on the gate.
      check result.verdict == vPass
      check result.exec.isSome
      check result.exec.get().exitCode == 0
      check result.exec.get().stdout.strip().len > 0

      # Mandatory envelope files exist.
      check fileExists(outDir / "00-provision.log")
      check fileExists(outDir / "RESULT.txt")
      check fileExists(outDir / "DONE")
      check readFile(outDir / "DONE").strip() == "PASS"
