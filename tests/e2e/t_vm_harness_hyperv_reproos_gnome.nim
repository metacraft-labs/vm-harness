## e2e_vm_harness_hyperv_reproos_gnome
##
## DE-G2 acceptance gate for the ReproOS-Wayland-DEs-PoC campaign:
## boot the DE-G1 GNOME-42 ISO under Hyper-V Gen-2 UEFI (Secure Boot
## off), wait for the systemd login prompt, autologin as the
## ``repro:1000`` user that DE0-S provisions, drive the planted GDM /
## gnome-session chain headless (no DRM/virtio-gpu emulation of
## Hyper-V SyntheticVideo), and assert the GNOME stack came up far
## enough to:
##
##   1. ``journalctl -u gdm`` shows GDM started;
##   2. ``gnome-shell --version`` reports the planted ``GNOME Shell 42.x``;
##   3. ``mutter --version`` returns successfully (mutter is part of the
##      planted closure; gnome-shell links it at runtime).
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\de-g1-iso\reproos-mvp.iso``
##
## Produced by:
##
##   wsl -d repro-ubuntu bash recipes/reproos-mvp-config/build-mvp-iso.sh
##     MVP_INCLUDE_GNOME=1 MVP_STAGE=iso
##     MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-g1-iso
##
## The MVP_INCLUDE_GNOME knob implies MVP_INCLUDE_DE0_SESSION +
## MVP_INCLUDE_DE0_DBUS + MVP_INCLUDE_DE0_GRAPHICS so the planted ISO
## carries the full DE0 foundation under DE-G1's compositor stack.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The DE-G1 ISO doesn't exist on disk yet.
##
## Wall-clock budget per the DE-G2 brief: 300 s total, 180 s per cmd.
## Memory budget: 4096 MB (matches D4's allocation; GNOME's closure is
## ~10x larger than DE-H1's sway closure — gnome-shell + mutter + gjs +
## libmozjs-91 alone are ~120 MB on disk, and gnome-session forks the
## gsd-* daemon set + dconf-service on first boot).
##
## NOTE on cascade G (R9 systemd dbus.socket non-activation): DE-H2
## documented cascade G as deferred — without dbus.service active there
## is no /run/user/1000, gdm.service stalls waiting on logind, and the
## three banner assertions cannot fire. DE-G2 inherits the same blocker.
## Per the milestone brief, we land the test infrastructure + run it
## once; banner-green is NOT required for milestone closure given the
## cascade G state. Expect 0/3 banner-class assertions until cascade G
## lifts.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_gnome: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\de-g1-iso\reproos-mvp.iso"
    ## DE-G1's build driver re-uses ``build-mvp-iso.sh`` and so emits
    ## the conventional ``reproos-mvp.iso`` filename even when
    ## MVP_INCLUDE_GNOME=1. The DE_G_GNOME_ISO env var overrides the
    ## on-disk lookup so a CI host with a different layout still
    ## reaches the test.

  TotalDeadlineSec = 300
  BootStageTimeout = 120
  LoginTimeout     = 90
  CmdTimeout       = 180
  ## CmdTimeout 180 s per the DE-G2 brief: gnome-shell's first-time
  ## startup recompiles its JS modules (gjs/mozjs91), initialises
  ## GSettings DB shims, and probes the mutter backend — all under a
  ## headless wlroots-less Hyper-V SyntheticVideo. ``gnome-shell
  ## --version`` is a no-init smoke probe (just prints the build tag)
  ## but ``mutter --version`` walks its plugin list. 180 s comfortably
  ## absorbs both even on a cold first boot.

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

