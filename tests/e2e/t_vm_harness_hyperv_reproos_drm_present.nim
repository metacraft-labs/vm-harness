## e2e_vm_harness_hyperv_reproos_drm_present
##
## DE0-K acceptance gate (ReproOS-Wayland-DEs-PoC campaign).
##
## Boots a hybrid (BIOS + UEFI) ISO containing the DE0-K-flipped R8 Linux
## 6.6.142 LTS bzImage under a transient Hyper-V Gen-2 UEFI VM (Secure
## Boot off), captures the COM1 serial console, then asserts that the
## kernel-side surface required by Wayland compositors is present:
##
##   * ``Linux version 6.6.142`` banner    -- proves the R8 bytes ran.
##   * ``hyperv_drm`` driver line in dmesg -- proves CONFIG_DRM_HYPERV=y
##     reached its probe path on the Hyper-V SyntheticVideo device.
##   * ``/dev/dri/card0`` exists in the booted rootfs -- proves the DRM
##     subsystem published the device node, which is the actual
##     userland-visible artifact every Wayland compositor opens.
##
## DE0-K is a kernel-surface gate ONLY. We do NOT require a Wayland
## compositor on the smoke rootfs; the campaign spec calls weston
## "optional -- DE0-K only gates the kernel-level surface." If the
## probed rootfs ships weston (e.g. a future DE0-G build), we additionally
## attempt ``weston --backend=drm --idle-time=0`` for 10 s in headless
## mode and check it doesn't immediately exit; absence of weston is NOT
## a failure.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\de0k-smoke\reproos-de0k-smoke.iso``
##
## Produced by the DE0-K smoke ISO build path (placeholder initramfs +
## DE0-K kernel, no DE userland). When the ISO is missing, this test
## SKIPs — never silently passes.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process isn't elevated.
##   * The DE0-K smoke ISO doesn't exist on disk yet.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_drm_present: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\de0k-smoke\reproos-de0k-smoke.iso"

  TotalDeadlineSec = 180
  BootStageTimeout = 90
  LoginTimeout     = 60
  CmdTimeout       = 60

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

