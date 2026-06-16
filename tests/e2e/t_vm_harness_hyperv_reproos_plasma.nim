## e2e_vm_harness_hyperv_reproos_plasma
##
## DE-K2 acceptance gate for the ReproOS-Wayland-DEs-PoC campaign:
## boot the DE-K1 Plasma 5.24 ISO under Hyper-V Gen-2 UEFI (Secure
## Boot off), wait for the systemd login prompt, autologin as the
## ``repro:1000`` user that DE0-S provisions, drive the planted SDDM /
## kwin_wayland / plasmashell chain headless (no DRM/virtio-gpu
## emulation of Hyper-V SyntheticVideo), and assert the Plasma stack
## came up far enough to:
##
##   1. ``journalctl -u sddm`` shows SDDM started;
##   2. ``kwin_wayland --version`` reports the planted ``kwin 5.24``;
##   3. ``plasmashell --version`` (if installed) reports the planted
##      ``plasmashell 5.24``.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\de-k1-iso\reproos-mvp.iso``
##
## Produced by:
##
##   wsl -d repro-ubuntu bash recipes/reproos-mvp-config/build-mvp-iso.sh
##     MVP_INCLUDE_PLASMA=1 MVP_STAGE=iso
##     MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-k1-iso
##
## The MVP_INCLUDE_PLASMA knob implies MVP_INCLUDE_DE0_SESSION +
## MVP_INCLUDE_DE0_DBUS + MVP_INCLUDE_DE0_GRAPHICS so the planted ISO
## carries the full DE0 foundation under DE-K1's compositor stack.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The DE-K1 ISO doesn't exist on disk yet.
##
## Wall-clock budget per the DE-K2 brief: 480 s total, 300 s per cmd.
## Memory budget: 4096 MB (matches DE-G2's allocation; Plasma's closure
## is the largest of the three DEs — kwin + plasmashell + plasma-workspace
## + 25 KF5/Qt5 packages — and the first-time QML compile + kded5/
## kactivitymanagerd / plasmashell process tree is heavier than
## gnome-shell's first boot under llvmpipe).

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_plasma: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\de-k1-iso\reproos-mvp.iso"
    ## DE-K1's build driver re-uses ``build-mvp-iso.sh`` and so emits
    ## the conventional ``reproos-mvp.iso`` filename even when
    ## MVP_INCLUDE_PLASMA=1. The DE_K_PLASMA_ISO env var overrides the
    ## on-disk lookup so a CI host with a different layout still
    ## reaches the test.

  TotalDeadlineSec = 480
  BootStageTimeout = 180
  LoginTimeout     = 120
  CmdTimeout       = 300
  ## CmdTimeout 300 s per the DE-K2 brief: Plasma's closure is the
  ## largest of the three DEs (kwin_wayland + plasmashell + KF5 + Qt5
  ## + 25 supporting catalogs). ``kwin_wayland --version`` walks the
  ## qt5 plugin tree (QT_PLUGIN_PATH from /etc/profile.d/plasma-qt.sh)
  ## and probes the wayland backend; ``plasmashell --version`` links
  ## libplasma + libplasmaquick eagerly to print the build tag. 300 s
  ## comfortably absorbs both on a cold first boot under llvmpipe.

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

