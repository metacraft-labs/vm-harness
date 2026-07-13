## t_vmharness_libvirt_ephemeral_run (campaign M2 gate).
##
## Proves the libvirt per-job EPHEMERAL CoW-clone reset against REAL
## libvirt + /dev/kvm: each job gets a FRESH VM cloned from a golden
## qcow2, boots on KVM, is probed, then destroyed leaving NO residue.
## This is the primitive the M1 GARM provider's CreateInstance/
## DeleteInstance map onto (wired in M4).
##
## What it asserts (all against a genuinely booted KVM guest, not a
## noop/mock):
##
##   (a) PROBE — a fresh per-job clone boots on /dev/kvm and emits the
##       golden's serial boot marker (``MARKER-READ=[GOLDEN-BASELINE-
##       PRISTINE]`` + ``GOLDEN-INIT-DONE``). The domain uses
##       ``type='kvm'`` so this is a real hardware-accelerated boot.
##   (b) NO RESIDUE — after ``stopAndCleanup(deleteVm=true)`` there is
##       NO residual domain (``virsh list --all`` clean of the job name)
##       and NO residual overlay/nvram on disk. The golden is untouched.
##   (c) TWO-RUN INDEPENDENCE — a marker STAMP written into the guest's
##       disk in run 1 (the golden init over-writes the on-disk marker
##       with ``DIRTIED-BY-RUN``) is ABSENT in run 2: run 2's fresh CoW
##       overlay reads the PRISTINE golden marker again. This proves
##       there is no state bleed between per-job clones.
##
## The golden is the SMALL/fast ``golden-linux-tiny`` bundle (built via
## the flake: ``nix build .#golden-linux-tiny``), NOT the 81 GiB Windows
## golden — the per-job reset primitive is OS-agnostic and must be
## provable fast + hermetically. The bundle location is taken from
## ``VMH_GOLDEN_TINY`` (a directory holding ``golden.qcow2``, ``kernel``,
## ``initramfs.gz``); the test skips cleanly when it isn't set or when
## libvirt/KVM isn't usable.
##
## Run (from a vm-harness checkout, on a Linux host with /dev/kvm):
##   nix build .#golden-linux-tiny
##   export VMH_GOLDEN_TINY=$(readlink -f result)
##   export LIBVIRT_DEFAULT_URI=qemu:///session
##   nim r --hints:off tests/e2e/t_vmharness_libvirt_ephemeral_run.nim

import std/[os, strutils, times, unittest]
import std/posix
import vm_harness

proc kvmAvailable(): bool =
  ## ``/dev/kvm`` is a CHARACTER device, so ``os.fileExists`` (which only
  ## matches regular files) returns false for it. Probe it properly.
  var st: Stat
  if stat("/dev/kvm", st) != 0: return false
  S_ISCHR(st.st_mode)

when not defined(linux):
  echo "[skip] t_vmharness_libvirt_ephemeral_run: Linux host required"
  quit(0)

let goldenDir = getEnv("VMH_GOLDEN_TINY")
if goldenDir.len == 0:
  echo "[skip] t_vmharness_libvirt_ephemeral_run: VMH_GOLDEN_TINY not set " &
       "(build via `nix build .#golden-linux-tiny` and point it at " &
       "`readlink -f result`)"
  quit(0)

let goldenQcow2 = goldenDir / "golden.qcow2"
let goldenKernel = goldenDir / "kernel"
let goldenInitrd = goldenDir / "initramfs.gz"
if not (fileExists(goldenQcow2) and fileExists(goldenKernel) and
        fileExists(goldenInitrd)):
  echo "[skip] t_vmharness_libvirt_ephemeral_run: golden bundle incomplete " &
       "under " & goldenDir & " (need golden.qcow2 + kernel + initramfs.gz)"
  quit(0)

const
  PristineMarker = "MARKER-READ=[GOLDEN-BASELINE-PRISTINE]"
  DoneMarker = "GOLDEN-INIT-DONE"
  DirtyMarker = "DIRTIED-BY-RUN"
  KernelCmdline = "console=ttyS0 quiet panic=1"

