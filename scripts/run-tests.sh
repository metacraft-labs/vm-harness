#!/usr/bin/env bash
set -euo pipefail

run_nim() {
  echo
  echo "==> nim $*"
  nim "$@"
}

# Host-independent unit tests.
run_nim r --hints:off tests/unit/t_output_envelope.nim
run_nim r --hints:off tests/unit/t_auto_selection.nim
run_nim r --hints:off tests/unit/t_guest_scripts.nim
run_nim r --hints:off tests/unit/t_cli_probe.nim
run_nim r --hints:off tests/unit/t_cli_boot.nim
run_nim r --hints:off tests/unit/t_hyperv_parsers.nim
run_nim r --hints:off tests/unit/t_hyperv_boot_media.nim
run_nim r --hints:off tests/unit/t_wsl_parsers.nim
run_nim r --hints:off tests/unit/t_utm_parsers.nim
run_nim r --hints:off tests/unit/t_tart_shared_dirs.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_backend.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_overlay.nim
run_nim r --hints:off tests/unit/t_windows_golden_recipe_hardening.nim
run_nim r --hints:off tests/unit/t_tart_backend.nim
run_nim r --hints:off tests/unit/t_lima_backend.nim
run_nim r --hints:off tests/unit/t_prune.nim
run_nim r --hints:off tests/unit/t_uefi_iso_validator.nim

# Backend-independent lifecycle and CLI coverage.
run_nim r --hints:off tests/integration/t_noop_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim
run_nim r --hints:off tests/e2e/t_vm_harness_auto_backend_selection.nim

# Backend contracts that do not require a live hypervisor.
run_nim r --hints:off tests/integration/t_libvirt_backend.nim
run_nim r --hints:off tests/integration/t_cli_libvirt_flags.nim
