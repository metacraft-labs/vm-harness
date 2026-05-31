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

task test, "Run the M0 test suite":
  exec "nim r --hints:off tests/unit/t_output_envelope.nim"
  exec "nim r --hints:off tests/unit/t_auto_selection.nim"
  exec "nim r --hints:off tests/unit/t_guest_scripts.nim"
  exec "nim r --hints:off tests/integration/t_noop_lifecycle.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_smoke.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_finally_cleanup_on_panic.nim"
  exec "nim r --hints:off tests/e2e/t_vm_harness_auto_backend_selection.nim"

task buildCli, "Build the vm-harness CLI binary":
  exec "nim c --hints:off -o:build/bin/vm-harness src/vm_harness/cli.nim"
