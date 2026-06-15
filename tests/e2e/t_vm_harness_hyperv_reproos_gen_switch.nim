## e2e_vm_harness_hyperv_reproos_gen_switch
##
## D2 P6 acceptance gate: generation switch demonstration on ReproOS.
##
## Scenario (per campaign spec § D2 P6):
##
##   1. Apply config v1 with git from snapshot A → reboot → verify
##      ``git --version`` reports the snapshot-A banner.
##   2. Apply config v2 with git from snapshot B → reproos-rebuild
##      switch → reboot → verify the snapshot-B banner.
##   3. ``reproos-rebuild rollback`` → reboot → verify snapshot-A
##      again, demonstrating B3's switch + rollback against a real
##      foreign-package change.
##
## Required artifacts:
##
##   * reproos-mvp-gen-a.iso — built from a config that pins
##     ``git@debian/bookworm:20260601T000000Z`` (snapshot A; the same
##     pin D1 uses).
##   * reproos-mvp-gen-b.iso — built from a config that pins
##     ``git@debian/bookworm:20260901T000000Z`` (snapshot B; bumped
##     three months forward).
##
## The test invokes the B3 ``reproos-rebuild`` subcommands (``apply``,
## ``switch``, ``rollback``) from the serial console. Each "reboot" is
## implemented by ``reproos-rebuild switch`` + ``systemctl reboot``
## with the same Hyper-V VM (persistent state lives on the VHD attached
## as ``/var/lib/reproos``).
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * Either generation ISO is absent.
##   * The persistent state VHD path is absent.
##
## Honest scope: the D1 + D2 build drivers stop at overlay assembly by
## default; the ISO + persistent-VHD artifacts require the R9 systemd
## install tree on the build host. This test is the contract-driver;
## the build-host-side artifact production is a follow-up.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_gen_switch: Windows host required"
  quit(0)

const
  DefaultIsoGenA = r"D:\metacraft\reprobuild\build\d2-mvp-gen-a\reproos-mvp-gen-a.iso"
  DefaultIsoGenB = r"D:\metacraft\reprobuild\build\d2-mvp-gen-b\reproos-mvp-gen-b.iso"
  DefaultStateVhd = r"D:\metacraft\reprobuild\build\d2-mvp-gen-state.vhdx"

  TotalDeadlineSec = 180
  BootStageTimeout = 90
  LoginTimeout     = 60
  CmdTimeout       = 30

  # Banner regex patterns the test asserts after each phase.
  GenABanner = r"git version 1:2\.39\.5"
  # Snapshot B's git version is intentionally one minor bump so the
  # test can prove the rollback flipped the bytes back. The exact
  # version depends on what debian/bookworm rolled in 20260901; we
  # accept any 2.39.<rev> that is NOT 2.39.5 to keep the assertion
  # forgiving of point-release drift.
  GenBBanner = r"git version 1:2\.39\.([6-9]|1[0-9])"

proc isElevated(): bool =
  let cmd = @["powershell.exe", "-NoLogo", "-NoProfile",
              "-ExecutionPolicy", "Bypass", "-Command",
              "try { $null = Get-VMHost -ErrorAction Stop; exit 0 } " &
              "catch { exit 1 }"]
  try:
    let p = startProcess(cmd[0], args = cmd[1 .. ^1],
                         options = {poUsePath, poStdErrToStdOut})
    let code = p.waitForExit(timeout = 30 * 1000)
    p.close()
    return code == 0
  except CatchableError:
    return false

proc findArtifact(envName, default: string): string =
  let envOverride = getEnv(envName)
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(default):
    return default
  return ""

# ---------------------------------------------------------------------------
# Login + reboot helpers shared with the multi-distro test.
# ---------------------------------------------------------------------------

proc awaitLogin(backend: HyperVBackend; serial: SerialStream) =
  let kernelBanner = backend.expectLine(serial, r"Linux version",
    timeoutSec = BootStageTimeout)
  check kernelBanner.matched
  let pid1 = backend.expectLine(serial, r"systemd\[1\]:",
    timeoutSec = BootStageTimeout)
  check pid1.matched
  let login = backend.expectLine(serial,
    r"(reproos.*login:|root@reproos|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if login.matched and login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ #|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      backend.serialSend(serial, "root\n")
      discard backend.expectLine(serial,
        r"(password|Password|\$|#)", timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)",
        timeoutSec = LoginTimeout)

