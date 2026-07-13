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
