# vm-harness

## What this repo is (read before hand-rolling anything VM-related)

`vm-harness` is **the** cross-platform VM lifecycle library + CLI for this
workspace. If your task involves **booting, provisioning, driving, or recording
a guest OS** — Linux, macOS, or Windows (incl. Windows-on-ARM) — use this repo.
**Do not hand-roll `qemu`/`swtpm`/`tart`/`limactl`/`autounattend.xml` yourself;**
it's already implemented, tested, and golden here.

What it gives you, behind one `VmBackend` abstraction (`--backend auto` picks per
host×guest):

- **Backends** (`src/vm_harness/backends/`): `tart` (macOS + Linux-ARM guests on
  Apple Silicon), `utm` + `qemu_windows_arm` (Windows-on-ARM), `lima` (Linux),
  `libvirt` (Linux/Windows x64 via QEMU/KVM), `hyperv`, `wsl`, `incus`, `noop`.
- **Lifecycle primitives**: boot / ephemeral clone + fast per-gate revert /
  exec-in-guest / copy files in-and-out / snapshot-restore / serial capture /
  standardized output envelope. Driven via `vm-harness {provision,run,probe,
  shell,backends,snapshot,baseline}` (see README "CLI reference").
- **Guest OS install recipes** (`guest-recipes/`): the one-time "how to build a
  golden guest" scripts. Notably **`guest-recipes/windows-arm-base/`** — the
  maintained Win11-on-ARM golden (official MS ARM64 ISO + `autounattend.xml` +
  OOBE-skip + OpenSSH-server + VirtIO NetKVM + SysPrep), built via **UTM** (raw
  `qemu` can't cleanly do the Win11-ARM installer→WinPE handoff, which is exactly
  why the UTM path exists). Also `windows-x64-base/` and the Linux runner images.
  In-guest bootstrap lives in `guest-scripts/`.

**Consuming from another repo?** Depend on the Nim library or shell out to the
`vm-harness` CLI for guest lifecycle, and keep only your task-specific logic on
top (per the three-tier ownership below). The Rust port is `agent-harbor`
`crates/ah-vm`.

## Which guide do you want?

- **To _use_ vm-harness** (drive VMs from the CLI or from your own harness code,
  set its parameters, author a guest recipe) → read the **user guide** at
  [`docs/user-guide/README.md`](docs/user-guide/README.md). Start with
  [Getting started](docs/user-guide/getting-started.md); the parameter contract
  consumers depend on is the [Parameters catalog](docs/user-guide/parameters.md).

- **To _enhance / develop_ vm-harness itself** → the developing guide follows
  below, and the canonical internal architecture reference is
  [`docs/design.md`](docs/design.md).

## Developing vm-harness

Backend implementations live in `src/vm_harness/backends/`, guest bootstrap
assets live in `guest-scripts/` and `guest-recipes/`, and tests are split across
`tests/unit/`, `tests/integration/`, and `tests/e2e/`.

Use the Nix development environment (`direnv allow` or `nix develop`) and the
repository entrypoints below:

- `just build` builds the CLI and snapshot benchmark.
- `just test` runs the deterministic test catalog in `scripts/run-tests.sh`.
- `just test-host` runs the opt-in gates that require a real host hypervisor.
- `just lint` checks the Nim entrypoint and Nix formatting.
- `just format` formats Nim and Nix sources.
- `just nix-build` builds the distributable Nix package.
- `repro build --tool-provisioning=path --daemon=off` builds the CLI through
  the pure reprobuild graph.
- `repro test --tool-provisioning=path --daemon=off` builds and executes the
  deterministic reprobuild test graph.

`just test` is the deterministic three-class Nix CI catalog. `repro test` is
the additive five-class catalog spanning Linux x64/ARM64, macOS ARM64, and
Windows x64/ARM64. Backend tests that require a real hypervisor live behind
`just test-host` and must keep an explicit platform and prerequisite guard. Do
not turn a missing prerequisite into claimed coverage.
The production host-level gates are maintained in `metacraft-labs/infra`:
`checks/t_vmharness_tart_ephemeral_run.sh`, `checks/t_m3_arm_ephemeral.sh`, and
`checks/t_windows_sysprep_golden.sh`.

## Three-tier ownership (what belongs here vs. in a consumer)

vm-harness ships **generic primitives only**; consumers compose them and never
push their logic down into it:

- **Tier 1 — this library**: VM lifecycle + generic in-guest scripts + guest
  install recipes.
- **Tier 2 — reprobuild**: gate orchestration, tool-specific argv shims.
- **Tier 3 — Agent Harbor / other consumers**: source sync, test isolation,
  result extraction, and *task-specific guest choreography* (e.g. a
  desktop-recording session that drives GUI apps + Playwright + a screen
  capture — that lives in the consumer, driving Tier-1 lifecycle here).

vm-harness never imports Tier 2 or Tier 3 code.

Follow the shared policies in `metacraft-labs/metacraft-dev-guidelines`,
especially `policies/repo-requirements.md`,
`policies/ci-workflow-standards.md`, and `policies/writing-nix-flakes.md`.
