# vm-harness

Cross-platform VM lifecycle orchestration for test harnesses and dev
workflows. One abstraction over Tart, UTM, Hyper-V, WSL, libvirt/QEMU,
and Lima — so test code drives any of them through the same primitives.

This repository is the **canonical Nim implementation**; a nearly-identical
Rust port lives at `agent-harbor/main/crates/ah-vm/` (M17 of the
[Multi-OS VM Automation Campaign][campaign]).

[campaign]: https://github.com/metacraft-labs/reprobuild-specs/blob/main/Multi-OS-VM-Automation-Campaign.milestones.org

## Status

**M0 — scaffolding** is the current milestone. Today the repo ships:

- The `VmBackend` concept and supporting types (`docs/design.md` §3.2).
- A `NoopBackend` reference fixture for testing the harness scaffolding
  without any real hypervisor — the only allowed mock per the test
  methodology in `docs/design.md` §9.
- The Tier-1 in-guest scripts (`guest-scripts/posix.sh`,
  `guest-scripts/windows.ps1`) embedded into the library via
  `staticRead` (design choice #1 in `docs/design.md` §12).
- The standardized output envelope writer (`00-provision.log`,
  `02-<cmd>-run.txt`, `RESULT.txt`, `DONE`).
- The CLI dispatcher (`vm-harness {provision,run,probe,shell,backends}`)
  with `--backend auto` selection per (host OS, guest OS).
- The `try/finally` orchestrator that guarantees `stopAndCleanup` runs
  even on gate failure or SIGINT.

Real backend implementations land in M1 (Hyper-V + WSL refactor), M2
(Tart), M3 (UTM), M4 (libvirt/QEMU), M5 (Lima).

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
│           └── (hyperv, wsl, tart, utm, libvirt, lima — M1-M5)
├── guest-scripts/
│   ├── posix.sh
│   └── windows.ps1
├── guest-recipes/           # OS-bootstrap recipes (M3 onward)
├── tests/
│   ├── unit/
│   ├── integration/
│   └── e2e/
├── golden-outputs/          # M12 cross-language reference artifacts
└── docs/
    ├── design.md            # mirror of reprobuild-specs/VM-Harness-Design.md
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
