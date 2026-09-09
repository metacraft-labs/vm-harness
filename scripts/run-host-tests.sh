#!/usr/bin/env bash
set -euo pipefail

run_nim() {
  echo
  echo "==> nim $*"
  nim "$@"
}

# These gates require a real host hypervisor or daemon. They are intentionally
# separate from the ephemeral Nix CI matrix: a Tart macOS guest is not itself
# a supported Tart/UTM/Lima host, and a plain Incus guest is not a libvirt or
# nested-Incus host.

# Windows host: Hyper-V and WSL.
run_nim r --hints:off tests/integration/t_hyperv_lifecycle.nim
run_nim r --hints:off tests/integration/t_wsl_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_hyperv_m69_feature_capability_passes.nim
run_nim r --hints:off tests/e2e/t_vm_harness_wsl_m69_passwd_user_passes.nim
run_nim r --hints:off --threads:on tests/e2e/t_vm_harness_wsl_systemd_boot.nim
run_nim r --hints:off --threads:on tests/e2e/t_vm_harness_hyperv_systemd_boot.nim
# RA4 remoting on a SECOND Windows host: a remote client drives a per-job
# ephemeral Hyper-V VM (New-VHD/New-VM-from-golden -> boot -> JIT-probe ->
# Remove-VM, no residue) through `vm-harness serve`. Needs a golden VHDX in
# $VMH_HYPERV_GOLDEN; self-skips off-Windows / without Hyper-V / without it.
run_nim r --hints:off tests/e2e/t_vmharness_serve_win_hyperv.nim

# macOS host: Tart, UTM, and Lima.
run_nim r --hints:off tests/integration/t_tart_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_linux_arm_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_macos_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_cleanup_on_failure.nim
# RA5 remoting on the macOS/tart host (m3): a remote client drives a per-job
# ephemeral tart guest (clone-from-golden -> boot -> in-guest probe -> destroy,
# no residue) through `vm-harness serve`. Defaults to the cheap Linux-ARM
# golden; set VMH_TART_SERVE_MACOS=1 for the macOS golden. Self-skips off-macOS
# / without tart+sshpass.
run_nim r --hints:off tests/e2e/t_vmharness_serve_macos_tart.nim
run_nim r --hints:off tests/integration/t_utm_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_utm_windows_arm_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_utm_windows_dism_works_under_prism.nim
run_nim r --hints:off tests/integration/t_lima_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_lima_linux_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_lima_revert_under_30s.nim

# Linux host: libvirt and Incus.
run_nim r --hints:off tests/e2e/t_vmharness_libvirt_ephemeral_run.nim
# Campaign WR0: the libvirt snapshot surface. Both self-skip loudly when
# their prerequisites are absent -- the conformance gate needs
# VMH_LIBVIRT_SCRATCH=1 on a /session URI (it DEFINES a throwaway domain),
# and the live gate needs an operator-provided running guest in
# VMH_LIBVIRT_WARM_DOMAIN. See each file's header.
run_nim r --hints:off tests/e2e/t_libvirt_snapshot_surface_conformance.nim
run_nim r --hints:off tests/e2e/t_libvirt_live_snapshot_restore.nim
run_nim r --hints:off tests/e2e/t_windows_golden_jit_boot.nim
run_nim r --hints:off tests/e2e/t_vmharness_incus_ephemeral_run.nim
# RA1 remoting against a real backend: remote client drives an ephemeral
# incus container through `vm-harness serve` (launch -> probe -> destroy).
run_nim r --hints:off tests/e2e/t_vmharness_serve_roundtrip_incus.nim
# §7.4 layered base images: snapshot -> publish -> export -> import -> launch.
run_nim r --hints:off tests/e2e/t_incus_layered_base_image.nim
