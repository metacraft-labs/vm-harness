## e2e_vm_harness_hyperv_reproos_multi_de_sddm
##
## DEM2 acceptance scaffold for the ReproOS-Wayland-DEs-PoC campaign.
##
## DEM2 (Phase DEM, milestone DEM2 -- stretch) is the single-image
## login-time DE selection model: ONE GRUB entry boots a single image;
## SDDM is the unified greeter; the user picks among three Wayland
## sessions at the SDDM greeter UI.
##
## This test boots the DEM2 ISO once under Hyper-V Gen-2 UEFI (Secure
## Boot off), waits for the systemd login prompt (or SDDM tty surface),
## and asserts (best-effort, given cascade G is open):
##
##   1. ``journalctl -u sddm`` shows SDDM started (the system unit
##      activated -- whether the greeter actually paints depends on
##      cascade G).
##   2. ``journalctl -u sddm | grep -iE "session"`` surfaces session-
##      enumeration log lines (SDDM logs every discovered .desktop file
##      in /usr/share/wayland-sessions/ at greeter-start).
##   3. ``ls /usr/share/wayland-sessions/`` contains 3 entries
##      (hyprland.desktop, gnome.desktop, plasmawayland.desktop).
##   4. ``readlink /etc/systemd/system/display-manager.service`` resolves
##      to a path containing ``sddm.service`` (DEM2 wires this directly,
##      not via a selector helper).
##   5. NO ``repro-de-select.service`` is present (DEM2 ditches DEM1's
##      boot-time selector).
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\dem2-iso\reproos-mvp.iso``
##
## Produced by:
##
##   wsl -d repro-ubuntu bash recipes/reproos-mvp-config/build-mvp-iso.sh
##     MVP_INCLUDE_MULTI_DE=1 MVP_DE_SELECTION_MODE=login MVP_STAGE=iso
##     MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/dem2-iso
##
## ``MVP_DE_SELECTION_MODE=login`` flips stage 4k from the DEM1 composer
## to the DEM2 composer (build-mvp-multi-de-sddm-iso.sh) and the GRUB
## variant from multi-de to single.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The DEM2 ISO doesn't exist on disk yet.
##
## Wall-clock budget: 480 s total, 300 s per cmd. Memory: 4096 MB.
##
## Per the DEM2 brief: cascade G (R9 systemd dbus.socket) + the linker
## cascade (DE-G2 finding) are still open, so the actual SDDM greeter
## may not paint. The test surfaces the journal + the on-disk layout
## that DEM2 plants; banner-class outcomes (greeter rendered + user
## drove a session) are documented but not check-fail-gated.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_multi_de_sddm: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\dem2-iso\reproos-mvp.iso"
    ## The build-mvp-iso.sh driver emits the conventional
    ## ``reproos-mvp.iso`` filename even with MVP_DE_SELECTION_MODE=login.
    ## ``DEM2_ISO`` overrides the lookup.

  TotalDeadlineSec = 480
  BootStageTimeout = 180
  LoginTimeout     = 120
  CmdTimeout       = 300
    ## CmdTimeout 300 s mirrors DE-K2: the SDDM start + session
    ## enumeration walks the full DE-K1 + DE-G1 + DE-H1 closure on a
    ## cold boot under llvmpipe.

# ---------------------------------------------------------------------------
# Probe table: DEM2 surfaces 5 assertions (all soft; cascade G may
# suppress greeter rendering but the on-disk layout MUST match).
#
# The first 2 ("session-enumeration" + "sddm-started") are
# journal-derived; the latter 3 ("session-files" + "display-manager-
# symlink" + "no-selector") are filesystem-derived and harder to make
# fail under cascade G (they assert the COMPOSITION pattern).
# ---------------------------------------------------------------------------

type
  Dem2Assertion = object
    name*: string
    command*: string
    pattern*: string
    softFail*: bool
      ## true = log + count but do NOT `check`; cascade G expected to
      ## suppress runtime banner-class assertions. false = hard check.

