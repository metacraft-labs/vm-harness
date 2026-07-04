## t_windows_golden_jit_boot (campaign M3 gate).
##
## Proves the ephemeral Windows JIT-injection MECHANISM end-to-end on a real
## KVM boot of a FRESH CoW clone of the cloudbase-init golden, with NO live
## GitHub (a mock GARM metadata + actions endpoint stands in):
##
##   * a Windows guest booted from the cloudbase-init golden consumes an
##     INJECTED config-drive (openstack/latest/{meta_data.json,user_data})
##     carrying GARM's Windows JIT bootstrap;
##   * on first boot the bootstrap fetches the JIT/registration material
##     (.runner/.credentials/.credentials_rsaparams/service-name) from the
##     MOCK GARM metadata endpoint, authorized by a per-instance JWT
##     (no-JWT -> 401);
##   * it launches Runner.Listener with the injected JIT config, which
##     authenticates + connects to the mock as its Actions server and
##     attempts to create a runner session (i.e. reaches the "configured /
##     listening for one job" phase);
##   * the clone is torn down via the ephemeral path leaving NO residue
##     (domain/overlay/config-drive/nvram), and the golden is untouched.
##
## The whole flow is orchestrated by the sibling driver
## ``windows-jit/run-windows-jit-gate.sh`` (it mixes qemu-img/virsh/python
## mock/sshpass); this Nim wrapper discovers the config, runs the driver in
## the FOREGROUND, streams its log, and asserts the driver reached
## ``M3_GATE_PASS`` (each sub-assertion is a ``PASS (x)`` line the driver
## emits). It SELF-SKIPS cleanly when the golden / OVMF / KVM / tooling
## isn't present.
##
## Config (env):
##   VMH_WIN_GOLDEN      cloudbase-init golden qcow2
##                       (default /storage/iso/golden-win11-cloudbase.qcow2)
##   VMH_OVMF_CODE       OVMF code fd
##                       (default /run/libvirt/nix-ovmf/edk2-x86_64-code.fd)
##   VMH_OVMF_VARS       OVMF vars template
##                       (default /run/libvirt/nix-ovmf/edk2-i386-vars.fd)
##   VMH_GUEST_PASSWORD  guest admin password (default repro-windows-x64)
##   LIBVIRT_DEFAULT_URI libvirt URI (default qemu:///system)
##
## Run (on the runner host, /dev/kvm + a system libvirtd + the golden):
##   export VMH_GUEST_PASSWORD=repro-windows-x64
##   nim r --hints:off --path:src tests/e2e/t_windows_golden_jit_boot.nim

import std/[os, osproc, strutils, unittest]
import std/posix

proc kvmAvailable(): bool =
  var st: Stat
  if stat("/dev/kvm", st) != 0: return false
  S_ISCHR(st.st_mode)

when not defined(linux):
  echo "[skip] t_windows_golden_jit_boot: Linux host required"
  quit(0)

let scriptDir = currentSourcePath().parentDir / "windows-jit"
let driver = scriptDir / "run-windows-jit-gate.sh"

let golden = getEnv("VMH_WIN_GOLDEN",
  "/storage/iso/golden-win11-cloudbase.qcow2")
let ovmfCode = getEnv("VMH_OVMF_CODE",
  "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd")
let ovmfVars = getEnv("VMH_OVMF_VARS",
  "/run/libvirt/nix-ovmf/edk2-i386-vars.fd")
let guestPw = getEnv("VMH_GUEST_PASSWORD", "repro-windows-x64")

proc haveTool(t: string): bool = findExe(t).len > 0

suite "t_windows_golden_jit_boot":
  test "prerequisites present (else skip)":
    if not kvmAvailable():
      echo "[skip] /dev/kvm absent"; skip()
    elif not fileExists(golden):
      echo "[skip] golden not found: " & golden; skip()
    elif not (fileExists(ovmfCode) and fileExists(ovmfVars)):
      echo "[skip] OVMF firmware not found"; skip()
    elif not (haveTool("virsh") and haveTool("qemu-img") and
              haveTool("python3") and haveTool("sshpass") and
              (haveTool("genisoimage") or haveTool("xorriso"))):
      echo "[skip] required tooling missing " &
        "(virsh/qemu-img/python3/sshpass/genisoimage|xorriso)"; skip()
    else:
      check kvmAvailable()
      check fileExists(golden)

  test "ephemeral Windows clone: config-drive JIT injection -> runner " &
       "reaches configured/listening against the mock -> clean teardown":
    if not (kvmAvailable() and fileExists(golden) and
            fileExists(ovmfCode) and fileExists(ovmfVars) and
            haveTool("virsh") and haveTool("qemu-img") and
            haveTool("python3") and haveTool("sshpass") and
            (haveTool("genisoimage") or haveTool("xorriso"))):
      echo "[skip] prerequisites not satisfied"; skip()
    else:
      putEnv("VMH_WIN_GOLDEN", golden)
      putEnv("VMH_OVMF_CODE", ovmfCode)
      putEnv("VMH_OVMF_VARS", ovmfVars)
      putEnv("VMH_GUEST_PASSWORD", guestPw)
      # Run the driver in the foreground; stream its output.
      let (output, exitCode) = execCmdEx(
        "bash " & quoteShell(driver),
        options = {poStdErrToStdOut})
      echo output
      if exitCode == 3 or "SKIP" in output.splitLines()[^1]:
        echo "[skip] driver self-skipped (missing golden/tooling)"
        skip()
      else:
        # Each sub-assertion the driver proves must be present, and it must
        # end with M3_GATE_PASS.
        check "PASS (a):" in output   # JWT-authorized JIT delivery
        check "PASS (a'):" in output  # no-JWT rejected (401)
        check "PASS (b):" in output   # Runner.Listener launched w/ JIT
        check "PASS (c):" in output   # runner attempted a session
        check "PASS (d):" in output   # clean teardown, no residue
        check "M3_GATE_PASS" in output
        check exitCode == 0
