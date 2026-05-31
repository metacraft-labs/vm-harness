# Guest recipes

OS-bootstrap recipes that produce baseline images for each backend. M0
ships the empty skeleton; M3 onward fills it in:

- `windows-arm-base/` — M3 (UTM Windows ARM autounattend.xml + ISO
  assembly recipe).
- `ubuntu-server-base/` — M4 (libvirt + cloud-init seed).
- `tart-macos-customized/` — M18 (AH-branded macOS golden via Packer).

vm-harness's lifecycle primitives operate on already-existing baselines;
the recipes here document how to create them.