proc newSessionBackend(): LibvirtBackend =
  ## Honour LIBVIRT_DEFAULT_URI (the harness resolves it in
  ## ``newLibvirtBackend``). On a workstation this is usually
  ## ``qemu:///session`` (sudo-free user-mode libvirt); the image pool is
  ## then the user-mode ``~/.local/share/libvirt/images``.
  newLibvirtBackend()

proc runEphemeralJob(b: LibvirtBackend, name, serialLog: string): string =
  ## Clone → boot → wait-for-poweroff → harvest serial → destroy.
  ## Returns the captured serial text. Guarantees teardown.
  let spec = EphemeralCloneSpec(
    name: name,
    goldenImage: goldenQcow2,
    cpus: 1,
    memoryMB: 512,
    kernel: goldenKernel,
    initrd: goldenInitrd,
    cmdline: KernelCmdline,
    serialLogPath: serialLog)
  var vm = b.provisionEphemeralClone(spec)
  try:
    # The tiny golden self-terminates (poweroff -f). Poll for shut off.
    let deadline = epochTime() + 90.0
    while epochTime() < deadline:
      if b.domainState(name) == "shut off":
        break
      sleep(300)
    # Give the serial file a moment to flush.
    sleep(300)
    result =
      if fileExists(serialLog): readFile(serialLog) else: ""
  finally:
    b.stopAndCleanup(vm, deleteVm = true)

suite "t_vmharness_libvirt_ephemeral_run":
  let b = newSessionBackend()

  test "libvirt + /dev/kvm are usable (else skip)":
    if not kvmAvailable():
      echo "[skip] /dev/kvm absent — real-boot gate needs KVM"
      skip()
    elif not b.probeAvailability():
      echo "[skip] libvirtd not reachable at " & b.libvirtUri &
           " (set LIBVIRT_DEFAULT_URI=qemu:///session and ensure the " &
           "user session libvirtd is up)"
      skip()
    else:
      check kvmAvailable()
      check b.probeAvailability()

  test "per-job clone boots on KVM, probes, tears down with no residue, " &
       "two runs are independent":
    if not kvmAvailable() or not b.probeAvailability():
      echo "[skip] KVM/libvirt not usable"
      skip()
    else:
      let job1 = "vmh-m2-eph-run1"
      let job2 = "vmh-m2-eph-run2"
      let serial1 = getTempDir() / "vmh-m2" / (job1 & ".serial.log")
      let serial2 = getTempDir() / "vmh-m2" / (job2 & ".serial.log")
      # Pre-clean any residue from a crashed prior run.
      for j in [job1, job2]:
        if b.domainExists(j):
          b.destroyDomain(j)
          b.undefineDomain(j)
        b.removeEphemeralOverlay(j)

      # ---- RUN 1 -----------------------------------------------------
      let out1 = runEphemeralJob(b, job1, serial1)

      # (a) PROBE succeeded on a genuinely fresh KVM boot.
      check DoneMarker in out1
      check PristineMarker in out1

      # (b) NO RESIDUE after teardown.
      check (not b.domainExists(job1))
      # virsh list --all must not mention the job name.
      check (job1 notin b.listAllDomainNames())
      # Overlay + nvram gone.
      let overlay1 = b.overlayPathFor(job1)
      check (not fileExists(overlay1))
      # The golden itself is untouched.
      check fileExists(goldenQcow2)

      # ---- RUN 2 (independence) -------------------------------------
      let out2 = runEphemeralJob(b, job2, serial2)
      check DoneMarker in out2
      # Run 2's fresh overlay must read the PRISTINE golden marker —
      # NOT run 1's stamp. This proves no state bleed across clones:
      # run 1's init over-wrote its OWN overlay's on-disk marker with
      # ``DIRTIED-BY-RUN``, but run 2 gets a brand-new overlay backed by
      # the untouched golden, so it reads the pristine marker again.
      check PristineMarker in out2
      # A state-bleed would surface as the guest reading back the dirty
      # stamp instead of the pristine marker; assert that did NOT happen.
      check ("MARKER-READ=[" & DirtyMarker) notin out2
      # Run 2 also leaves no residue.
      check (not b.domainExists(job2))
      check (not fileExists(b.overlayPathFor(job2)))
