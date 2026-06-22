# vm-harness

Cross-platform VM lifecycle orchestration for test harnesses and dev
workflows. One abstraction over Tart, UTM, Hyper-V, WSL, libvirt/QEMU,
and Lima — so test code drives any of them through the same primitives.

This repository is the **canonical Nim implementation**; a nearly-identical
Rust port lives at `agent-harbor/main/crates/ah-vm/` (M17 of the
[Multi-OS VM Automation Campaign][campaign]).

[campaign]: https://github.com/metacraft-labs/reprobuild-specs/blob/main/Multi-OS-VM-Automation-Campaign.milestones.org

## Status

Shipped milestones:

- **M1 — Hyper-V + WSL backends** (`src/vm_harness/backends/hyperv.nim`,
  `wsl.nim`). PowerShell Direct over VMBus for Hyper-V; `wsl --import` /
  `wsl --exec` for WSL2.
- **M1.5 — bootFromMedia + serial-stream primitives**. Transient VM
  bring-up around a VHDX/ISO/rootfs tarball with serial-console
  capture for boot-time assertions.
- **M2 — Tart** (`src/vm_harness/backends/tart.nim`). macOS Apple
  Silicon host, macOS and Linux-ARM guests.
- **M3 — UTM** (`src/vm_harness/backends/utm.nim`, partial).
  Windows-on-ARM guest via UTM on macOS; clone-based per-gate revert
  through `utmctl clone`.
- **M4 Phase A slice — libvirt / QEMU/KVM** (`src/vm_harness/backends/libvirt.nim`).
  Linux host, x86_64 Windows or Linux guests via `virt-install` +
  `virsh`. Targets the windows-runner-001 prototype on
  `solunska-server`. See `docs/m4-libvirt.md` for Phase B/C scope.
- **M5 — Lima** (`src/vm_harness/backends/lima.nim`). macOS / Linux
  host, Linux guest via `limactl`.

Cross-cutting infrastructure that ships across all of the above:

- The `VmBackend` concept and supporting types (`docs/design.md` §3.2).
- A `NoopBackend` reference fixture for testing the harness scaffolding
  without any real hypervisor — the only allowed mock per the test
  methodology in `docs/design.md` §9.
