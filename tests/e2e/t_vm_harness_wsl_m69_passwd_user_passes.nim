## e2e_vm_harness_wsl_m69_passwd_user_passes (M1 verification).
##
## *STATUS: pending* — this test verifies that driving the M69
## ``passwd.user`` POSIX destructive gate through the new WslBackend
## produces the same PASS verdict as the legacy direct invocation of
## ``run-wsl-m69-posix.ps1``. The test requires:
##
## - A Windows host with WSL2 installed.
## - The Ubuntu jammy rootfs tarball already cached on disk.
## - Reprobuild's ``tools/wsl-m69-posix/run-wsl-m69-posix.ps1`` present
##   at the path supplied via ``$VMH_WSL_RUN_SCRIPT`` (or the harness's
##   hard-coded default).
## - The reprobuild + runquota source trees present at their canonical
##   ``D:\metacraft\reprobuild``, ``D:\metacraft\runquota`` paths
##   (the bash provisioning script reads them via the 9P /mnt/ bridge).
##
## On non-Windows hosts the test exits early. Marked ``status:
## pending`` in the milestone file pending Windows-host verification.
##
## The harness runs the WHOLE WSL M69 + M83 gate batch (the existing
## bash provisioning script doesn't expose per-gate dispatch). We
## assert that the ``passwd.user`` gate specifically reaches PASS by
## scanning the resulting ``RESULT.txt`` for its row, in addition to
## the overall VERDICT: PASS gate.

import std/[os, strutils, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_wsl_m69_passwd_user_passes: Windows host required"
  quit(0)

suite "e2e_vm_harness_wsl_m69_passwd_user_passes":
  test "passwd.user gate via WslBackend reaches PASS":
    let runScript = getEnv("VMH_WSL_RUN_SCRIPT",
                          "D:\\metacraft\\reprobuild\\tools\\" &
                          "wsl-m69-posix\\run-wsl-m69-posix.ps1")
    let rootfs = getEnv("VMH_WSL_ROOTFS", DefaultRootfsTarballPath)

    let backend = newWslBackend(
      distroPrefix = "vmh-e2e-wsl",
      rootfsTarballPath = rootfs,
      runScriptPath = runScript,
      defaultTimeoutMinutes = 60)

    let outDir = "D:\\metacraft\\wsl-m69-posix-out"

    let result = backend.runViaReproScript(
      timeoutMinutes = 60,
      outDirOverride = outDir)

    check result.done
    check result.verdict.kind == svPass

    # Scan steps for the passwd.user row specifically.
    var sawPasswdPass = false
    for step in result.steps:
      if step.name.contains("passwd") and
         (step.status.contains("PASS") or step.status.contains("OK")):
        sawPasswdPass = true
        break
    check sawPasswdPass
