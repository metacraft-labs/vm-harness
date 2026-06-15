## e2e_vm_harness_hyperv_reproos_multi_distro
##
## D2 acceptance gate for the ReproOS-Generations-And-Foreign-Packages
## campaign: boot a reproos-mvp-multi.iso under Hyper-V Gen-2 UEFI
## (Secure Boot off), wait for the systemd login prompt, auto-login as
## root, and execute the 9 foreign-package binaries (5 apt + 2 dnf + 2
## pacman) via the C3 bind-mount sandbox launcher. Each binary must
## produce the expected version banner from the pinned snapshot of its
## upstream distro.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\d2-mvp-multi\reproos-mvp-multi.iso``
##
## Produced by:
##
##   bash recipes/reproos-mvp-config/build-mvp-multi-iso.sh MVP_STAGE=iso
##
## ...inside the repro-ubuntu WSL distro. The build driver tolerates a
## missing R9/R8 toolchain on the build host and emits a warning rather
## than a corrupt ISO; the absence of the ISO at acceptance-test time
## results in a SKIP, never a silent pass.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The D2 multi-distro ISO doesn't exist on disk yet.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_multi_distro: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\d2-mvp-multi\reproos-mvp-multi.iso"

  TotalDeadlineSec = 90
  BootStageTimeout = 90
  LoginTimeout     = 60
  CmdTimeout       = 15

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

proc findMvpIso(): string =
  let envOverride = getEnv("D2_MVP_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# Foreign-package assertion table — 9 entries (5 apt + 2 dnf + 2 pacman).
#
# The shim layout exposes:
#   /usr/local/bin/<name>             — apt copy when present (D1 parity)
#   /usr/local/bin/<distro>-<name>    — always
#
# The dnf-htop / pacman-htop shims disambiguate the htop collision
# (three different upstreams provide htop in the multi config).
# ---------------------------------------------------------------------------

type
  ForeignAssertion = object
    name*: string
    command*: string
    pattern*: string

const ForeignAssertions = @[
  # apt — 5 assertions; reuses the D1 banner patterns.
  ForeignAssertion(name: "apt-git",
    command: "git --version",
    pattern: r"git version 1:2\.39\.5"),
  ForeignAssertion(name: "apt-vim",
    command: "vim --version | head -1",
    pattern: r"VIM - Vi IMproved 2:9\.0\.1378"),
  ForeignAssertion(name: "apt-python3",
    command: "python3 -c 'print(\"D2PY3 hi STOP\")'",
    pattern: r"D2PY3 hi STOP"),
  ForeignAssertion(name: "apt-curl",
    command: "curl --version | head -1",
    pattern: r"curl 7\.88\.1"),
  ForeignAssertion(name: "apt-htop",
    command: "apt-htop --version",
    pattern: r"htop 3\.2\.2.*\(apt\)"),
  # dnf — 2 assertions; the dnf-htop and dnf-neovim shims invoke the
  # Fedora-flavored stubs whose --version banner includes "(dnf)".
  ForeignAssertion(name: "dnf-htop",
    command: "dnf-htop --version",
    pattern: r"htop 3\.3\.0-1\.fc39.*\(dnf\)"),
  ForeignAssertion(name: "dnf-neovim",
    command: "dnf-neovim --version",
    pattern: r"NVIM v0\.10\.2-1\.fc39.*\(dnf\)"),
  # pacman — 2 assertions.
  ForeignAssertion(name: "pacman-htop",
    command: "pacman-htop --version",
    pattern: r"htop 3\.3\.0-1.*\(pacman\)"),
  ForeignAssertion(name: "pacman-fzf",
    command: "pacman-fzf --version",
    pattern: r"0\.55\.0-1.*\(pacman\)"),
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
  let logKeepDir = getEnv("D2_MVP_KEEP_SERIAL", "")
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
    echo "[diag] kernel banner never appeared"
    return

  echo "[info] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial,
    r"systemd\[1\]:", timeoutSec = BootStageTimeout)
  check pid1.matched

  echo "[info] expecting login prompt on ttyS0..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|root@reproos|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[diag] login prompt never appeared"
    return

  if login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ #|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      backend.serialSend(serial, "root\n")
      discard backend.expectLine(serial, r"(password|Password|\$|#)",
        timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)", timeoutSec = LoginTimeout)

  if getEnv("D2_MVP_DIAGNOSTIC", "") == "1":
    backend.serialSend(serial,
      "echo D2_DIAG_BEGIN; ls /usr/local/bin/ 2>&1; " &
      "ls /opt/reproos-foreign/ 2>&1; " &
      "ls /opt/reproos-foreign/apt/ /opt/reproos-foreign/dnf/ " &
        "/opt/reproos-foreign/pacman/ 2>&1; " &
      "echo D2_DIAG_END\n")
    discard backend.expectLine(serial, r"D2_DIAG_END",
      timeoutSec = CmdTimeout)

  var passed = 0
  for fa in ForeignAssertions:
    echo "[d2] asserting ", fa.name, " via shim..."
    let sentinelBefore = "D2_BEGIN_" & fa.name
    let sentinelAfter  = "D2_END_" & fa.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & fa.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, fa.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[d2] PASS ", fa.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[d2] FAIL ", fa.name, ": expected /", fa.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[d2] foreign assertions passed: ", passed, "/",
    ForeignAssertions.len
  echo "[d2] total wall-clock: ",
    totalElapsed.formatFloat(precision = 1), "s"
  echo "[d2] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[d2] WARN: total wall-clock exceeds D2 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_multi_distro":
  test "D2 acceptance: reproos-mvp-multi.iso boots, 9 foreign packages":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-d2-mvp-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findMvpIso()
      if iso.len == 0:
        echo "[skip] D2 multi-distro ISO not found at ", DefaultIsoPath,
             " (and D2_MVP_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-multi-iso.sh"
        echo "       with MVP_STAGE=iso once the R9 systemd install tree is on the host."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-d2-mvp-multi-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-d2-mvp" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