- The Tier-1 in-guest scripts (`guest-scripts/posix.sh`,
  `guest-scripts/windows.ps1`) embedded into the library via
  `staticRead` (design choice #1 in `docs/design.md` §12).
- The standardized output envelope writer (`00-provision.log`,
  `02-<cmd>-run.txt`, `RESULT.txt`, `DONE`).
- The CLI dispatcher
  (`vm-harness {provision,run,probe,shell,backends,snapshot,baseline}`)
  with `--backend auto` selection per (host OS, guest OS); every
  backend listed above has its `--backend <id>` selector wired
  through the registry.
- The `try/finally` orchestrator that guarantees `stopAndCleanup` runs
  even on gate failure or SIGINT.
- M30 snapshot/restore parity (Hyper-V, Lima, Tart, UTM) and M31 hot
  snapshots + portable baseline export/import (Hyper-V; clone-based
  parity on Tart/UTM).

Outstanding:

- **M4 Phase B** — libvirt snapshot/restore, argv-trace shim,
  serial-stream primitives. Tracked in `docs/m4-libvirt.md`.
- **M4 Phase C** — libvirt GPU + SR-IOV + USB passthrough. Gated on
  applicable runner hardware.

## Layout

```
vm-harness/
├── flake.nix                # dev shell + package output
├── vm_harness.nimble        # Nimble package + test task
├── src/
│   ├── vm_harness.nim       # top-level re-export module
│   └── vm_harness/
│       ├── types.nim
│       ├── output.nim
│       ├── auto.nim
│       ├── cli.nim
│       ├── orchestrator.nim
│       ├── guest_scripts.nim
│       └── backends/
│           ├── noop.nim
│           ├── process_helpers.nim   # shared PS / wsl.exe helpers (M1)
│           ├── hyperv.nim            # M1
│           ├── wsl.nim               # M1
│           ├── tart.nim              # M2
│           ├── utm.nim               # M3
│           ├── libvirt.nim           # M4 Phase A (slice)
│           └── lima.nim              # M5
├── guest-scripts/
│   ├── posix.sh
│   └── windows.ps1
├── guest-recipes/           # OS-bootstrap recipes
│   ├── windows-arm-base/    # UTM Win11-on-ARM golden (M3)
│   └── windows-x64-base/    # libvirt Win11-on-x64 baseline (M4 Phase A)
├── tests/
│   ├── unit/
│   ├── integration/
│   └── e2e/
├── golden-outputs/          # M12 cross-language reference artifacts
└── docs/
    ├── design.md            # mirror of reprobuild-specs/VM-Harness-Design.md
    ├── m4-libvirt.md        # M4 Phase A slice scope + Phase B/C plan
    └── per-backend-notes/
```

## Building and testing

Inside the Nix dev shell:

```sh
nix develop
nimble buildCli          # produces build/bin/vm-harness
nimble test              # M0 verification suite
```

Without Nix (any host with Nim 2.0+ on PATH):

```sh
nim c -o:build/bin/vm-harness src/vm_harness/cli.nim
nim r tests/e2e/t_vm_harness_smoke.nim
```

## CLI reference

```
vm-harness provision --backend <id|auto> --guest <linux|windows|macos> \
                     --baseline <name> [--source-image <ref>] \
                     [--cpus N] [--memory-mb N] [--disk-gb N]

vm-harness run       --backend <id|auto> --guest <linux|windows|macos> \
                     --baseline <name> --output-dir <path> \
                     [--env KEY=VAL ...] [--copy-to host:guest ...] \
                     [--copy-from guest:host ...] \
                     [--install-shim binary:logpath ...] \
                     -- <command args>

vm-harness probe     # JSON report of available backends.
vm-harness backends  # Tabular listing.
vm-harness shell     --backend <id|auto> --baseline <name>   # placeholder in M0
```

`--backend auto` picks per the dispatch table (design doc §6):

| Host                  | Guest    | Backend              |
| --------------------- | -------- | -------------------- |
| Windows               | Windows  | hyperv               |
| Windows               | Linux    | wsl                  |
| Linux                 | Linux    | libvirt              |
| Linux                 | Windows  | libvirt              |
| macOS (Apple Silicon) | macOS    | tart-macos           |
| macOS (Apple Silicon) | Linux    | tart-linux-arm       |
| macOS (Apple Silicon) | Windows  | utm-windows-arm      |

## Per-gate reset performance contract

Each backend implements `revertToBaseline` as the fastest reset its tech
allows. Targets:

| Backend      | Target reset | Mechanism                          |
| ------------ | ------------ | ---------------------------------- |
| Hyper-V      | ≤ 10s        | `Restore-VMCheckpoint`             |
| libvirt/QEMU | ≤ 10s        | `virsh snapshot-revert --running`  |
| UTM          | ≤ 20s        | `utmctl clone` from local bundle   |
| Tart         | ≤ 30s        | `tart clone` from local OCI cache  |
| WSL          | ≤ 20s        | `wsl --import` of cached rootfs    |
| Lima         | ≤ 30s        | `limactl delete + create + start`  |

Regressions of more than 50% over budget trigger
`e2e_vm_harness_per_gate_revert_meets_m0_budget` (M12).

## Three-tier ownership

vm-harness ships **generic primitives only**. Consumers compose them:

- **Tier 1 — this library**: VM lifecycle + generic in-guest scripts.
- **Tier 2 — reprobuild**: gate orchestration, argv-shim installations
  for tool-specific commands (`useradd`, `dscl`, `launchctl`, ...).
- **Tier 3 — Agent Harbor**: mutagen source sync, cargo test isolation,
  JUnit XML extraction.

vm-harness never imports Tier 2 or Tier 3 code.

## License

MIT — see `LICENSE`.
