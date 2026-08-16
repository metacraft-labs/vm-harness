# Guest recipes

OS-bootstrap recipes that produce baseline images for each backend. M0
ships the empty skeleton; M3 onward fills it in:

- `windows-arm-base/` — M3 (UTM Windows ARM autounattend.xml + ISO
  assembly recipe, including an offline Win32-OpenSSH ARM64 fallback).
- `windows-x64-base/` — M4 (libvirt + QEMU/KVM Win11 x64 golden).
- `ubuntu-server-base/` — M4 (libvirt + cloud-init seed).
- `tart-macos-customized/` — M18 (AH-branded macOS golden via Packer).

`lib/` holds assets shared across recipes:

- `validate-uefi-iso.sh` — El Torito UEFI boot-record check.
- `provision-git.ps1` — installs Git for Windows (PortableGit) into a
  Windows golden and puts `C:\PortableGit\bin` on the **machine** PATH,
  which is what makes `bash.exe` reachable by a GitHub Actions runner
  *service* on clones of that golden. Owns the pinned version + SHA-256
  for both Windows recipes.
- `fetch-portable-git.sh` — host-side cache + checksum verify for that
  pinned archive (`--arch x64|arm64`); parses the pin out of
  `provision-git.ps1` rather than repeating it.

vm-harness's lifecycle primitives operate on already-existing baselines;
the recipes here document how to create them.