const Dem2Assertions = @[
  Dem2Assertion(name: "session-files-present",
    # The 3 .desktop files at /usr/share/wayland-sessions/ are
    # composer-planted at ISO-build time; their presence is independent
    # of cascade G.
    command: "ls /usr/share/wayland-sessions/ 2>&1 | sort | tr '\\n' ' '",
    pattern: r"gnome\.desktop.*hyprland\.desktop.*plasmawayland\.desktop",
    softFail: false),
  Dem2Assertion(name: "display-manager-symlink",
    # display-manager.service -> sddm.service (composer wires this
    # directly; build-time invariant).
    command: "readlink /etc/systemd/system/display-manager.service 2>&1",
    pattern: r"sddm\.service",
    softFail: false),
  Dem2Assertion(name: "no-dem1-selector",
    # repro-de-select.service is a DEM1 artefact; the DEM2 composer
    # strips it. Verify it's not present.
    command: "ls /etc/systemd/system/repro-de-select.service 2>&1 || echo NO_SELECTOR",
    pattern: r"(No such file|NO_SELECTOR)",
    softFail: false),
  Dem2Assertion(name: "sddm-started",
    # sddm.service started (journal slice). Soft: cascade G may make
    # SDDM start fall over before painting; the unit's own start banner
    # is what we accept.
    command: "journalctl -u sddm.service -n 50 --no-pager 2>&1 | grep -iE 'Starting Simple Desktop Display Manager|Started|sddm-greeter|Display server started' || journalctl -u sddm -n 50 --no-pager 2>&1",
    pattern: r"(Starting Simple Desktop Display Manager|Started|sddm-greeter|Display server started|SDDM)",
    softFail: true),
  Dem2Assertion(name: "sddm-session-enumeration",
    # SDDM logs every .desktop file it discovers at greeter-start. Soft:
    # the greeter has to actually try to enumerate (gated on the
    # cascade-G outcome). Accept ANY of the 3 session names appearing
    # in the journal.
    command: "journalctl -u sddm.service --no-pager 2>&1 | grep -iE 'session|wayland-sessions' | head -20",
    pattern: r"(hyprland|gnome|plasma|wayland-sessions)",
    softFail: true),
]

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