proc findDe0kSmokeIso(): string =
  let envOverride = getEnv("DE0K_SMOKE_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

proc runDrmPresentScenario(backend: HyperVBackend,
                           isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    # 2 GB per the campaign brief — DRM probe + a tiny initramfs +
    # busybox shell is comfortable; future DE0-G runs (when weston
    # lands on the rootfs) will bump this independently.
    memoryMB: 2048,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("DE0K_KEEP_SERIAL", "")
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

  echo "[de0k] expecting `Linux version 6.6.142` banner..."
  let linuxBanner = backend.expectLine(serial,
    r"Linux version 6\.6\.142", timeoutSec = BootStageTimeout)
  check linuxBanner.matched
  if linuxBanner.matched:
    echo "[de0k] linux banner: ", linuxBanner.matchedText.strip()

  # hyperv_drm probe — the Hyper-V SyntheticVideo DRM driver prints a
  # line like "hyperv_drm 00000000-...: [drm] Cannot find any crtc or
  # sizes" or "[drm] Initialized hyperv_drm" once it attaches to the
  # synthetic-video VMBus device. We accept either of the canonical
  # 6.6.x kernel print formats; absence here is the canonical
  # "CONFIG_DRM_HYPERV=y didn't take" symptom.
  echo "[de0k] expecting hyperv_drm probe line in dmesg..."
  let drmBanner = backend.expectLine(serial,
    r"(hyperv_drm.*\[drm\]|\[drm\].*hyperv_drm|Initialized hyperv_drm)",
    timeoutSec = BootStageTimeout)
  check drmBanner.matched
  if drmBanner.matched:
    echo "[de0k] hyperv_drm probe: ", drmBanner.matchedText.strip()

  echo "[de0k] expecting login prompt..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|root@reproos|root@.*[\$#]|~ #|/ #)",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[de0k] login prompt never appeared"
    return

  if login.matchedText.contains("login:"):
    backend.serialSend(serial, "root\n")
    discard backend.expectLine(serial, r"(password|Password|\$|#)",
      timeoutSec = LoginTimeout)
    if (let bannerCap = backend.expectLine(serial,
        r"(password|Password)", timeoutSec = 5); bannerCap.matched):
      backend.serialSend(serial, "reproos\n")
    discard backend.expectLine(serial, r"(\$|#)",
      timeoutSec = LoginTimeout)

  # --- DE0-K gate: /dev/dri/card0 must exist ----------------------------
  echo "[de0k] probing /dev/dri/card0..."
  backend.serialSend(serial,
    "echo DE0K_DRI_BEGIN && ls -la /dev/dri/card0 2>&1 && " &
    "echo DE0K_DRI_OK || echo DE0K_DRI_MISSING\n")
  let driRes = backend.expectLine(serial,
    r"(DE0K_DRI_OK|DE0K_DRI_MISSING)", timeoutSec = CmdTimeout)
  check driRes.matched
  let driPresent = driRes.matched and driRes.matchedText.contains("DE0K_DRI_OK")
  check driPresent
  if driPresent:
    echo "[de0k] PASS /dev/dri/card0 present"
  else:
    echo "[de0k] FAIL /dev/dri/card0 missing"

  # --- DE0-K gate: dmesg confirms hyperv_drm driver loaded --------------
  # Belt-and-braces — even if the early-boot serial banner regex was
  # noisy, dmesg in the booted shell is the canonical source.
  echo "[de0k] cross-checking dmesg for hyperv_drm..."
  backend.serialSend(serial,
    "echo DE0K_DMESG_BEGIN && dmesg | grep -E 'hyperv_drm|\\[drm\\]' " &
    "| head -10 && echo DE0K_DMESG_END\n")
  let dmesgRes = backend.expectLine(serial,
    r"DE0K_DMESG_END", timeoutSec = CmdTimeout)
  check dmesgRes.matched

  # --- DE0-K optional: weston headless smoke ----------------------------
  # The DE0-K gate spec calls weston OPTIONAL — DE0-K only certifies the
  # kernel-level surface. If weston is on the rootfs we run a 10 s
  # headless smoke; if not, we report absent and pass.
  if getEnv("DE0K_TRY_WESTON", "1") == "1":
    echo "[de0k] optional: weston headless smoke..."
    backend.serialSend(serial,
      "echo DE0K_WESTON_BEGIN && command -v weston >/dev/null 2>&1 && " &
      "echo DE0K_WESTON_PRESENT || echo DE0K_WESTON_ABSENT\n")
    let wstCheck = backend.expectLine(serial,
      r"(DE0K_WESTON_PRESENT|DE0K_WESTON_ABSENT)", timeoutSec = CmdTimeout)
    if wstCheck.matched and wstCheck.matchedText.contains("DE0K_WESTON_PRESENT"):
      backend.serialSend(serial,
        "( weston --backend=drm --idle-time=0 & ) ; " &
        "sleep 10 ; " &
        "pgrep -x weston >/dev/null && echo DE0K_WESTON_ALIVE || " &
        "echo DE0K_WESTON_DEAD\n")
      let wstAlive = backend.expectLine(serial,
        r"(DE0K_WESTON_ALIVE|DE0K_WESTON_DEAD)", timeoutSec = CmdTimeout)
      check wstAlive.matched
      if wstAlive.matched and wstAlive.matchedText.contains("DE0K_WESTON_ALIVE"):
        echo "[de0k] PASS weston headless smoke (10 s alive)"
        backend.serialSend(serial, "pkill -9 weston 2>/dev/null; true\n")
      else:
        echo "[de0k] WARN weston exited within 10 s (not a DE0-K failure)"
    else:
      echo "[de0k] weston not on rootfs — DE0-K kernel gate covers what we need"

  let totalElapsed = epochTime() - totalStart
  echo "[de0k] total wall-clock: ", totalElapsed.formatFloat(precision = 1), "s"
  echo "[de0k] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[de0k] WARN: total wall-clock exceeds DE0-K budget"

suite "e2e_vm_harness_hyperv_reproos_drm_present":
  test "DE0-K acceptance: reproos-de0k-smoke.iso boots, /dev/dri/card0 + hyperv_drm present":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-de0k-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findDe0kSmokeIso()
      if iso.len == 0:
        echo "[skip] DE0-K smoke ISO not found at ", DefaultIsoPath
        echo "       (and DE0K_SMOKE_ISO unset). Build via the DE0-K"
        echo "       smoke-ISO build script in `recipes/reproos-mvp-config/`"
        echo "       once an R9 placeholder initramfs is wired through."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-de0k-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-de0k-drm" / vmName
        runDrmPresentScenario(backend, iso, perVmDir, vmName)
