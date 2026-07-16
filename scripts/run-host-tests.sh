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

# macOS host: Tart, UTM, and Lima.
run_nim r --hints:off tests/integration/t_tart_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_linux_arm_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_macos_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_tart_cleanup_on_failure.nim
run_nim r --hints:off tests/integration/t_utm_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_utm_windows_arm_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_utm_windows_dism_works_under_prism.nim
run_nim r --hints:off tests/integration/t_lima_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_lima_linux_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_lima_revert_under_30s.nim

# Linux host: libvirt and Incus.
run_nim r --hints:off tests/e2e/t_vmharness_libvirt_ephemeral_run.nim
run_nim r --hints:off tests/e2e/t_windows_golden_jit_boot.nim
run_nim r --hints:off tests/e2e/t_vmharness_incus_ephemeral_run.nim
# §7.4 layered base images: snapshot -> publish -> export -> import -> launch.
run_nim r --hints:off tests/e2e/t_incus_layered_base_image.nim
