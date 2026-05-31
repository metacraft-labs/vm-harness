## e2e_vm_harness_hyperv_m69_feature_capability_passes (M1 verification).
##
## *STATUS: pending* — this test verifies that driving the M69
## ``feature-capability`` gate through the new HyperVBackend produces
## the same PASS verdict and output artifacts as the legacy direct
## invocation of ``run-hyperv-m69-system.ps1``. The test requires:
##
## - A Windows host with Hyper-V enabled.
## - The M69 base VM (``repro-m69-hyperv``) already provisioned and
##   carrying the ``base-clean`` snapshot.
## - Reprobuild's ``tools/hyperv-m69-system/run-hyperv-m69-system.ps1``
##   present at the path supplied via ``$VMH_HYPERV_RUN_SCRIPT`` (or the
##   harness's hard-coded default).
## - The gate exe (``e2e_windows_optional_feature_and_capability.exe``)
##   already built into ``D:\metacraft\reprobuild\build\test-bin\``.
##
## On non-Windows hosts the test exits early. The test is part of the
## M1 deliverable but its actual pass/fail can only be observed on a
## properly-configured Windows host; the milestone file records this
## as ``status: pending``.

import std/[os, tempfiles, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_m69_feature_capability_passes: " &
       "Windows host required"
  quit(0)

suite "e2e_vm_harness_hyperv_m69_feature_capability_passes":
  test "feature-capability gate via HyperVBackend reaches PASS":
    let runScript = getEnv("VMH_HYPERV_RUN_SCRIPT",
                          "D:\\metacraft\\reprobuild\\tools\\" &
                          "hyperv-m69-system\\run-hyperv-m69-system.ps1")
    let provisionScript = getEnv("VMH_HYPERV_PROVISION_SCRIPT",
                                 "D:\\metacraft\\reprobuild\\tools\\" &
                                 "hyperv-m69-system\\provision-base-vm.ps1")
    let credPath = getEnv("VMH_HYPERV_CRED_XML",
                          getHomeDir() / "AppData" / "Local" /
                          "Repro" / "hyperv-m69" / "vm-cred.xml")

    let backend = newHyperVBackend(
      vmName = "repro-m69-hyperv",
      credentialCachePath = credPath,
      runScriptPath = runScript,
      provisionScriptPath = provisionScript,
      defaultGateTimeoutMinutes = 30)

    let outDir = createTempDir("vmh-hyperv-fc-", "")

    let result = backend.runViaReproScript(
      gate = "feature-capability",
      scenario = "base-clean",
      outDir = outDir,
      gateTimeoutMinutes = 30)

    check result.done
    check result.verdict.kind == svPass
    check fileExists(outDir / "feature-capability-base-clean" / "RESULT.txt") or
          fileExists(outDir / "RESULT.txt")
    check fileExists(outDir / "feature-capability-base-clean" / "DONE") or
          fileExists(outDir / "DONE")
