## e2e_vm_harness_hyperv_systemd_boot
##
## R1 Path B in vm-harness: boot a vendored Debian generic-cloud VHDX
## under a transient Hyper-V Gen-2 UEFI VM (Secure Boot off) with a
## cloud-init NoCloud seed ISO, then assert that systemd reaches PID 1,
## cloud-init's final-message fires, and a serial-getty login prompt
## arrives on COM1.
##
## This test is the canonical Nim replacement for the Python
## ``reprobuild/recipes/reproos-ref-iso/boot-test-hyperv.py`` that
## previously drove the same scenario via a parallel Python boot
## harness. The Nim version goes through the same vm-harness primitives
## the rest of the campaign uses (``bootFromMedia`` + ``captureSerial``
## + ``expectLine`` + ``serialSend`` + ``stopAndCleanup``) and embeds
## the cloud-init NoCloud seed ISO9660 builder directly (see
## ``src/vm_harness/cloud_init_seed.nim``).
##
## Required artifacts:
##
## - A Windows host with Hyper-V installed AND an elevated process
##   (Hyper-V cmdlets require admin). The test SKIPs if elevation is
##   unavailable (NEVER silently passes).
## - The vendored Debian generic-cloud VHDX at:
##
##     $env:VMH_DEBIAN_CLOUD_VHDX (if set), or
##     $env:LOCALAPPDATA\repro-boot-harness-cache\debian-12-genericcloud-amd64.vhdx, or
##     D:\metacraft\reprobuild\recipes\reproos-ref-iso\vendor\debian-12-genericcloud-amd64.vhdx
##
##   When none of the above are present the test SKIPs with a clear
##   reason. Use ``recipes/reproos-ref-iso/vendor/fetch.ps1`` +
##   ``convert-cloud-image.ps1`` in reprobuild to produce the VHDX.
##
## Skips when Hyper-V isn't available, elevation isn't held, or none of
## the VHDX candidates exist.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness
import vm_harness/cloud_init_seed

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_systemd_boot: Windows host required"
  quit(0)

# ---------------------------------------------------------------------------
# Probe helpers.

proc isElevated(): bool =
  ## Best-effort elevation probe: try a Hyper-V cmdlet that requires
  ## admin and see if it succeeds. ``Get-VMHost`` is sufficient.
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

proc findVhdx(): string =
  var candidates: seq[string] = @[]
  let envOverride = getEnv("VMH_DEBIAN_CLOUD_VHDX")
  if envOverride.len > 0:
    candidates.add(envOverride)
  let localAppData = getEnv("LOCALAPPDATA")
  if localAppData.len > 0:
    candidates.add(localAppData / "repro-boot-harness-cache" /
                   "debian-12-genericcloud-amd64.vhdx")
  candidates.add("D:\\metacraft\\reprobuild\\recipes\\reproos-ref-iso\\" &
                 "vendor\\debian-12-genericcloud-amd64.vhdx")
  for c in candidates:
    if fileExists(c):
      return c
  return ""

# ---------------------------------------------------------------------------
# Cloud-init seed.

const UserData = """#cloud-config
chpasswd:
  expire: false
  users:
    - {name: root, password: ReproOS, type: text}
    - {name: debian, password: ReproOS, type: text}

ssh_pwauth: true
disable_root: false

runcmd:
  - [systemctl, enable, --now, serial-getty@ttyS0.service]

final_message: "R1-CLOUD-INIT-FINAL: cloud-init completed in $UPTIME seconds"
"""

const MetaData = """instance-id: repro-r1
local-hostname: repro-r1
"""

# ---------------------------------------------------------------------------
# Scenario body.

proc runBootScenario(backend: HyperVBackend, vhdx, perVmDir: string,
                    vmName: string) =
  ## Copy the vendored VHDX into a per-VM disposable, build the NoCloud
  ## seed ISO, boot the VM, drive the assertions, and clean everything
  ## up in finally.
  createDir(perVmDir)
  let bootVhdx = perVmDir / (vmName & ".boot.vhdx")
  let seedIso = perVmDir / (vmName & ".seed.iso")

  # Per-VM disposable copy: cloud-init mutates the disk on boot. We
  # never want to modify the vendored VHDX.
  echo "[info] copying vendored VHDX -> per-VM disposable: ", bootVhdx
  copyFile(vhdx, bootVhdx)

  # Build the NoCloud seed inline.
  echo "[info] writing NoCloud seed ISO -> ", seedIso
  writeNoCloudIso(seedIso, UserData, MetaData, "CIDATA")

  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkVhdx,
    mediaPath: bootVhdx,
    secondaryIsoPath: seedIso,
    cpus: 2,
    memoryMB: 2048,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let vm = backend.bootFromMedia(spec)
  defer:
    # Ensure the per-VM dir is gone after the VM is removed, in case
    # stopAndCleanup's own removeDir was racy.
    backend.stopAndCleanup(vm, deleteVm = true)
    if dirExists(perVmDir):
      try: removeDir(perVmDir)
      except CatchableError: discard

  let serial = backend.captureSerial(vm)
  defer: backend.closeSerial(serial)

  # Phase A: systemd PID 1.
  echo "[info] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial, r"systemd\[1\]:", timeoutSec = 120)
  check pid1.matched
  if pid1.matched:
    echo "[diag] systemd[1]: matched in ", pid1.elapsedMs, " ms: ",
         pid1.matchedText.strip()

  # Phase B: cloud-init final marker.
  echo "[info] expecting R1-CLOUD-INIT-FINAL marker..."
  let ciFinal = backend.expectLine(serial,
    r"R1-CLOUD-INIT-FINAL: cloud-init completed",
    timeoutSec = 180)
  check ciFinal.matched
  if ciFinal.matched:
    echo "[diag] cloud-init final marker: ", ciFinal.matchedText.strip()

  # Phase C: login prompt on COM1.
  echo "[info] expecting login: prompt on COM1..."
  let login = backend.expectLine(serial,
    r"(login:|Debian GNU/Linux.*tty)", timeoutSec = 180)
  check login.matched
  if login.matched:
    echo "[diag] login prompt: ", login.matchedText.strip()

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_systemd_boot":
  test "Debian cloud VHDX boots under Hyper-V Gen-2 UEFI; systemd reaches PID 1; cloud-init runs; login prompt arrives":
    let backend = newHyperVBackend(vmName = "repro-test-boot-hv-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation; current " &
           "process is not elevated (Get-VMHost failed)"
      skip()
    else:
      let vhdx = findVhdx()
      if vhdx.len == 0:
        echo "[skip] Debian generic-cloud VHDX not found. Set " &
             "VMH_DEBIAN_CLOUD_VHDX or run " &
             "`pwsh recipes/reproos-ref-iso/vendor/fetch.ps1` then " &
             "`pwsh recipes/reproos-ref-iso/vendor/convert-cloud-image.ps1` " &
             "in reprobuild"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-hv-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-boot" / vmName
        runBootScenario(backend, vhdx, perVmDir, vmName)
