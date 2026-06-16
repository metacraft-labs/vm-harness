## e2e_vm_harness_hyperv_reproos_hyprland
##
## DE-H2 acceptance gate for the ReproOS-Wayland-DEs-PoC campaign:
## boot the DE-H1 Hyprland-equivalent ISO (sway-as-Hyprland; see
## ``docs/wayland-de-hyprland.md``) under Hyper-V Gen-2 UEFI (Secure
## Boot off), wait for the systemd login prompt, autologin as the
## ``repro:1000`` user that DE0-S provisions, run
## ``/usr/local/bin/repro-start-hyprland.sh`` under ``REPRO_HEADLESS=1``
## so wlroots picks the headless backend (no DRM/virtio-gpu emulation
## of Hyper-V SyntheticVideo), and assert the compositor came up far
## enough to:
##
##   1. print its "Wayland compositor" / version banner;
##   2. answer ``swaymsg -t get_version`` over the WAYLAND_DISPLAY
##      socket;
##   3. launch the foot terminal via ``swaymsg exec foot``;
##   4. NOT emit fatal "Aborting" / "Critical" log lines while doing so.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\de-h1-iso\reproos-mvp.iso``
##
## Produced by:
##
##   wsl -d repro-ubuntu bash recipes/reproos-mvp-config/build-mvp-iso.sh
##     MVP_INCLUDE_HYPRLAND=1 MVP_STAGE=iso
##     MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-h1-iso
##
## The MVP_INCLUDE_HYPRLAND knob implies MVP_INCLUDE_DE0_SESSION +
## MVP_INCLUDE_DE0_DBUS + MVP_INCLUDE_DE0_GRAPHICS so the planted ISO
## carries the full DE0 foundation under DE-H1's compositor stack.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The DE-H1 ISO doesn't exist on disk yet.
##
## Wall-clock budget per the DE-H2 brief: 180 s total, 60 s per cmd.
## Memory budget: 2048 MB (much less than D4's 4096; the sway + wlroots
## closure is small, ~3 MB .deb total, vs D4's ~285 MB Darling closure).

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_hyprland: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\de-h1-iso\reproos-mvp.iso"
    ## DE-H1's build driver re-uses ``build-mvp-iso.sh`` and so emits
    ## the conventional ``reproos-mvp.iso`` filename even when
    ## MVP_INCLUDE_HYPRLAND=1. The DE_H_HYPRLAND_ISO env var overrides
    ## the on-disk lookup so a CI host with a different layout still
    ## reaches the test.

  TotalDeadlineSec = 180
  BootStageTimeout = 90
  LoginTimeout     = 60
  CmdTimeout       = 60
  ## CmdTimeout 60 s per the DE-H2 brief: sway's first-time wlroots
  ## backend init (allocator + pixman renderer + xkb keymap compile)
  ## takes noticeably longer than a steady-state shell roundtrip;
  ## ``swaymsg`` against a not-yet-ready socket retries internally with
  ## ~2 s spacing. 60 s comfortably absorbs both.

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