proc runShellWithSentinel(backend: HyperVBackend;
                          serial: SerialStream;
                          tag, cmd, pattern: string): bool =
  let before = "D2GS_BEGIN_" & tag
  let after = "D2GS_END_" & tag
  backend.serialSend(serial,
    "echo " & before & " && " & cmd & " && echo " & after & "\n")
  let resp = backend.expectLine(serial, pattern, timeoutSec = CmdTimeout)
  return resp.matched

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_gen_switch":
  test "D2 P6: generation switch + rollback flips git bytes":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-d2-gen-switch-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let isoA = findArtifact("D2_GEN_A_ISO", DefaultIsoGenA)
      let isoB = findArtifact("D2_GEN_B_ISO", DefaultIsoGenB)
      let stateVhd = findArtifact("D2_GEN_STATE_VHD", DefaultStateVhd)
      if isoA.len == 0 or isoB.len == 0 or stateVhd.len == 0:
        echo "[skip] D2 P6 artifacts missing:"
        echo "  gen-A ISO:   ", DefaultIsoGenA
        echo "  gen-B ISO:   ", DefaultIsoGenB
        echo "  state VHD:   ", DefaultStateVhd
        echo "  (override via D2_GEN_A_ISO, D2_GEN_B_ISO, D2_GEN_STATE_VHD)"
        echo "Build via the build-mvp-multi-iso.sh driver with two"
        echo "different MVP_CONFIG_PATH inputs targeting snapshot A vs B."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-d2-gs-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-d2-gen-switch" / vmName
        createDir(perVmDir)

        var extra = initTable[string, string]()
        extra["persistentStateVhd"] = stateVhd
        let totalStart = epochTime()

        # ----- Phase 1: boot ISO A, assert snapshot-A banner. -----
        let specA = BootMediaSpec(
          name: vmName,
          kind: bmkIso,
          mediaPath: isoA,
          cpus: 2,
          memoryMB: 2048,
          generation: 2,
          secureBootEnabled: false,
          serialPipeName: vmName & "-com1-phaseA",
          serialLogPath: perVmDir / (vmName & ".phaseA.serial.log"),
          extra: extra)
        let vmA = backend.bootFromMedia(specA)
        let serialA = backend.captureSerial(vmA)
        defer:
          backend.closeSerial(serialA)
          backend.stopAndCleanup(vmA, deleteVm = true)
        awaitLogin(backend, serialA)
        echo "[d2gs] phase 1: assert git from snapshot A"
        let phase1 = runShellWithSentinel(backend, serialA, "P1",
          "git --version", GenABanner)
        check phase1
        discard runShellWithSentinel(backend, serialA, "P1A",
          "reproos-rebuild apply --yes && echo D2GS_APPLY_OK_A",
          r"D2GS_APPLY_OK_A")

        # ----- Phase 2: switch to ISO B's config, reboot, assert snapshot-B. -----
        echo "[d2gs] phase 2: switch to snapshot B"
        discard runShellWithSentinel(backend, serialA, "P2-prep",
          "mkdir -p /mnt/gen-b && mount -t iso9660 -o ro /dev/sr1 /mnt/gen-b 2>/dev/null && " &
          "cp /mnt/gen-b/etc/reproos/configuration.nim /etc/reproos/ && " &
          "echo D2GS_PREP_OK",
          r"D2GS_PREP_OK")
        discard runShellWithSentinel(backend, serialA, "P2A",
          "reproos-rebuild apply --yes && reproos-rebuild switch latest && " &
          "echo D2GS_SWITCH_OK",
          r"D2GS_SWITCH_OK")
        backend.serialSend(serialA, "systemctl reboot\n")
        awaitLogin(backend, serialA)
        let phase2 = runShellWithSentinel(backend, serialA, "P2",
          "git --version", GenBBanner)
        check phase2

        # ----- Phase 3: rollback, reboot, assert snapshot-A again. -----
        echo "[d2gs] phase 3: rollback to snapshot A"
        discard runShellWithSentinel(backend, serialA, "P3A",
          "reproos-rebuild rollback && echo D2GS_ROLLBACK_OK",
          r"D2GS_ROLLBACK_OK")
        backend.serialSend(serialA, "systemctl reboot\n")
        awaitLogin(backend, serialA)
        let phase3 = runShellWithSentinel(backend, serialA, "P3",
          "git --version", GenABanner)
        check phase3

        let totalElapsed = epochTime() - totalStart
        echo "[d2gs] phases passed: ", int(phase1) + int(phase2) +
          int(phase3), "/3"
        echo "[d2gs] total wall-clock: ",
          totalElapsed.formatFloat(precision = 1), "s"
        if totalElapsed > TotalDeadlineSec.float:
          echo "[d2gs] WARN: wall-clock exceeds D2 P6 budget of ",
            TotalDeadlineSec, "s"
