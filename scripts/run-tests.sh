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
run_nim r --hints:off tests/unit/t_pool_algorithms.nim
run_nim r --hints:off tests/unit/t_libvirt_snapshot_args.nim
run_nim r --hints:off tests/unit/t_wsl_parsers.nim
run_nim r --hints:off tests/unit/t_utm_parsers.nim
run_nim r --hints:off tests/unit/t_tart_shared_dirs.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_backend.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_overlay.nim
run_nim r --hints:off tests/unit/t_qemu_boot_backend.nim
run_nim r --hints:off tests/unit/t_tpm_device_args.nim
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

# Live boot-smoke falsifiability gates. These really boot QEMU, but under
# TCG against a 512-byte synthetic guest that halts in under a second, so
# they need no hypervisor and no prebuilt artifact. They exit early with a
# printed reason on non-Linux hosts; on Linux they never skip.
run_nim r --hints:off tests/integration/t_boot_smoke_harness_fails_on_missing_line.nim
run_nim r --hints:off tests/integration/t_boot_smoke_harness_tears_down_on_failure.nim

# Live vTPM gate. Boots a real Linux guest (stock nixpkgs kernel + busybox
# initramfs, `nix/guest-linux-tpm.nix`) with and without a swtpm-backed TPM
# and asserts what the guest itself reports about /dev/tpm0. Needs
# $VMH_TPM_GUEST_DIR, which the dev shell exports; on Linux it never skips.
run_nim r --hints:off tests/integration/t_guest_sees_tpm_device.nim
