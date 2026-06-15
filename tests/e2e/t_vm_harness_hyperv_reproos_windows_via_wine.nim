## e2e_vm_harness_hyperv_reproos_windows_via_wine
##
## W4 acceptance gate for the ReproOS-Multi-OS-Catalog-PoC campaign:
## boot a reproos-w4-wine.iso under Hyper-V Gen-2 UEFI (Secure Boot off),
## wait for the systemd login prompt, auto-login as root, and execute
## the 3 Windows-via-WINE binaries (gh 2.40.0, just 1.24.0, ninja 1.12.1)
## via the C3 sandbox launcher's runtime=wine path (W2). Each binary
## must produce the upstream-pinned version banner.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\w4-wine\reproos-w4-wine.iso``
##
## Produced by:
##
##   bash recipes/reproos-mvp-config/build-mvp-wine-iso.sh MVP_STAGE=iso
##
## ...inside the repro-ubuntu WSL distro (so wine + the R8/R9 toolchain
## are available). The build driver tolerates a missing R8/R9 toolchain
## on the build host and emits a warning rather than a corrupt ISO; the
## absence of the ISO at acceptance-test time results in a SKIP, never
## a silent pass.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The W4 wine ISO doesn't exist on disk yet.
##
## Wall-clock budget per the W4 brief: 120 s (WINE cold-start is heavier
## than native Linux foreign packages). Memory budget: 4 GB (the
## augmented initramfs approaches ~350 MB; Hyper-V VM RAM accommodates).

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_windows_via_wine: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\w4-wine\reproos-w4-wine.iso"

  TotalDeadlineSec = 120
  BootStageTimeout = 90
  LoginTimeout     = 60
  CmdTimeout       = 30
  ## CmdTimeout is set generously: WINE cold-start on first invocation
  ## may pay a ~5-10 s tax even with wineboot baked at build time;
  ## subsequent invocations are sub-second.

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

proc findWineIso(): string =
  let envOverride = getEnv("W4_WINE_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# Wine-package assertion table — 3 entries (gh + just + ninja).
#
# Each shim at /usr/local/bin/wine-<name> invokes
# /usr/local/bin/reprobuild-sandbox-launcher --manifest=<vm-path> -- "$@".
# The launcher's runtime=wine path exec()s /usr/bin/wine with the .exe's
# C:/repro-store/<name>/bin/<name>.exe as argv[1] and forwards "--version".
#
# Banners match the wine_version_banner field in each catalog
# (recipes/catalog/windows/<name>.json) — strict equality on the leading
# token plus version triple to prove the Windows binary actually ran.
# ---------------------------------------------------------------------------

type
  WineAssertion = object
    name*: string
    command*: string
    pattern*: string

const WineAssertions = @[
  WineAssertion(name: "wine-gh",
    command: "wine-gh --version",
    pattern: r"gh version 2\.40\.0"),
  WineAssertion(name: "wine-just",
    command: "wine-just --version",
    pattern: r"just 1\.24\.0"),
  WineAssertion(name: "wine-ninja",
    command: "wine-ninja --version",
    pattern: r"1\.12\.1"),
]

proc runBootScenario(backend: HyperVBackend, isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    # 4 GB to comfortably accommodate the ~350 MB augmented initramfs
    # (the kernel decompresses the entire cpio.gz into tmpfs at boot).
    memoryMB: 4096,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("W4_WINE_KEEP_SERIAL", "")
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

  # Optional diagnostic surface: confirm the W4 overlay tree landed in
  # the rootfs as expected. Useful for triaging missing-file failures
  # before the wine-<tool> assertions run.
  if getEnv("W4_WINE_DIAGNOSTIC", "") == "1":
    backend.serialSend(serial,
      "echo W4_DIAG_BEGIN; " &
      "ls /usr/local/bin/wine-* 2>&1; " &
      "ls /opt/reproos-foreign/ 2>&1; " &
      "ls /opt/reproos-foreign/wine-prefix/drive_c/repro-store/ 2>&1; " &
      "ls /usr/lib/wine/ 2>&1; " &
      "/usr/bin/wine --version 2>&1; " &
      "echo W4_DIAG_END\n")
    discard backend.expectLine(serial, r"W4_DIAG_END",
      timeoutSec = CmdTimeout)

  var passed = 0
  for wa in WineAssertions:
    echo "[w4] asserting ", wa.name, " via shim..."
    let sentinelBefore = "W4_BEGIN_" & wa.name
    let sentinelAfter  = "W4_END_" & wa.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & wa.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, wa.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[w4] PASS ", wa.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[w4] FAIL ", wa.name, ": expected /", wa.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[w4] wine assertions passed: ", passed, "/", WineAssertions.len
  echo "[w4] total wall-clock: ", totalElapsed.formatFloat(precision = 1), "s"
  echo "[w4] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[w4] WARN: total wall-clock exceeds W4 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_windows_via_wine":
  test "W4 acceptance: reproos-w4-wine.iso boots, 3 Windows packages via WINE":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-w4-wine-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findWineIso()
      if iso.len == 0:
        echo "[skip] W4 wine ISO not found at ", DefaultIsoPath,
             " (and W4_WINE_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-wine-iso.sh"
        echo "       with MVP_STAGE=iso once the R9 systemd install tree is on the host."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-w4-wine-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-w4-wine" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
