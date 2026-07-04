# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Cross-platform VM lifecycle orchestration (Tart, UTM, Hyper-V, WSL, libvirt, Lima)"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["vm_harness/cli"]
binDir        = "build/bin"
namedBin["vm_harness/cli"] = "vm-harness"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run the vm-harness test suite":
  # M0 + M1 unit tests (host-independent, run on any platform).
  exec "nim r --hints:off tests/unit/t_output_envelope.nim"
  exec "nim r --hints:off tests/unit/t_auto_selection.nim"
  exec "nim r --hints:off tests/unit/t_guest_scripts.nim"
  exec "nim r --hints:off tests/unit/t_hyperv_parsers.nim"
  exec "nim r --hints:off tests/unit/t_wsl_parsers.nim"
  exec "nim r --hints:off tests/unit/t_utm_parsers.nim"
  # M0 integration / e2e (NoopBackend; runs on any platform).
  exec "nim r --hints:off tests/integration/t_noop_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_auto_backend_selection.nim"
  # M1 integration + verification (auto-skip on non-Windows).
  exec "nim r --hints:off tests/integration/t_hyperv_lifecycle.nim"
  exec "nim r --hints:off tests/integration/t_wsl_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_hyperv_m69_feature_capability_passes.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_wsl_m69_passwd_user_passes.nim"
  # M1.5 bootFromMedia + serial-stream primitives (auto-skip without WSL2 /
  # Hyper-V / required vendored artifacts; requires --threads:on).
  exec "nim r --hints:off --threads:on tests/e2e/t_vm_harness_wsl_systemd_boot.nim"
  exec "nim r --hints:off --threads:on tests/e2e/t_vm_harness_hyperv_systemd_boot.nim"
  # M2 integration + verification (auto-skip on non-macOS or when tart/sshpass missing).
  exec "nim r --hints:off tests/integration/t_tart_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_tart_linux_arm_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_tart_macos_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_tart_cleanup_on_failure.nim"
  # M3 integration + verification (auto-skip on non-macOS or when utmctl/sshpass
  # missing or when the windows-arm golden bundle isn't registered).
  exec "nim r --hints:off tests/integration/t_utm_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_utm_windows_arm_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_utm_windows_dism_works_under_prism.nim"
  # M5 integration + verification (auto-skip on non-macOS or when limactl is
  # missing). The smoke + revert-budget tests perform real Lima boots; expect
  # several minutes total wall-clock on a cold image cache.
  exec "nim r --hints:off tests/integration/t_lima_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_lima_linux_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_lima_revert_under_30s.nim"
  # M4 libvirt slice — no-live-virsh smoke test (compiles on any host;
  # asserts argv shape + stub-method clarity without booting any VM).
  # Live-libvirtd lifecycle tests land with M4 Phase B.
  exec "nim r --hints:off tests/integration/t_libvirt_backend.nim"
  # M4 libvirt slice — CLI flag plumbing for the canonical operator
  # command (--recipe / --name / --vcpu / --memory-gb / --network-bridge
  # / --first-boot-script). NoopBackend-style: no virsh, no libvirtd.
  exec "nim r --hints:off tests/integration/t_cli_libvirt_flags.nim"
  # Campaign M2 — libvirt per-job ephemeral CoW-clone reset gate. Boots
  # a FRESH per-job VM from a small Linux golden on REAL libvirt + KVM,
  # probes the serial boot marker, tears it down (no residue), and
  # asserts two-run independence. Self-skips cleanly unless
  # VMH_GOLDEN_TINY points at a `golden-linux-tiny` bundle AND /dev/kvm +
  # a reachable libvirtd (LIBVIRT_DEFAULT_URI=qemu:///session) are
  # present. Build the golden with `nix build .#golden-linux-tiny`.
  exec "nim r --hints:off tests/e2e/t_vmharness_libvirt_ephemeral_run.nim"
  # Campaign M3 — Windows golden + cloudbase-init config-drive JIT injection
  # gate. Boots a FRESH per-job CoW clone of the cloudbase-init Windows
  # golden on REAL libvirt + KVM (UEFI/OVMF) with an INJECTED config-drive
  # carrying the GARM Windows JIT bootstrap, drives it against a MOCK GARM
  # metadata+actions endpoint (per-instance JWT), and asserts the runner
  # fetches the JIT credentials under the JWT + launches Runner.Listener +
  # attempts a runner session, then tears the clone down with no residue.
  # Self-skips unless the golden (VMH_WIN_GOLDEN) + OVMF + /dev/kvm + a
  # system libvirtd + python3/sshpass/genisoimage are present. NEVER touches
  # windows-runner-001.
  exec "nim r --hints:off tests/e2e/t_windows_golden_jit_boot.nim"

task buildCli, "Build the vm-harness CLI binary":
  exec "nim c --hints:off -o:build/bin/vm-harness src/vm_harness/cli.nim"

task buildBench, "Build the backend-agnostic snapshot-revert benchmark":
  exec "nim c --hints:off --path:src -o:build/bin/vm-harness-bench-snapshot-revert " &
       "tools/bench/snapshot_revert_bench.nim"