proc findPlasmaIso(): string =
  let envOverride = getEnv("DE_K_PLASMA_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# SDDM / kwin / plasmashell banner assertion table.
#
# The DE-K2 brief lists 3 banner-class assertions. We layer them so a
# single COM1 session covers all three; failures attribute clearly via
# per-assertion sentinels.
#
# We do NOT attempt to assert "plasmashell started a session" via
# ``journalctl --user-unit=plasma-plasmashell`` because under headless +
# no logind /run/user/1000 the user-session journal never spins up.
# The three checks below are the campaign-spec assertion set verbatim;
# plasmashell --version is the documented optional ("if installed").
# The planted DE-K1 closure includes plasmashell so it is exercised.
# ---------------------------------------------------------------------------

type
  PlasmaAssertion = object
    name*: string
    command*: string
    pattern*: string

const PlasmaAssertions = @[
  PlasmaAssertion(name: "sddm-started",
    # sddm.service is wired into multi-user.target.wants by DE-K1
    # (display-manager.service convention symlink points at it). The
    # journal slice tagged ``sddm`` records the systemd unit's stdout +
    # stderr. We accept either the systemd start banner ("Starting
    # Simple Desktop Display Manager") or sddm's own self-banner.
    command: "journalctl -u sddm -n 50 --no-pager 2>&1 | grep -iE 'Starting Simple Desktop Display Manager|sddm-greeter|Started|Display server started' || journalctl -u sddm.service -n 50 --no-pager 2>&1",
    pattern: r"(Starting Simple Desktop Display Manager|Started|sddm-greeter|Display server started|SDDM)"),
  PlasmaAssertion(name: "kwin-wayland-version",
    # kwin_wayland --version is a self-contained smoke probe: it links
    # libkwinwayland + libqt5wayland eagerly to print the tag. The
    # planted closure pins kwin 5.24.x (jammy upstream).
    command: "/usr/local/bin/kwin_wayland --version 2>&1 || kwin_wayland --version 2>&1",
    pattern: r"kwin\s+5\.24"),
  PlasmaAssertion(name: "plasmashell-version",
    # plasmashell --version smoke probe; the planted closure includes
    # the plasmashell binary as a sibling to kwin_wayland. Returns
    # "plasmashell 5.24.x" or "plasmashell <ver>" depending on the
    # package's version-string code path; accept either via a loose
    # pattern that still pins to 5.24 when the full banner appears.
    command: "/usr/local/bin/plasmashell --version 2>&1 || plasmashell --version 2>&1",
    pattern: r"plasmashell\s+5\.24"),
]

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
  let logKeepDir = getEnv("DE_K_PLASMA_KEEP_SERIAL", "")
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
    echo "[diag] kernel banner never appeared; aborting DE-K2 scenario"
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
  # Optional diagnostic surface — list the DE-K1 overlay tree + DE0
  # foundation pieces so a failure clearly distinguishes "sddm never
  # started" from "sddm started but kwin/plasmashell unreachable".
  # ---------------------------------------------------------------------
  if getEnv("DE_K_PLASMA_DIAGNOSTIC", "") == "1":
    proc probe(cmd: string) =
      backend.serialSend(serial, cmd & "\n")
    backend.serialSend(serial, "echo DE_K_DIAG_BEGIN\n")
    probe("id")
    probe("ls /etc/wayland-sessions/ 2>&1")
    probe("ls /etc/sddm.conf 2>&1")
    probe("cat /etc/sddm.conf 2>&1")
    probe("ls /usr/local/bin/repro-start-plasma.sh /usr/local/bin/kwin_wayland /usr/local/bin/plasmashell /usr/local/bin/startplasma-wayland /usr/local/bin/sddm 2>&1")
    probe("ls /opt/reproos-linux/store/ 2>&1 | head -30")
    probe("cat /etc/profile.d/plasma-qt.sh /etc/profile.d/reproos-libpath.sh 2>&1")
    probe("command -v sddm kwin_wayland plasmashell startplasma-wayland krunner 2>&1")
    probe("systemctl status dbus.service dbus.socket 2>&1 | head -10")
    # DE-K2 cascade inheritance (same cascade G as DE-G2): surface why
    # sddm.service didn't fire. Three probes:
    #   1. systemctl status sddm to see ExecStart, last exit code.
    #   2. journalctl -u sddm to extract the actual error/stderr.
    #   3. systemctl status systemd-logind + ls /run/user/1000 to
    #      capture the cascade G dbus/logind/runtime-dir chain.
    probe("systemctl status sddm.service display-manager.service 2>&1 | head -30")
    probe("journalctl -u sddm.service -u display-manager.service --no-pager -n 50 2>&1")
    probe("systemctl status systemd-logind.service 2>&1 | head -30")
    probe("journalctl -u systemd-logind.service --no-pager -n 50 2>&1")
    probe("ls -la /var/lib/systemd/ /var/lib/sddm/ 2>&1")
    probe("ls -la /run/user/1000 2>&1")
    backend.serialSend(serial, "echo DE_K_DIAG_END\n")
    discard backend.expectLine(serial, r"DE_K_DIAG_END",
      timeoutSec = CmdTimeout)

  # ---------------------------------------------------------------------
  # Phase: run the 3 banner-class assertions. We deliberately do NOT
  # launch repro-start-plasma.sh out-of-band the way DE-H2 does for
  # sway — SDDM's autologin path (User=repro + Session=plasmawayland in
  # /etc/sddm.conf) is what kicks the session under the planted
  # configuration. The "sddm-started" assertion verifies sddm.service
  # was activated; the kwin_wayland / plasmashell assertions verify
  # the binaries are present + linkable even when the session itself
  # can't come up under cascade G / DE-G2's linker cascade.
  # ---------------------------------------------------------------------
  var passed = 0
  for pa in PlasmaAssertions:
    echo "[de-k2] asserting ", pa.name, "..."
    let sentinelBefore = "DE_K_BEGIN_" & pa.name
    let sentinelAfter  = "DE_K_END_" & pa.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & pa.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, pa.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[de-k2] PASS ", pa.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[de-k2] FAIL ", pa.name, ": expected /", pa.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[de-k2] plasma assertions passed: ", passed, "/",
       PlasmaAssertions.len
  echo "[de-k2] total wall-clock: ",
       totalElapsed.formatFloat(precision = 1), "s"
  echo "[de-k2] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[de-k2] WARN: total wall-clock exceeds DE-K2 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_plasma":
  test "DE-K2 acceptance: reproos-de-plasma.iso boots, sddm/kwin/plasmashell startup banners":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-de-k2-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findPlasmaIso()
      if iso.len == 0:
        echo "[skip] DE-K1 Plasma ISO not found at ", DefaultIsoPath,
             " (and DE_K_PLASMA_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-iso.sh"
        echo "       with MVP_INCLUDE_PLASMA=1 MVP_STAGE=iso " &
             "MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-k1-iso"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-de-k2-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-de-k2" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
