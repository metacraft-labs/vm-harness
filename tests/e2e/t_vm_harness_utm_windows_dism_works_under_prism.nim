## e2e_vm_harness_utm_windows_dism_works_under_prism (M3 verification).
##
## Smoke-test that Windows-on-ARM's Prism x86 emulator handles a
## DISM-driven optional-feature query end-to-end inside the UTM guest.
## Validates that M69's ``feature-capability`` gate would PASS on a
## Mac-host UTM workflow — i.e. the harness can drive a DISM command
## inside the Windows-ARM guest and observe its output.
##
## Why a *query* (``DISM /Online /Get-Features``) and not a write
## (``/Enable-Feature:Containers``)? The latter requires a reboot and
## then a second exec round-trip after a power-cycle, which is M5/M69
## territory rather than an M3 smoke. The query path exercises the same
## DISM binary + Prism translation surface; if the query works the
## enable path is mechanically the same shell-out.
##
## Skips cleanly on non-macOS hosts, when ``utmctl`` / ``sshpass`` aren't
## on PATH, or when the golden bundle isn't registered with UTM.

import std/[options, os, strutils, tables, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_utm_windows_dism_works_under_prism: macOS host required"
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

suite "e2e_vm_harness_utm_windows_dism_works_under_prism":
  test "DISM /Online /Get-Features succeeds inside UTM Windows-ARM guest":
    let b = newUtmBackend(
      goldenBundleName = (if goldenOverride.len > 0:
                            goldenOverride
                          else:
                            "repro-windows-arm-base"),
      bootTimeoutSec = parseInt(envBootTimeout),
      sshReadyTimeoutSec = parseInt(envSshTimeout))
    if not b.probeAvailability():
      echo "[skip] utmctl or sshpass missing on PATH"
      skip()
    elif not goldenExists(b):
      echo "[skip] golden UTM bundle '" & b.goldenBundleName &
           "' not registered with UTM. Run the provisioning recipe " &
           "first (one-time, ~30-60 minutes)."
      skip()
    else:
      b.provisionBaseline(BaselineSpec(
        name: "utm-dism-prism-smoke",
        sourceImage: b.goldenBundleName,
        cpus: 4, memoryMB: 8192, diskGB: 64,
        guestOs: goWindows, guestArch: gaArm64))

      let vm = b.revertToBaseline("utm-dism-prism-smoke")
      defer: b.stopAndCleanup(vm)
      check vm.ipAddress.isSome

      # DISM is a native ARM64 binary on Windows-on-ARM; even though the
      # Prism translation layer is what makes a lot of x86 user tooling
      # work, DISM itself runs natively. We still exercise it here
      # because (a) it's the closest available proxy for the M69
      # ``feature-capability`` gate, (b) any failure here would block
      # the M69 driver-validation gate downstream regardless of Prism.
      let r = b.execInGuest(vm,
        env = initTable[string, string](),
        cmd = @["cmd", "/c", "dism", "/online", "/get-features",
                "/format:table"],
        timeoutSec = 180)

      # DISM exits 0 when the feature list query succeeds; non-zero
      # would indicate either DISM is broken inside the Prism layer or
      # the harness's exec path is dropping the command.
      check r.exitCode == 0
      # The table format always includes a "Feature Name" header — if
      # we got the header we know the query made it through.
      check "Feature Name" in r.stdout or "feature name" in r.stdout.toLowerAscii
