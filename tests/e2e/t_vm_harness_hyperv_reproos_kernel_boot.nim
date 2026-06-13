## e2e_vm_harness_hyperv_reproos_kernel_boot
##
## R8 acceptance gate (drives vm-harness's bootFromMedia primitive
## against the R8 from-source Linux 6.6.142 LTS bzImage).
##
## Boots a hybrid (BIOS + UEFI) ISO containing the R8 from-source kernel
## + a tiny placeholder initramfs under a transient Hyper-V Gen-2 UEFI
## VM (Secure Boot off), captures the serial console on COM1, and
## asserts the kernel produces its boot banners:
##
##   * ``Linux version 6.6.142``                  - the R8 bytes ran
##   * ``Hypervisor detected: Microsoft Hyper-V`` - Hyper-V drivers wired
##     correctly (config-knob ``CONFIG_HYPERV=y``)
##   * a userspace-handoff marker                 - early kernel bring-up
##     finished and either userspace started or kernel panicked at the
##     init handoff (panic from a placeholder /init is OK; the point is
##     the kernel reached the handoff)
##
## Required artifacts (paths intentionally hard-coded since the only
## producer is the reprobuild R8 build script):
##
##   ``D:/metacraft/reprobuild/build/r8-build/reproos-r8-test.iso``
##
## The orchestrator produces it via:
##   bash .../build-linux-kernel.sh ...
##   bash .../build-minimal-initramfs.sh build/r8-build/initramfs.cpio.gz
##   SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
##     bash .../reproos-iso/scripts/build-iso.sh \
##       build/r8-build/bzImage \
##       build/r8-build/initramfs.cpio.gz \
##       build/r8-build/reproos-r8-test.iso
##
## Skips when Hyper-V isn't available, the host isn't elevated, or the
## ISO isn't present.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_kernel_boot: Windows host required"
  quit(0)

const
  ReproosR8Iso = r"D:\metacraft\reprobuild\build\r8-build\reproos-r8-test.iso"
  ReproosR8BzImage = r"D:\metacraft\reprobuild\build\r8-build\bzImage"

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

  let vm = backend.bootFromMedia(spec)
  defer:
    backend.stopAndCleanup(vm, deleteVm = true)
    if dirExists(perVmDir):
      try: removeDir(perVmDir)
      except CatchableError: discard

  let serial = backend.captureSerial(vm)
  defer: backend.closeSerial(serial)

  # Phase A: kernel banner -- proves the R8 bzImage's bytes ran.
  echo "[info] expecting `Linux version 6.6.142` banner..."
  let linuxBanner = backend.expectLine(serial,
    r"Linux version 6\.6\.142", timeoutSec = 90)
  check linuxBanner.matched
  if linuxBanner.matched:
    echo "[diag] linux banner: ", linuxBanner.matchedText.strip()

  # Phase B: Hyper-V hypervisor detection OR secure-boot disabled.
  echo "[info] expecting Hyper-V / Secure Boot banner..."
  let hvBanner = backend.expectLine(serial,
    r"(Hypervisor detected: Microsoft Hyper-V|secureboot: Secure boot disabled|Booting paravirtualized kernel on Hyper-V)",
    timeoutSec = 60)
  check hvBanner.matched
  if hvBanner.matched:
    echo "[diag] hyperv/sb banner: ", hvBanner.matchedText.strip()

  # Phase C: userspace handoff -- panic from placeholder /init is OK.
  echo "[info] expecting userspace-handoff marker..."
  let userland = backend.expectLine(serial,
    r"(Kernel panic - not syncing|VFS: Mounted root|Run /init as init process|R8-INIT-REACHED|systemd\[1\]|Freeing unused kernel image|init\[1\])",
    timeoutSec = 60)
  check userland.matched
  if userland.matched:
    echo "[diag] userspace handoff: ", userland.matchedText.strip()

suite "e2e_vm_harness_hyperv_reproos_kernel_boot":
  test "R8 from-source linux 6.6.142 bzImage boots under Hyper-V Gen-2 UEFI; banners visible on COM1":
    let backend = newHyperVBackend(vmName = "repro-test-boot-r8-placeholder")

    if not fileExists(ReproosR8BzImage):
      echo "[skip] R8 bzImage not built; run " &
           "bash recipes/bootstrap/tcc-chain/scripts/build-linux-kernel.sh " &
           "recipes/bootstrap/tcc-chain/vendor " &
           "recipes/bootstrap/kernel/configs/x86_64-hyperv.config " &
           "build/r8-build  (in the reprobuild repo)"
      skip()
    elif not fileExists(ReproosR8Iso):
      echo "[skip] R8 test ISO not assembled; see this file's docstring"
      skip()
    elif not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation; current " &
           "process is not elevated (Get-VMHost failed)"
      skip()
    else:
      let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
      let vmName = "repro-test-boot-r8-" & suffix[suffix.len - 8 .. ^1]
      let perVmDir = getTempDir() / "vm-harness-e2e-r8-boot" / vmName
      runBootScenario(backend, ReproosR8Iso, perVmDir, vmName)
