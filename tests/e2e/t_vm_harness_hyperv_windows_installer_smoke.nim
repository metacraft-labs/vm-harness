## e2e_vm_harness_hyperv_windows_installer_smoke
##
## Drives a Windows installer artifact through the full
## install → verify → uninstall lifecycle inside a Hyper-V guest VM,
## using only the vm-harness Tier-1 primitives (revertToBaseline,
## copyToGuest, execInGuest, copyFromGuest, stopAndCleanup).
##
## The test is BYO-installer: the path to the .exe under test and the
## install/verify/uninstall commands are supplied via environment
## variables, so any Windows-targeting project (codetracer, agent
## harbor, …) can reuse this as a canonical install-test pattern.
##
## Required env vars:
##
##   VMH_INSTALLER_HOST_PATH
##     Absolute host path to the installer `.exe` produced by the
##     build under test. Skipped if unset.
##
##   VMH_INSTALLER_VM_NAME       (default: ``repro-m69-hyperv``)
##     Hyper-V VM name to revert and exec inside.
##
##   VMH_INSTALLER_BASELINE      (default: ``base-clean``)
##     Snapshot to revert to before each lifecycle step.
##
##   VMH_INSTALLER_GUEST_INSTALL_DIR  (default: ``C:\CodeTracer``)
##     Where the installer is told to lay its tree down.
##
##   VMH_INSTALLER_GUEST_VERIFY_EXE   (default: ``ct.exe``)
##     Exe under ``<install-dir>\bin\`` that ``--version`` is invoked
##     against to prove the installer materialised a working binary.
##
##   VMH_INSTALLER_EXPECTED_VERSION_SUBSTRING  (default: ``CodeTracer version``)
##     Substring the verify-exe's stdout must contain.
##
##   VMH_INSTALLER_SILENT_FLAG        (default: ``/S``)
##     Silent-install flag the installer respects. NSIS uses ``/S``;
##     Inno Setup uses ``/VERYSILENT`` etc.
##
## Skips on non-Windows hosts (Hyper-V is Windows-only) and when the
## installer path env var is unset.

import std/[os, strutils, tables, tempfiles, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_windows_installer_smoke: " &
       "Windows host required"
  quit(0)

let installerHostPath = getEnv("VMH_INSTALLER_HOST_PATH")
if installerHostPath.len == 0:
  echo "[skip] t_vm_harness_hyperv_windows_installer_smoke: " &
       "VMH_INSTALLER_HOST_PATH unset"
  quit(0)

if not fileExists(installerHostPath):
  echo "[skip] t_vm_harness_hyperv_windows_installer_smoke: " &
       "installer not found at " & installerHostPath
  quit(0)

let vmName        = getEnv("VMH_INSTALLER_VM_NAME", "repro-m69-hyperv")
let baseline      = getEnv("VMH_INSTALLER_BASELINE", "base-clean")
let installDir    = getEnv("VMH_INSTALLER_GUEST_INSTALL_DIR", "C:\\CodeTracer")
let verifyExe     = getEnv("VMH_INSTALLER_GUEST_VERIFY_EXE", "ct.exe")
let expectedSub   = getEnv("VMH_INSTALLER_EXPECTED_VERSION_SUBSTRING",
                           "CodeTracer version")
let silentFlag    = getEnv("VMH_INSTALLER_SILENT_FLAG", "/S")
let guestInstallerPath = "C:\\vmh-staging\\" & extractFilename(installerHostPath)
let guestVerifyExe = installDir & "\\bin\\" & verifyExe

# Reprobuild adapter paths (the HyperVBackend wraps reprobuild's
# provision-base-vm.ps1 + run-hyperv-m69-system.ps1 when set; for a
# plain primitive test we don't need them, but the constructor accepts
# them for parity with the other e2e tests).
let runScript = getEnv("VMH_HYPERV_RUN_SCRIPT",
                       "D:\\metacraft\\reprobuild\\tools\\" &
                       "hyperv-m69-system\\run-hyperv-m69-system.ps1")
let provisionScript = getEnv("VMH_HYPERV_PROVISION_SCRIPT",
                             "D:\\metacraft\\reprobuild\\tools\\" &
                             "hyperv-m69-system\\provision-base-vm.ps1")
let credPath = getEnv("VMH_HYPERV_CRED_XML",
                      getHomeDir() / "AppData" / "Local" /
                      "Repro" / "hyperv-m69" / "vm-cred.xml")

suite "e2e_vm_harness_hyperv_windows_installer_smoke":
  test "install -> verify -> uninstall lifecycle via vm-harness primitives":
    let backend = newHyperVBackend(
      vmName = vmName,
      credentialCachePath = credPath,
      runScriptPath = runScript,
      provisionScriptPath = provisionScript,
      defaultGateTimeoutMinutes = 30)

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      quit(0)

    let outDir = createTempDir("vmh-installer-", "")
    defer: removeDir(outDir)

    # Step 1 — revert to the clean baseline so install state from a
    # prior gate run doesn't bleed in.
    let vm = backend.revertToBaseline(baseline)
    defer: backend.stopAndCleanup(vm, deleteVm = false)

    backend.startAndAwaitReady(vm, timeoutSec = 300)

    # Step 2 — stage the installer into the guest. The destination
    # directory is invented; the implicit mkdir lives inside
    # copyToGuest's PowerShell Direct wrapper.
    backend.copyToGuest(vm, installerHostPath, guestInstallerPath)

    # Step 3 — invoke the installer silently. NSIS conventions: ``/S``
    # silent + ``/D=<path>`` install-dir override. The /D= flag must
    # be LAST on the command line and must NOT be quoted (NSIS parses
    # the entire tail of argv as the path). All other installers
    # supply their own analog via VMH_INSTALLER_SILENT_FLAG /
    # VMH_INSTALLER_GUEST_INSTALL_DIR.
    let installResult = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @[guestInstallerPath, silentFlag, "/D=" & installDir],
      timeoutSec = 600)
    check installResult.exitCode == 0

    # Step 4 — prove the installer materialised the expected layout.
    let lsResult = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @["cmd.exe", "/c", "dir", installDir & "\\bin"],
      timeoutSec = 60)
    check lsResult.exitCode == 0
    check verifyExe in lsResult.stdout

    # Step 5 — run the verify exe and check the version string.
    let verifyResult = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @[guestVerifyExe, "--version"],
      timeoutSec = 60)
    check verifyResult.exitCode == 0
    check expectedSub in verifyResult.stdout

    # Step 6 — run the uninstaller the installer emitted. NSIS lays
    # ``Uninstall.exe`` at the install root; the silent flag matches
    # the installer's.
    let uninstResult = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @[installDir & "\\Uninstall.exe", silentFlag,
              "_?=" & installDir],
      timeoutSec = 300)
    check uninstResult.exitCode == 0

    # Step 7 — verify the install directory is gone. NSIS keeps the
    # outer dir if the uninstaller copy itself is still locked; we
    # accept either a missing dir or an empty one.
    let checkResult = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @["cmd.exe", "/c",
              "if exist " & installDir & "\\bin\\" & verifyExe &
                " (echo STILL_PRESENT) else (echo REMOVED)"],
      timeoutSec = 60)
    check checkResult.exitCode == 0
    check "REMOVED" in checkResult.stdout
