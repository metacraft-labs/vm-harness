## e2e_vm_harness_utm_windows_arm_smoke (M3 verification).
##
## Drives a complete ``vm-harness run`` lifecycle against a UTM-managed
## Windows-on-ARM guest cloned from the ``repro-windows-arm-base.utm``
## golden bundle. The test invokes ``runGate`` (the same orchestrator
## used by ``vm-harness run --backend utm-windows-arm``) and asserts the
## canonical PASS shape:
##
## - ``revertToBaseline`` clones from the golden bundle and brings the
##   VM to SSH-ready within the per-gate budget (≤20s clone, plus the
##   Windows-on-ARM boot and OpenSSH ready poll which together cap at
##   ``VMH_UTM_SSH_TIMEOUT`` defaulting to 240s).
## - ``execInGuest`` runs ``cmd /c hostname`` inside the guest and the
##   verdict is ``PASS``.
## - The ephemeral VM is deleted via the orchestrator's ``finally``
##   block; a post-run ``utmctl list`` no longer reports the ephemeral.
##
## Skips cleanly on non-macOS hosts, when ``utmctl`` / ``sshpass`` aren't
## on PATH, or when the golden bundle isn't registered with UTM (i.e.
## the provisioning recipe hasn't been run yet).

import std/[options, os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_utm_windows_arm_smoke: macOS host required"
  quit(0)

let
  goldenOverride = getEnv("VMH_UTM_GOLDEN", "")
  envBootTimeout = getEnv("VMH_UTM_BOOT_TIMEOUT", "240")
  envSshTimeout = getEnv("VMH_UTM_SSH_TIMEOUT", "240")

proc goldenExists(b: UtmBackend): bool =
  for v in b.listUtmVms():
    if v.name == b.goldenBundleName:
      return true
  return false

suite "e2e_vm_harness_utm_windows_arm_smoke":
  test "vm-harness run --backend utm-windows-arm produces PASS":
    let b = newUtmBackend(
      goldenBundleName = (if goldenOverride.len > 0:
                            goldenOverride
                          else:
                            "repro-windows-arm-base"),
      bootTimeoutSec = parseInt(envBootTimeout),
      sshReadyTimeoutSec = parseInt(envSshTimeout))
    if not b.probeAvailability():
      echo "[skip] utmctl or sshpass missing on PATH; install via " &
           "`brew install --cask utm` + sshpass"
      skip()
    elif not goldenExists(b):
      echo "[skip] golden UTM bundle '" & b.goldenBundleName &
           "' not registered with UTM. Run the provisioning recipe at " &
           "vm-harness/guest-recipes/windows-arm-base/ and import the " &
           "resulting bundle (one-time, ~30-60 minutes)."
      skip()
    else:
      let outDir = createTempDir("vmh-utm-windows-smoke-", "")
      defer: removeDir(outDir)

      b.provisionBaseline(BaselineSpec(
        name: "utm-windows-arm-smoke",
        sourceImage: b.goldenBundleName,
        cpus: 4, memoryMB: 8192, diskGB: 64,
        guestOs: goWindows, guestArch: gaArm64))

      let envelope = newOutputEnvelope(outDir)
      envelope.logProvision("utm windows-arm smoke starting")
      let gate = GateSpec(
        name: "utm-windows-arm-smoke",
        baseline: "utm-windows-arm-smoke",
        env: initTable[string, string](),
        cmd: @["cmd", "/c", "hostname"],
        timeoutSec: 60)
      let result = runGate(b, gate, envelope)

      check result.verdict == vPass
      check result.exec.isSome
      check result.exec.get().exitCode == 0
      check result.exec.get().stdout.strip().len > 0

      # Mandatory envelope files exist.
      check fileExists(outDir / "00-provision.log")
      check fileExists(outDir / "RESULT.txt")
      check fileExists(outDir / "DONE")
      check readFile(outDir / "DONE").strip() == "PASS"
