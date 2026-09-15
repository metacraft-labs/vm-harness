## Runner-Fleet-M3-ARM-Wave MA3 gate: ``t_qemu_windows_arm_golden_build``
## — HOST TIER. Opt-in. Runs the real thing: a full unattended Windows ARM64
## install, ``sysprep /generalize``, power-off and promotion to a validated
## golden, then boots two clones of it and requires them to have DISTINCT
## machine SIDs.
##
## The unit tier of the same gate is
## ``tests/unit/t_qemu_windows_arm_golden_build.nim``. It runs everywhere and
## does NOT cover what is asserted here: no unit test can say that Windows
## Setup accepted the answer file, that HVF tolerated the install's reboot
## sequence, or that ``/generalize`` really re-minted the SID. This file is
## where those are found out, and it is the gate MA4 runs on m3.
##
## THIS TEST NEVER PASSES QUIETLY. Every precondition it lacks is named, in
## the message, with the environment variable that supplies it. It is opt-in
## because a single run is a ~60 minute host operation that allocates tens of
## gigabytes on a machine that is also serving CI — not because it is
## optional.
##
## Preconditions, all required:
##
##   VMH_WINDOWS_ARM_GOLDEN_HOST_TEST=1   explicit opt-in
##   VMH_WINDOWS_ARM_ISO=<path>           operator-supplied Windows 11 ARM64
##                                        ISO (on m3:
##                                        /Users/zahary/iso/Win11_25H2_English_Arm64_v2.iso)
##   VMH_WINDOWS_ARM_AUTOUNATTEND_ISO=<path>
##                                        built by
##                                        guest-recipes/windows-arm-base/
##                                        build-autounattend-iso.sh
##   a macOS aarch64 host with qemu-system-aarch64, swtpm and sshpass
##
## Optional:
##   VMH_WINDOWS_ARM_GOLDEN_OUT=<dir>     parent directory for the versioned
##                                        build directory (default: a temp
##                                        dir). MA4 points this at
##                                        /private/var/lib/vm-harness/
##                                        qemu-windows-arm/golden.
##   VMH_WINDOWS_ARM_GOLDEN_DEADLINE=<s>  overall deadline (default 5400)
##   VMH_WINDOWS_ARM_GOLDEN_DISK_GB=<n>   requested qcow2 size (default 64)
##
## The build directory is deliberately NOT removed on success: this gate
## produces the artifact MA4 promotes, and promotion is a pointer flip onto a
## directory that already exists. It is also not removed on failure, because
## the serial log and QEMU log inside it are the only diagnostics a failed
## Windows install leaves.

import std/[os, strutils, tables, tempfiles, times, unittest]
import vm_harness

const
  OptInEnv = "VMH_WINDOWS_ARM_GOLDEN_HOST_TEST"
  WindowsIsoEnv = "VMH_WINDOWS_ARM_ISO"
  AutounattendIsoEnv = "VMH_WINDOWS_ARM_AUTOUNATTEND_ISO"
  OutDirEnv = "VMH_WINDOWS_ARM_GOLDEN_OUT"

proc missingPreconditions(): seq[string] =
  ## Every unmet precondition, named. Collected rather than short-circuited
  ## so one run tells the operator everything that is missing.
  when not defined(macosx):
    result.add("a macOS host (this gate drives qemu-system-aarch64 under " &
               "HVF; the Linux equivalent is the libvirt path)")
  when not (defined(arm64) or defined(arm)):
    result.add("an aarch64 host (a Windows ARM64 guest cannot run under " &
               "HVF on x86_64)")
  if getEnv(OptInEnv) != "1":
    result.add(OptInEnv & "=1 (this gate performs a real ~60 minute " &
               "Windows install and allocates tens of GB; it is never run " &
               "implicitly)")
  let winIso = getEnv(WindowsIsoEnv)
  if winIso.len == 0:
    result.add(WindowsIsoEnv & "=<path to a Windows 11 ARM64 ISO> (an " &
               "operator-supplied input; the harness never downloads it)")
  elif not fileExists(winIso):
    result.add(WindowsIsoEnv & " points at " & winIso & ", which does not " &
               "exist")
  let unattendIso = getEnv(AutounattendIsoEnv)
  if unattendIso.len == 0:
    result.add(AutounattendIsoEnv & "=<path to autounattend.iso>, built by " &
               "guest-recipes/windows-arm-base/build-autounattend-iso.sh")
  elif not fileExists(unattendIso):
    result.add(AutounattendIsoEnv & " points at " & unattendIso &
               ", which does not exist")