proc findDem2Iso(): string =
  let envOverride = getEnv("DEM2_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

proc runBootScenario(backend: HyperVBackend, isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    memoryMB: 4096,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("DEM2_KEEP_SERIAL", "")
  defer:
    backend.stopAndCleanup(vm, deleteVm = true)
    if logKeepDir.len > 0:
      createDir(logKeepDir)
      let src = perVmDir / (vmName & ".serial.log")
      if fileExists(src):
        let dst = logKeepDir / (vmName & ".serial.log")
        try: copyFile(src, dst); echo "[diag] serial log preserved at ", dst
        except CatchableError: discard
    if dirExists(perVmDir):
      try: removeDir(perVmDir)
      except CatchableError: discard

  let serial = backend.captureSerial(vm)
  defer: backend.closeSerial(serial)

  echo "[dem2] expecting Linux kernel banner..."
  let kernelBanner = backend.expectLine(serial,
    r"Linux version", timeoutSec = BootStageTimeout)
  check kernelBanner.matched
  if not kernelBanner.matched:
    echo "[diag] kernel banner never appeared; aborting DEM2 scenario"
    return

  echo "[dem2] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial,
    r"systemd\[1\]:", timeoutSec = BootStageTimeout)
  check pid1.matched

  echo "[dem2] expecting login prompt on ttyS0..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|repro@reproos|root@reproos|repro@.*[\$#]|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[diag] login prompt never appeared"
    return

  if login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ \$|repro@.*[\$#]|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      backend.serialSend(serial, "repro\n")
      discard backend.expectLine(serial, r"(password|Password|\$|#)",
        timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)", timeoutSec = LoginTimeout)

  # Optional diagnostic surface. Same shape as DE-K2's diag block;
  # additionally surface the /etc/sddm.conf body so we can verify the
  # DEM2 [Autologin]-stripping landed at the rootfs level.
  if getEnv("DEM2_DIAGNOSTIC", "") == "1":
    proc probe(cmd: string) =
      backend.serialSend(serial, cmd & "\n")
    backend.serialSend(serial, "echo DEM2_DIAG_BEGIN\n")
    probe("id")
    probe("ls /usr/share/wayland-sessions/ 2>&1")
    probe("for f in /usr/share/wayland-sessions/*.desktop; do echo \"--- $f ---\"; cat \"$f\"; done")
    probe("cat /etc/sddm.conf 2>&1")
    probe("readlink /etc/systemd/system/display-manager.service 2>&1")
    probe("ls /etc/systemd/system/multi-user.target.wants/ 2>&1")
    probe("ls /etc/systemd/system/repro-de-select.service 2>&1 || echo NO_SELECTOR_OK")
    probe("ls /usr/local/sbin/repro-de-select.sh 2>&1 || echo NO_SELECTOR_HELPER_OK")
    probe("ls /usr/local/bin/repro-start-hyprland.sh /usr/local/bin/repro-start-gnome.sh /usr/local/bin/repro-start-plasma.sh 2>&1")
    probe("systemctl status sddm.service display-manager.service 2>&1 | head -30")
    probe("journalctl -u sddm.service --no-pager -n 50 2>&1")
    probe("systemctl status systemd-logind.service 2>&1 | head -30")
    probe("journalctl -u systemd-logind.service --no-pager -n 30 2>&1")
    probe("ls -la /var/lib/sddm/ /run/user/1000 2>&1")
    backend.serialSend(serial, "echo DEM2_DIAG_END\n")
    discard backend.expectLine(serial, r"DEM2_DIAG_END",
      timeoutSec = CmdTimeout)

  # ---------------------------------------------------------------------
  # Phase: run the DEM2 assertions. The first 3 are filesystem-derived
  # (hard-checked); the last 2 are journal-derived (soft -- cascade G
  # may suppress).
  # ---------------------------------------------------------------------
  var hardPasses = 0
  var hardTotal  = 0
  var softPasses = 0
  var softTotal  = 0
  for pa in Dem2Assertions:
    echo "[dem2] asserting ", pa.name, " (soft=", pa.softFail, ")..."
    let sentinelBefore = "DEM2_BEGIN_" & pa.name.replace("-", "_")
    let sentinelAfter  = "DEM2_END_" & pa.name.replace("-", "_")
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & pa.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, pa.pattern,
      timeoutSec = CmdTimeout)
    if pa.softFail:
      inc softTotal
      if resp.matched:
        echo "[dem2] PASS (soft) ", pa.name, ": ", resp.matchedText.strip()
        inc softPasses
      else:
        echo "[dem2] FAIL (soft) ", pa.name, ": expected /", pa.pattern,
             "/ not seen within ", CmdTimeout, "s (cascade G expected)"
    else:
      inc hardTotal
      if resp.matched:
        echo "[dem2] PASS (hard) ", pa.name, ": ", resp.matchedText.strip()
        inc hardPasses
      else:
        echo "[dem2] FAIL (hard) ", pa.name, ": expected /", pa.pattern,
             "/ not seen within ", CmdTimeout, "s"
      check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[dem2] hard assertions passed: ", hardPasses, "/", hardTotal
  echo "[dem2] soft assertions passed: ", softPasses, "/", softTotal,
       " (cascade G expected to suppress)"
  echo "[dem2] total wall-clock: ",
       totalElapsed.formatFloat(precision = 1), "s"
  echo "[dem2] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[dem2] WARN: total wall-clock exceeds DEM2 budget"

suite "e2e_vm_harness_hyperv_reproos_multi_de_sddm":
  test "DEM2 acceptance: reproos-mvp.iso (login selection) boots + SDDM enumerates 3 sessions":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-dem2-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findDem2Iso()
      if iso.len == 0:
        echo "[skip] DEM2 ISO not found at ", DefaultIsoPath,
             " (and DEM2_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-iso.sh"
        echo "       with MVP_INCLUDE_MULTI_DE=1 MVP_DE_SELECTION_MODE=login " &
             "MVP_STAGE=iso MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/dem2-iso"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-dem2-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-dem2" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
