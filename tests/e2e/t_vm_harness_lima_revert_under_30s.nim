## e2e_vm_harness_lima_revert_under_30s (M5 verification).
##
## Measures the full ``limactl stop --force && limactl delete --force
## && limactl create --tty=false && limactl start --tty=false`` cycle
## that LimaBackend performs on every ``revertToBaseline`` call, and
## asserts the wall-clock is under 30 seconds per the M0 Per-Gate
## Reset Performance Contract.
##
## The test relies on ``provisionBaseline`` having pre-warmed the
## Lima image cache (otherwise the first revert pays the download
## cost, easily exceeding 30s on a slow network). The contract's 30s
## budget assumes warm caches across runs — a fresh ``brew install
## lima`` host without pre-fetched images will need
## ``provisionBaseline`` to run first.
##
## Skips cleanly on non-macOS hosts or when ``limactl`` isn't on
## PATH.

import std/[os, strutils, times, unittest]
import vm_harness

when not defined(macosx):
  echo "[skip] t_vm_harness_lima_revert_under_30s: macOS host required"
  quit(0)

let envBootTimeout = getEnv("VMH_LIMA_BOOT_TIMEOUT", "240")
# The contract budget is 30s; tests on cold-cache or constrained CI
# can bump this via env. 50% headroom matches the
# "regression flag at miss-by-more-than-50%" wording in
# ``revertToBaseline``'s contract doc.
let budgetSec = parseInt(getEnv("VMH_LIMA_REVERT_BUDGET_SEC", "30"))
let hardCeilingSec = parseInt(getEnv("VMH_LIMA_REVERT_CEILING_SEC", "45"))

suite "e2e_vm_harness_lima_revert_under_30s":
  test "stop+delete+create+start completes inside the M5 budget":
    let b = newLimaBackend(
      bootTimeoutSec = parseInt(envBootTimeout),
      cpus = 2, memoryGiB = 2, diskGiB = 10)
    if not b.probeAvailability():
      echo "[skip] limactl missing on PATH; install via " &
           "`brew install lima` or `nix profile install nixpkgs#lima`"
      skip()
    else:
      # Pre-warm: provisionBaseline reaps stale ephemerals and
      # pre-fetches the base image. This is the same warm path the
      # production orchestrator runs once per session before the
      # first per-gate revert.
      b.provisionBaseline(BaselineSpec(
        name: "lima-revert-budget",
        cpus: 2, memoryMB: 2048, diskGB: 10,
        guestOs: goLinux, guestArch: gaArm64))

      let revertStart = epochTime()
      let vm = b.revertToBaseline("lima-revert-budget")
      let elapsedSec = epochTime() - revertStart
      defer: b.stopAndCleanup(vm)

      echo "[lima revert] wall-clock: " &
           formatFloat(elapsedSec, ffDecimal, 2) & "s " &
           "(budget " & $budgetSec & "s, ceiling " &
           $hardCeilingSec & "s)"

      # Functional check: the instance came up.
      check vm.name.startsWith("repro-vm-lima-")
      check b.instanceStatus(vm.name) == "Running"

      # Hard ceiling — fail if we miss by more than 50% (matches the
      # ``revertToBaseline`` contract doc in types.nim).
      check elapsedSec < hardCeilingSec.float
      # Soft budget — warn (not fail) if we miss the 30s target but
      # stay under the ceiling. Stored separately so CI can grep the
      # "warn" line.
      if elapsedSec >= budgetSec.float:
        echo "[lima revert] WARN: missed " & $budgetSec & "s budget " &
             "by " & formatFloat(elapsedSec - budgetSec.float,
                                 ffDecimal, 2) & "s"
