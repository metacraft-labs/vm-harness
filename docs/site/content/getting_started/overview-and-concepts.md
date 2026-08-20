---
title: Overview and concepts
section: getting_started
order: 1
slug: overview-and-concepts
---
# Overview and concepts

## What vm-harness is

vm-harness is a focused library + CLI for cross-platform VM lifecycle
orchestration in test harnesses and dev workflows. It gives you one
abstraction over several backend hypervisors and container managers so the same
consumer code can drive any of them:

- provision a baseline guest image (once, slowly),
- reset fast to that baseline between test invocations,
- exec a command in the guest and capture its output,
- copy files in and out,
- install argv-tracing shims around guest-side tools,
- write a standardized output envelope of the run.

It is single-machine, single-process orchestration. It is not an
image-build pipeline (use Packer for that), it does not know what a "task" is
(consumers compose that on top), it is not a cloud-fleet manager, and it does
not target microVM-grade sub-second cold starts. See the
[design reference](https://github.com/metacraft-labs/vm-harness/blob/main/docs/design.md)
§1 for the full in-scope / out-of-scope statement.

## The `VmBackend` abstraction

Every backend implements the same set of lifecycle methods. Your code talks to
the `VmBackend` interface and never to a specific hypervisor's CLI. The core
methods (defined in `src/vm_harness/types.nim`, mirrored from the design
reference §3.2) are:

| Method | What it does | Budget |
| --- | --- | --- |
| `probeAvailability(b)` | Is this backend's tool installed and usable on this host? | instant |
| `provisionBaseline(b, spec)` | Build the baseline image if absent; no-op if present (idempotent). | minutes–hours, one-time |
| `revertToBaseline(b, name)` | Fast per-gate reset; returns a started `VmHandle` ready for exec. | seconds — see the reset contract |
| `startAndAwaitReady(b, vm)` | Optional separate ready-poll step (many backends fold this into revert). | seconds |
| `execInGuest(b, vm, env, cmd)` | Run a command in the guest, capture stdout/stderr/exit code. | per-command |
| `copyToGuest` / `copyFromGuest` | Move a file in / out of the guest. | per-file |
| `installArgvTraceShim` / `uninstallArgvTraceShim` | Wrap a guest binary so its argv is logged, then exec the real one. | per-shim |
| `stopAndCleanup(b, vm)` | Tear the VM down. Safe in a `finally` block — never raises. | seconds |

Snapshot / export primitives (`snapshot`, `snapshotRunning`, `restoreSnapshot`,
`listSnapshots`, `exportBaseline`, `importBaseline`) and boot-media / serial
primitives (`bootFromMedia`, `captureSerial`, `expectLine`, `serialSend`) are
also part of the interface; backends that lack a capability raise
`BackendUnavailableError` rather than silently no-op, so they stay conformant.

The supporting value types you pass around are:

- `BaselineSpec` — the request to build a baseline: `name`, `sourceImage`,
  `cpus`, `memoryMB`, `diskGB`, `guestOs`, plus recipe/first-boot fields and a
  free-form `backendOptions` escape hatch.
- `VmHandle` — a live, started VM: `name`, `baseline`, `ipAddress`,
  `sshPort`, `sshUser`, `sshAuth`, and a backend-specific `extra` table.
- `ExecResult` — `exitCode`, `stdout`, `stderr`, `elapsedMs`.
- `ArgvTraceShim` — `wrappedBinaryName` + `traceLogPath`.

### `--backend auto` selection

You can name a backend explicitly or let vm-harness pick one from the (host OS,
guest OS) pair. The dispatch table (`selectBackendId` in `types.nim`, design
reference §6) is:

| Host | Guest | Backend |
| --- | --- | --- |
| Windows | Windows | `hyperv` |
| Windows | Linux | `wsl` |
| Linux | Linux | `libvirt` |
| Linux | Windows | `libvirt` (QEMU + autounattend) |
| macOS (Apple Silicon) | macOS | `tart-macos` |
| macOS (Apple Silicon) | Linux | `tart-linux-arm` |
| macOS (Apple Silicon) | Windows | `utm-windows-arm` |

macOS guests on non-Apple hosts are rejected (Apple licensing). `Incus` is a
Linux/Linux backend selected explicitly with `--backend incus` (it is the
container analog of the libvirt per-job path, not part of the auto table).

## The per-gate reset performance contract

`revertToBaseline` is the hot path — it runs many times per session, so each
backend implements it as the fastest reset its technology allows. These are
targets; a regression of more than 50% over budget trips a CI flag.

| Backend | Target reset | Mechanism |
| --- | --- | --- |
| Hyper-V | ≤ 10 s | `Restore-VMCheckpoint` |
| libvirt/QEMU | ≤ 10 s | `virsh snapshot-revert --running` |
| UTM | ≤ 20 s | `utmctl clone` from a local bundle |
| Tart | ≤ 30 s | `tart clone` from a local OCI cache |
| WSL | ≤ 20 s | `wsl --import` of a cached rootfs |
| Lima | ≤ 30 s | `limactl delete + create + start` |
| Incus | sub-second | `incus launch` a fresh ephemeral container |

## The three-tier ownership model

The single most important concept for using vm-harness correctly: it ships
generic primitives only, and everything tool-specific belongs to the
consumer. This is why the toolkit stays general-purpose.

- Tier 1 — vm-harness (this toolkit). VM lifecycle (provision, revert,
  start, stop, snapshot), generic in-guest scripts ("exec a command", "install
  an argv tracer for any binary", "write output to the standard layout"), and
  the output envelope. Nothing here knows about your build tool, your test
  runner, or your product.

- Tier 2 — the build/test orchestration that consumes vm-harness (for
  example reprobuild's gate suite). Gate-binary build steps, dispatch of which
  VM to use, and the specific argv-trace shims a build system cares about
  (`useradd`, `dscl`, `launchctl`, …). vm-harness provides the generic "wrap any
  binary" primitive; Tier 2 decides which binaries.

- Tier 3 — a higher-level agent/product layer (for example Agent Harbor).
  Source sync, per-language test isolation, result-schema extraction (JUnit XML,
  etc.).

vm-harness never imports or references Tier 2 or Tier 3 code. When you are
deciding "should this knob live in vm-harness?", the test is: *is it generic
across all consumers, or specific to mine?* Generic → propose it as a Tier-1
parameter. Specific → compose it in your own code using Tier-1 primitives
(commonly via `--env`, `--copy-to`, `--install-shim`, or the `backendOptions`
table).

For the full architecture — lifecycle phase diagram, output-envelope schema,
per-backend transport details, and design references — read the
[design reference](https://github.com/metacraft-labs/vm-harness/blob/main/docs/design.md).
