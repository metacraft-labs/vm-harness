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
run_nim r --hints:off tests/unit/t_cli_incus.nim
run_nim r --hints:off tests/unit/t_ssh_serialization.nim
run_nim r --hints:off tests/unit/t_hyperv_parsers.nim
run_nim r --hints:off tests/unit/t_hyperv_boot_media.nim
run_nim r --hints:off tests/unit/t_hyperv_ephemeral_clone.nim
run_nim r --hints:off tests/unit/t_pool_algorithms.nim
run_nim r --hints:off tests/unit/t_libvirt_snapshot_args.nim
run_nim r --hints:off tests/unit/t_wsl_parsers.nim
run_nim r --hints:off tests/unit/t_utm_parsers.nim
run_nim r --hints:off tests/unit/t_tart_shared_dirs.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_backend.nim
run_nim r --hints:off tests/unit/t_qemu_windows_arm_overlay.nim
# Runner-Fleet-M3-ARM-Wave MA3 gate: t_qemu_windows_arm_golden_build, UNIT
# TIER — the install argv, the rebuild-safety guards, the free-space
# precondition, and the install -> sysprep -> power-off -> finalize ->
# manifest orchestration driven end to end against a fake QEMU that binds the
# real forwarded port and serves a real monitor socket. The HOST tier (a real
# Windows install, and two clones with distinct machine SIDs) is
# tests/e2e/t_qemu_windows_arm_golden_build_host.nim, run by
# scripts/run-host-tests.sh; it skips with an explicit message naming every
# precondition it lacks.
run_nim r --hints:off tests/unit/t_qemu_windows_arm_golden_build.nim
run_nim r --hints:off tests/unit/t_qemu_boot_backend.nim
run_nim r --hints:off tests/unit/t_tpm_device_args.nim
run_nim r --hints:off tests/unit/t_windows_golden_recipe_hardening.nim
run_nim r --hints:off tests/unit/t_tart_backend.nim
# Runner-Fleet-M3-ARM-Wave MA0 gate: t_vmharness_image_is_honoured, assertion
# (c) — a registry-constructed tart backend with no image configured RAISES
# rather than substituting a default. Assertions (a) and (b) are provider-side
# and are run by the nix check of the same name in metacraft-labs/nixos-modules.
run_nim r --hints:off tests/unit/t_vmharness_image_is_honoured.nim
run_nim r --hints:off tests/unit/t_lima_backend.nim
run_nim r --hints:off tests/unit/t_prune.nim
# Runner-Fleet-M3-ARM-Wave MA7 (hygiene half) gate:
# t_m3_tart_orphan_dirs_reclaimed — `tart list` omits a VM with no disk.img,
# so `tart delete` cannot address one and every CLI-driven reaper is blind to
# it; m3 had leaked 600 such directories / 14.6 GiB. This gates the
# filesystem sweep that reclaims them AND, mostly, that each of its four
# guards independently spares a VM that is alive.
run_nim r --hints:off tests/unit/t_m3_tart_orphan_dirs_reclaimed.nim
run_nim r --hints:off tests/unit/t_layer_gc.nim
run_nim r --hints:off tests/unit/t_design_reprobuild_adapter_section.nim
run_nim r --hints:off tests/unit/t_uefi_iso_validator.nim
run_nim r --hints:off tests/unit/t_serve_protocol.nim
# RA6 enrollment/identity + capability manifest: pure crypto vectors, the
# capability deciders against fixtures, and the sign/verify state machine.
run_nim r --hints:off tests/unit/t_serve_enrollment.nim

# Backend-independent lifecycle and CLI coverage.
run_nim r --hints:off tests/integration/t_noop_lifecycle.nim
run_nim r --hints:off tests/e2e/t_vm_harness_smoke.nim
run_nim r --hints:off tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim
run_nim r --hints:off tests/e2e/t_vm_harness_auto_backend_selection.nim
# RA1 remoting: a remote client drives provision->run->destroy against a
# `vm-harness serve` daemon over the authenticated endpoint (noop backend).
run_nim r --hints:off tests/e2e/t_vmharness_serve_roundtrip.nim
# RA6 enrollment gate: a remote client reads the daemon's SIGNED identity +
# capability manifest over /v1/manifest and verifies it against a trust store;
# unenrolled/expired/revoked/tampered identities are rejected. Hermetic (noop).
run_nim r --hints:off tests/e2e/t_vmharness_serve_enrollment.nim

# Backend contracts that do not require a live hypervisor.
run_nim r --hints:off tests/integration/t_libvirt_backend.nim
run_nim r --hints:off tests/integration/t_cli_libvirt_flags.nim
run_nim r --hints:off tests/integration/t_incus_ephemeral_capabilities.nim
run_nim r --hints:off tests/integration/t_durable_media.nim

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
