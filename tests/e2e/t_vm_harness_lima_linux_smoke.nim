## e2e_vm_harness_lima_linux_smoke (M5 verification).
##
## Drives a complete ``vm-harness run`` lifecycle against a Lima-
## managed Ubuntu Linux guest. The test invokes ``runGate`` (the same
## orchestrator used by ``vm-harness run --backend lima``) and
## asserts the canonical PASS shape:
##
## - ``revertToBaseline`` creates a fresh Lima instance via
##   ``limactl create + start`` (no native snapshot — full lifecycle
##   every revert).
## - ``execInGuest`` runs ``hostname`` inside the guest via
##   ``limactl shell`` and the verdict is ``PASS``.
## - The ephemeral instance is deleted via the orchestrator's
##   ``finally`` block; a post-run ``limactl ls`` no longer reports
##   the ephemeral name.
##
## Skips cleanly on non-macOS hosts or when ``limactl`` isn't on
## PATH.

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_lima_linux_smoke: macOS host required"
  quit(0)

let envBootTimeout = getEnv("VMH_LIMA_BOOT_TIMEOUT", "240")

suite "e2e_vm_harness_lima_linux_smoke":
  test "vm-harness run --backend lima produces PASS":
    let b = newLimaBackend(
      bootTimeoutSec = parseInt(envBootTimeout),
      cpus = 2, memoryGiB = 2, diskGiB = 10)
    if not b.probeAvailability():
      echo "[skip] limactl missing on PATH; install via " &
           "`brew install lima` or `nix profile install nixpkgs#lima`"
      skip()
    else:
      let outDir = createTempDir("vmh-lima-smoke-", "")
      defer: removeDir(outDir)

      b.provisionBaseline(BaselineSpec(
        name: "lima-linux-smoke",
        cpus: 2, memoryMB: 2048, diskGB: 10,
        guestOs: goLinux, guestArch: gaArm64))

      let envelope = newOutputEnvelope(outDir)
      envelope.logProvision("lima linux smoke starting")
      let gate = GateSpec(
        name: "lima-linux-smoke",
        baseline: "lima-linux-smoke",
        env: initTable[string, string](),
        cmd: @["hostname"],
        timeoutSec: 60)
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

      # The ephemeral instance should have been cleaned up.
      for name in b.listLimaInstances():
        check not name.startsWith("repro-vm-lima-")
