# Per-backend implementation notes

One file per backend lands here as M1-M5 are implemented:

- `hyperv.md` — M1 (refactor existing reprobuild Hyper-V harness).
- `wsl.md` — M1 (refactor existing reprobuild WSL harness).
- `tart.md` — M2 (macOS + Linux ARM guests on Mac hosts).
- `utm.md` — M3 (Windows-on-ARM guests on Mac hosts).
- `libvirt.md` — M4 (Linux + Windows guests on Linux hosts).
- `lima.md` — M5 (Linux guests on Mac hosts, alternative to Tart).

Each note documents the host-side CLI invocations, the in-guest
transport (SSH, PowerShell Direct, direct `wsl --` exec), file-transfer
mechanism, snapshot/clone strategy, and any known gotchas.
