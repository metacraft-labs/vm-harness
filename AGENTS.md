# vm-harness contributor guide

`vm-harness` is the Nim library and CLI for cross-platform VM lifecycle
orchestration. Backend implementations live in `src/vm_harness/backends/`, guest
bootstrap assets live in `guest-scripts/` and `guest-recipes/`, and tests are
split across `tests/unit/`, `tests/integration/`, and `tests/e2e/`.

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

Follow the shared policies in `metacraft-labs/metacraft-dev-guidelines`,
especially `policies/repo-requirements.md`,
`policies/ci-workflow-standards.md`, and `policies/writing-nix-flakes.md`.