proc recipeDir(): string =
  currentSourcePath().parentDir.parentDir.parentDir /
    "guest-recipes" / "windows-arm-base"

proc guestMachineSid(b: QemuWindowsArmBackend, vm: VmHandle): string =
  ## The machine SID as the guest itself reports it. ``whoami /user`` prints
  ## the logged-on account's SID; the machine SID is that without its RID.
  let r = b.execInGuest(vm, initTable[string, string](),
                        @["cmd.exe", "/c", "whoami /user"], timeoutSec = 120)
  doAssert r.exitCode == 0,
    "whoami /user failed in the guest (exit " & $r.exitCode & "): " &
    r.stdout & r.stderr
  for token in r.stdout.splitWhitespace():
    if token.toUpperAscii().startsWith("S-1-5-21-"):
      return machineSidFromUserSid(token)
  doAssert false, "no S-1-5-21-... SID in `whoami /user` output: " & r.stdout

suite "t_qemu_windows_arm_golden_build (host tier)":

  test "a real install, sysprep and promotion produce a usable golden":
    let missing = missingPreconditions()
    if missing.len > 0:
      echo "[skip] t_qemu_windows_arm_golden_build (host tier) needs:"
      for m in missing:
        echo "         - " & m
      echo "       Nothing was built and nothing was asserted. This is a " &
           "SKIP, not a pass."
      skip()
    else:
      let b = QemuWindowsArmBackend(newBackend(biQemuWindowsArm))
      doAssert b.probeAvailability(),
        "qemu-system-aarch64, swtpm or sshpass is missing from PATH"

      let outParent =
        if getEnv(OutDirEnv).len > 0: getEnv(OutDirEnv)
        else: createTempDir("vmh-win-arm-golden-", "")
      createDir(outParent)
      let buildId = now().utc.format("yyyyMMdd'T'HHmmss'Z'")
      let buildDir = outParent / ("win-arm-runner-" & buildId)

      let golden = b.buildWindowsArmGolden(newGoldenBuildSpec(
        buildDir = buildDir,
        windowsIso = getEnv(WindowsIsoEnv),
        autounattendIso = getEnv(AutounattendIsoEnv),
        recipeDir = recipeDir(),
        diskGB = parseInt(getEnv("VMH_WINDOWS_ARM_GOLDEN_DISK_GB", "64")),
        deadlineSec = parseInt(
          getEnv("VMH_WINDOWS_ARM_GOLDEN_DEADLINE", "5400"))))

      # The consuming path must accept it unchanged.
      check golden == absolutePath(buildDir)
      check validateWindowsArmVmDir(golden) == absolutePath(buildDir)
      check fileExists(golden / QwaBaseDiskName)
      check fileExists(golden / QwaGoldenManifestName)
      # Diagnostics survive a SUCCESSFUL run too; they are the record of
      # what this particular install did.
      check fileExists(golden / "serial.log")

      echo "[t_qemu_windows_arm_golden_build] golden built at " & golden
      echo readFile(golden / QwaGoldenManifestName)

      # /generalize is the whole reason sysprep is in this pipeline. Two
      # clones of a golden that skipped it share one machine SID, and a
      # fleet of runners with one SID is the defect this asserts against.
      b.provisionBaseline(BaselineSpec(name: "win-arm-runner",
                                       sourceImage: golden))
      var sids: seq[string] = @[]
      for i in 1 .. 2:
        let vm = b.revertToBaseline("win-arm-runner")
        try:
          sids.add(b.guestMachineSid(vm))
        finally:
          b.stopAndCleanup(vm, deleteVm = true)
      echo "[t_qemu_windows_arm_golden_build] clone machine SIDs: " &
           sids.join(", ")
      check sids.len == 2
      check sids[0].len > 0
      check sids[1].len > 0
      check sids[0] != sids[1]