proc findGnomeIso(): string =
  let envOverride = getEnv("DE_G_GNOME_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# GDM / gnome-shell banner assertion table.
#
# The DE-G2 brief lists 3 banner-class assertions. We layer them so a
# single COM1 session covers all three; failures attribute clearly via
# per-assertion sentinels.
#
# We do NOT attempt to assert "gnome-shell started a session" via
# ``journalctl --user-unit=org.gnome.Shell`` because under headless +
# no logind /run/user/1000 the user-session journal never spins up.
# The three checks below are the campaign-spec assertion set verbatim;
# mutter --version is the documented optional ("if installed"). The
# planted DE-G1 closure includes mutter so it is exercised.
# ---------------------------------------------------------------------------

type
  GnomeAssertion = object
    name*: string
    command*: string
    pattern*: string

const GnomeAssertions = @[
  GnomeAssertion(name: "gdm-started",
    # gdm.service is wired into multi-user.target.wants by DE-G1; the
    # journal slice tagged ``gdm`` records the systemd unit's stdout +
    # stderr. We accept either the systemd start banner ("Starting
    # GNOME Display Manager") or any gdm-process self-banner.
    command: "journalctl -u gdm -n 50 --no-pager 2>&1 | grep -iE 'Starting GNOME Display Manager|GdmDisplay|Started|gdm-session-worker' || journalctl -u gdm.service -n 50 --no-pager 2>&1",
    pattern: r"(Starting GNOME Display Manager|Started|gdm-session-worker|GdmDisplay)"),
  GnomeAssertion(name: "gnome-shell-version",
    # gnome-shell --version is a self-contained smoke probe: it links
    # libmutter + libgjs eagerly to print the tag. The planted closure
    # pins GNOME Shell 42.x (jammy upstream).
    command: "/usr/local/bin/gnome-shell --version 2>&1 || gnome-shell --version 2>&1",
    pattern: r"GNOME Shell 42\."),
  GnomeAssertion(name: "mutter-version",
    # mutter --version smoke probe; the planted closure includes the
    # mutter binary as a sibling to gnome-shell. Returns "mutter 42.x"
    # or "mutter <ver>" depending on the package's version-string code
    # path; accept either via a loose pattern.
    command: "/usr/local/bin/mutter --version 2>&1 || mutter --version 2>&1",
    pattern: r"mutter\s+\d+"),
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
  let logKeepDir = getEnv("DE_G_GNOME_KEEP_SERIAL", "")
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
    echo "[diag] kernel banner never appeared; aborting DE-G2 scenario"
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
  # Optional diagnostic surface — list the DE-G1 overlay tree + DE0
  # foundation pieces so a failure clearly distinguishes "gdm never
  # started" from "gdm started but gnome-shell unreachable".
  # ---------------------------------------------------------------------
  if getEnv("DE_G_GNOME_DIAGNOSTIC", "") == "1":
    proc probe(cmd: string) =
      backend.serialSend(serial, cmd & "\n")
    backend.serialSend(serial, "echo DE_G_DIAG_BEGIN\n")
    probe("id")
    probe("ls /etc/wayland-sessions/ 2>&1")
    probe("ls /etc/gdm3/custom.conf 2>&1")
    probe("cat /etc/gdm3/custom.conf 2>&1")
    probe("ls /usr/local/bin/repro-start-gnome.sh /usr/local/bin/gnome-shell /usr/local/bin/gnome-session /usr/local/bin/mutter 2>&1")
    probe("ls /opt/reproos-linux/store/ 2>&1 | head -30")
    probe("cat /etc/profile.d/gnome-gsettings.sh /etc/profile.d/glvnd.sh 2>&1")
    probe("command -v gdm gdm3 gnome-shell mutter gnome-session 2>&1")
    probe("systemctl status dbus.service dbus.socket 2>&1 | head -10")
    # DE-G2 cascade inheritance: surface why gdm.service didn't fire.
    # Three probes:
    #   1. systemctl status gdm to see ExecStart, last exit code.
    #   2. journalctl -u gdm to extract the actual error/stderr.
    #   3. systemctl status systemd-logind + ls /run/user/1000 to
    #      capture the cascade G dbus/logind/runtime-dir chain.
    probe("systemctl status gdm.service gdm3.service 2>&1 | head -30")
    probe("journalctl -u gdm.service -u gdm3.service --no-pager -n 50 2>&1")
    probe("systemctl status systemd-logind.service 2>&1 | head -30")
    probe("journalctl -u systemd-logind.service --no-pager -n 50 2>&1")
    probe("ls -la /var/lib/systemd/ /var/lib/gdm3/ 2>&1")
    probe("ls -la /run/user/1000 2>&1")
    # Cascade G investigation probes (2026-06-16): dbus.socket non-activation.
    # We need to distinguish: (1) systemd's UnitPath not seeing the symlink,
    # (2) systemd demoting the unit due to NTFS-via-WSL perms, (3) Alias=
    # strict reject. List-sockets reveals whether dbus.socket was even
    # enumerated; status reveals load state + LoadError; analyze verify
    # surfaces parse-time complaints; ls of the .wants/ dirs lets us
    # cross-check that the symlinks survived overlay->initramfs->boot.
    probe("echo '=== CASCADE-G ==='")
    probe("systemd-analyze --version 2>&1 | head -1")
    probe("systemctl list-sockets --all --no-pager 2>&1 | head -40")
    probe("systemctl status dbus.socket --no-pager 2>&1 | head -25")
    probe("systemctl status dbus.service --no-pager 2>&1 | head -25")
    probe("systemctl is-enabled dbus.socket dbus.service 2>&1")
    probe("ls -la /etc/systemd/system/sockets.target.wants/ 2>&1")
    probe("ls -la /etc/systemd/system/multi-user.target.wants/ 2>&1")
    probe("ls -la /lib/systemd/system/dbus.socket /lib/systemd/system/dbus.service /lib/systemd/system/dbus-broker.service 2>&1")
    probe("stat -c '%n %a %U:%G %F' /etc/systemd/system/sockets.target.wants/dbus.socket /lib/systemd/system/dbus.socket /lib/systemd/system/dbus-broker.service 2>&1")
    probe("readlink /etc/systemd/system/sockets.target.wants/dbus.socket /etc/systemd/system/dbus.service /etc/systemd/system/multi-user.target.wants/dbus.service 2>&1")
    probe("journalctl -u dbus.socket -u dbus.service -u dbus-broker.service --no-pager -n 80 2>&1 | head -50")
    probe("systemd-analyze verify dbus.socket 2>&1 | head -20")
    probe("systemd-analyze verify dbus.service 2>&1 | head -20")
    probe("systemctl show -p UnitPath 2>&1 | head -3")
    probe("systemctl show dbus.socket -p LoadState -p ActiveState -p SubState -p LoadError -p FragmentPath -p TriggeredBy -p Wants -p WantedBy 2>&1")
    probe("systemctl show dbus.service -p LoadState -p ActiveState -p SubState -p LoadError -p FragmentPath -p Alias -p Names 2>&1")
    probe("systemctl show sockets.target -p Wants -p After -p Before 2>&1 | head -5")
    probe("ss -lnxp 2>&1 | grep -E 'dbus|system_bus_socket' | head")
    probe("ls -la /run/dbus/ 2>&1")
    probe("dmesg 2>&1 | grep -iE 'dbus|socket|systemd' | head -30")
    probe("echo '=== END-CASCADE-G ==='")
    backend.serialSend(serial, "echo DE_G_DIAG_END\n")
    discard backend.expectLine(serial, r"DE_G_DIAG_END",
      timeoutSec = CmdTimeout)

  # ---------------------------------------------------------------------
  # Phase: run the 3 banner-class assertions. We deliberately do NOT
  # launch repro-start-gnome.sh out-of-band the way DE-H2 does for
  # sway — GNOME's gdm autologin path (AutomaticLoginEnable=true in
  # /etc/gdm3/custom.conf) is what kicks the session under the planted
  # configuration. The "gdm-started" assertion verifies gdm.service
  # was activated; the gnome-shell / mutter assertions verify the
  # binaries are present + linkable even when the session itself can't
  # come up under cascade G.
  # ---------------------------------------------------------------------
  var passed = 0
  for ga in GnomeAssertions:
    echo "[de-g2] asserting ", ga.name, "..."
    let sentinelBefore = "DE_G_BEGIN_" & ga.name
    let sentinelAfter  = "DE_G_END_" & ga.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & ga.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, ga.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[de-g2] PASS ", ga.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[de-g2] FAIL ", ga.name, ": expected /", ga.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[de-g2] gnome assertions passed: ", passed, "/",
       GnomeAssertions.len
  echo "[de-g2] total wall-clock: ",
       totalElapsed.formatFloat(precision = 1), "s"
  echo "[de-g2] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[de-g2] WARN: total wall-clock exceeds DE-G2 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_gnome":
  test "DE-G2 acceptance: reproos-de-gnome.iso boots, gdm/gnome-shell startup banners":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-de-g2-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findGnomeIso()
      if iso.len == 0:
        echo "[skip] DE-G1 GNOME ISO not found at ", DefaultIsoPath,
             " (and DE_G_GNOME_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-iso.sh"
        echo "       with MVP_INCLUDE_GNOME=1 MVP_STAGE=iso " &
             "MVP_OUT_DIR=/mnt/d/metacraft/reprobuild/build/de-g1-iso"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-de-g2-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-de-g2" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