proc findHyprlandIso(): string =
  let envOverride = getEnv("DE_H_HYPRLAND_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# Compositor-up assertion table.
#
# The DE-H2 brief lists 3 banner-class assertions + 1 negative
# "no Aborting/Critical" assertion. We layer them so a single COM1
# session covers all four; failures attribute clearly via per-assertion
# sentinels.
#
# The "sway" prefix on the command lines reflects the DE-H1 planted
# compositor (jammy-native sway 1.7 as Hyprland surrogate; see
# docs/wayland-de-hyprland.md "Why sway (not Hyprland)"). When upstream
# Hyprland is planted in a future milestone, swap the commands to
# ``hyprctl`` / ``Hyprland`` and re-run.
# ---------------------------------------------------------------------------

type
  HyprlandAssertion = object
    name*: string
    command*: string
    pattern*: string

const HyprlandAssertions = @[
  HyprlandAssertion(name: "sway-banner",
    # sway prints "sway version <ver>\n" on stderr at startup. We
    # already started it via systemd-cat (see runBootScenario), so the
    # banner shows up in the journal stream we tail; this command just
    # waits for it to flush.
    command: "journalctl -u repro-hyprland.service -n 50 --no-pager 2>&1 | grep -i 'sway version' || journalctl -t repro-hyprland -n 50 --no-pager 2>&1 | grep -iE 'sway version|wayland compositor'",
    pattern: r"sway version|Wayland compositor"),
  HyprlandAssertion(name: "swaymsg-get-version",
    command: "WAYLAND_DISPLAY=wayland-1 swaymsg -t get_version 2>&1",
    pattern: r"""("human_readable":|"major":)"""),
  HyprlandAssertion(name: "swaymsg-exec-foot",
    # swaymsg returns immediately with "{}" or "[ ... \"success\": true \"... ]"
    # for an exec dispatch; we cross-check by greping for the success token.
    command: "WAYLAND_DISPLAY=wayland-1 swaymsg exec foot 2>&1",
    pattern: r"""("success" *: *true|^\{\})"""),
]

proc runBootScenario(backend: HyperVBackend, isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    memoryMB: 2048,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("DE_H_HYPRLAND_KEEP_SERIAL", "")
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

  echo "[info] expecting Linux kernel banner..."
  let kernelBanner = backend.expectLine(serial,
    r"Linux version", timeoutSec = BootStageTimeout)
  check kernelBanner.matched
  if not kernelBanner.matched:
    echo "[diag] kernel banner never appeared; aborting DE-H2 scenario"
    return

  echo "[info] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial,
    r"systemd\[1\]:", timeoutSec = BootStageTimeout)
  check pid1.matched

  echo "[info] expecting login prompt on ttyS0..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|repro@reproos|root@reproos|repro@.*[\$#]|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[diag] login prompt never appeared"
    return

  # Drop into the repro:1000 user shell. The DE0-S overlay autologin's
  # at the agetty layer; if the ISO lands at a bare login: prompt we
  # fall back to interactive auth (the DE0-S default password is
  # ``reproos`` for the repro user).
  if login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ \$|repro@.*[\$#]|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      backend.serialSend(serial, "repro\n")
      discard backend.expectLine(serial, r"(password|Password|\$|#)",
        timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)", timeoutSec = LoginTimeout)

  # ---------------------------------------------------------------------
  # Optional diagnostic surface — list the DE-H1 overlay tree + DE0
  # foundation pieces so a failure clearly distinguishes "compositor
  # never started" from "compositor started but swaymsg unreachable".
  # ---------------------------------------------------------------------
  if getEnv("DE_H_HYPRLAND_DIAGNOSTIC", "") == "1":
    proc probe(cmd: string) =
      backend.serialSend(serial, cmd & "\n")
    backend.serialSend(serial, "echo DE_H_DIAG_BEGIN\n")
    probe("id")
    probe("ls /etc/wayland-sessions/ 2>&1")
    probe("ls /etc/hyprland.conf /etc/sway/config 2>&1")
    probe("ls /usr/local/bin/repro-start-hyprland.sh 2>&1")
    probe("ls /opt/reproos-linux/store/ 2>&1 | head -25")
    probe("cat /etc/profile.d/xkb-data.sh /etc/profile.d/glvnd.sh 2>&1")
    probe("command -v sway swaymsg foot 2>&1")
    probe("systemctl status dbus.service dbus.socket 2>&1 | head -10")
    probe("ls -la /run/user/1000 2>&1")
    backend.serialSend(serial, "echo DE_H_DIAG_END\n")
    discard backend.expectLine(serial, r"DE_H_DIAG_END",
      timeoutSec = CmdTimeout)

  # ---------------------------------------------------------------------
  # Start the compositor in the background under systemd-cat so its
  # stdout/stderr lands in the journal and can be inspected via the
  # ``sway-banner`` assertion below. We tag with ``repro-hyprland`` so
  # the journalctl -t filter is stable across the assertion phase.
  # ---------------------------------------------------------------------
  echo "[de-h2] launching repro-start-hyprland.sh headless..."
  backend.serialSend(serial,
    "REPRO_HEADLESS=1 setsid systemd-cat -t repro-hyprland " &
    "/usr/local/bin/repro-start-hyprland.sh </dev/null >/dev/null 2>&1 &\n")
  # Brief pause for sway's allocator + wlroots setup before swaymsg.
  backend.serialSend(serial, "sleep 3 && echo DE_H_COMPOSITOR_LAUNCHED\n")
  discard backend.expectLine(serial, r"DE_H_COMPOSITOR_LAUNCHED",
    timeoutSec = CmdTimeout)

  # ---------------------------------------------------------------------
  # Phase: run the 3 banner/RPC assertions + the negative log check.
  # ---------------------------------------------------------------------
  var passed = 0
  for ha in HyprlandAssertions:
    echo "[de-h2] asserting ", ha.name, "..."
    let sentinelBefore = "DE_H_BEGIN_" & ha.name
    let sentinelAfter  = "DE_H_END_" & ha.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & ha.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, ha.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[de-h2] PASS ", ha.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[de-h2] FAIL ", ha.name, ": expected /", ha.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  # ---------------------------------------------------------------------
  # Negative assertion: no fatal "Aborting" / "Critical" in the journal.
  # We grep the repro-hyprland journal slice; absence is a PASS.
  # ---------------------------------------------------------------------
  echo "[de-h2] checking journal for fatal errors..."
  backend.serialSend(serial,
    "echo DE_H_NEGCHK_BEGIN && " &
    "journalctl -t repro-hyprland -n 200 --no-pager 2>&1 | " &
    "grep -E 'Aborting|Critical' | head -3; " &
    "echo DE_H_NEGCHK_END\n")
  let negChk = backend.expectLine(serial, r"DE_H_NEGCHK_END",
    timeoutSec = CmdTimeout)
  if negChk.matched:
    # If we saw any Aborting/Critical lines before the END sentinel,
    # the grep output is in the captured serial buffer; the harness's
    # expectLine semantics don't expose the slice, so we re-grep
    # against an inverse marker — absence of an "Aborting!" sentinel
    # forwarded by a follow-up cmd.
    backend.serialSend(serial,
      "journalctl -t repro-hyprland -n 200 --no-pager 2>&1 | " &
      "grep -Eq 'Aborting|Critical' && echo DE_H_FATALS_PRESENT || " &
      "echo DE_H_NO_FATALS\n")
    let fatalsState = backend.expectLine(serial,
      r"(DE_H_FATALS_PRESENT|DE_H_NO_FATALS)", timeoutSec = CmdTimeout)
    if fatalsState.matched and
       fatalsState.matchedText.contains("DE_H_NO_FATALS"):
      echo "[de-h2] PASS no-fatals: no Aborting/Critical in journal"
    else:
      echo "[de-h2] FAIL no-fatals: Aborting/Critical lines present in journal"
      check fatalsState.matchedText.contains("DE_H_NO_FATALS")

  let totalElapsed = epochTime() - totalStart
  echo "[de-h2] hyprland assertions passed: ", passed, "/",
       HyprlandAssertions.len
  echo "[de-h2] total wall-clock: ",
       totalElapsed.formatFloat(precision = 1), "s"
  echo "[de-h2] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[de-h2] WARN: total wall-clock exceeds DE-H2 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_hyprland":
  test "DE-H2 acceptance: reproos-de-hyprland.iso boots, sway/foot startup banners":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-de-h2-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findHyprlandIso()
      if iso.len == 0:
        echo "[skip] DE-H1 Hyprland ISO not found at ", DefaultIsoPath,
             " (and DE_H_HYPRLAND_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-iso.sh"
        echo "       with MVP_INCLUDE_HYPRLAND=1 MVP_STAGE=iso " &
             "MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-h1-iso"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-de-h2-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-de-h2" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
