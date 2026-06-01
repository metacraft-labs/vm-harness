## e2e_vm_harness_tart_macos_smoke (M2 verification).
##
## Drives a complete ``vm-harness run`` lifecycle against a Tart-managed
## macOS guest cloned from the ``ghcr.io/cirruslabs/macos-tahoe-base``
## golden image. The test invokes ``runGate`` (the same orchestrator
## used by ``vm-harness run --backend tart-macos``) and asserts the
## canonical PASS shape: clone the golden, SSH in as admin, run
## ``hostname``, verdict ``PASS``, delete the ephemeral.
##
## *Cost note*: the cirruslabs macOS golden is large (~80 GB unpacked).
## On a fresh CI runner the first ``tart pull`` takes 10+ minutes. The
## test honors ``VMH_TART_SKIP_MACOS=1`` to opt out on space-constrained
## hosts; CI matrices should set ``VMH_TART_PREPULLED_MACOS=1`` after
## a prepare step that runs ``tart pull`` once before the test suite.
##
## Skips cleanly on non-macOS hosts or when ``tart`` / ``sshpass``
## aren't on PATH.

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_tart_macos_smoke: macOS host required"
  quit(0)

suite "e2e_vm_harness_tart_macos_smoke":
  test "vm-harness run --backend tart-macos produces PASS":
    if getEnv("VMH_TART_SKIP_MACOS", "") == "1":
      echo "[skip] VMH_TART_SKIP_MACOS=1 set; macOS golden pull is " &
           "multi-GB and may exceed CI disk budgets"
      skip()
    else:
      let b = newTartBackend(guestOs = goMacos,
                             bootTimeoutSec = 180,
                             sshReadyTimeoutSec = 180)
      if not b.probeAvailability():
        echo "[skip] tart or sshpass missing on PATH"
        skip()
      else:
        let outDir = createTempDir("vmh-tart-macos-smoke-", "")
        defer: removeDir(outDir)

        # The macOS golden pull is slow (multi-GB) on first run; we don't
        # impose a timeout. Once cached, subsequent runs are seconds.
        b.provisionBaseline(BaselineSpec(
          name: "tart-macos-smoke",
          sourceImage: b.goldenImage,
          cpus: 4, memoryMB: 8192, diskGB: 80,
          guestOs: goMacos, guestArch: gaArm64))

        let envelope = newOutputEnvelope(outDir)
        envelope.logProvision("tart macos smoke starting")
        let gate = GateSpec(
          name: "tart-macos-smoke",
          baseline: "tart-macos-smoke",
          env: initTable[string, string](),
          cmd: @["hostname"],
          timeoutSec: 60)
        let result = runGate(b, gate, envelope)

        check result.verdict == vPass
        check result.exec.isSome
        check result.exec.get().exitCode == 0
        check result.exec.get().stdout.strip().len > 0

        check fileExists(outDir / "00-provision.log")
        check fileExists(outDir / "RESULT.txt")
        check fileExists(outDir / "DONE")
        check readFile(outDir / "DONE").strip() == "PASS"
