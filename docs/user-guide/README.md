# vm-harness user guide

vm-harness is a **general-purpose, cross-platform VM lifecycle orchestration
toolkit** — a small Nim library plus a `vm-harness` CLI that let test code and
dev workflows drive many different hypervisors and container managers through
one set of primitives. You write against the abstraction once; the same code
runs a Hyper-V VM on Windows, a libvirt/QEMU VM on Linux, a Tart or UTM VM on an
Apple-Silicon Mac, an Incus system container, and so on.

This guide is **task-organized** and written for people who *use* vm-harness —
either from the command line or by driving the library from their own harness
code. It is deliberately separate from the internal architecture reference in
[`../design.md`](../design.md), which documents *how* the toolkit is built. When
you need the design rationale, the concept diagrams, or the per-milestone
history, read `design.md`; when you need to get a VM up and assert against it,
stay here.

## Contents

1. **[Overview and concepts](./overview-and-concepts.md)** — what vm-harness is,
   the `VmBackend` abstraction, and the three-tier ownership model that explains
   what belongs in vm-harness and what belongs in your own code.
2. **[Getting started](./getting-started.md)** — enter the dev shell, build the
   CLI, and bring a VM up / run your first in-guest assertion.
3. **Guides (task-oriented)**
   - **[Driving a VM from test / harness code](./driving-a-vm.md)** — the
     library API: `provisionBaseline` → `revertToBaseline` → `execInGuest` →
     `stopAndCleanup`, plus the one-call `runGate` orchestrator.
   - **[Backends: setup and caveats](./backends.md)** — per-backend host
     requirements, guest support, reset mechanism, and known gotchas for Tart,
     UTM, Hyper-V, WSL, libvirt/QEMU, Lima, and Incus.
   - **[Authoring a guest recipe](./guest-recipes.md)** — how baseline images
     are built, and a walk-through of the Linux GitHub-Actions runner-image
     recipe.
4. **Reference**
   - **[CLI reference](./cli-reference.md)** — every subcommand and flag.
   - **[Parameters catalog](./parameters.md)** — the documented, stable
     parameter contract: the `VMH_RUNNER_*` runner-image recipe seams and the
     `incus*` GARM provider options that consumers set. This is the surface
     downstream repos build policy against.

## The value is in the parameters

vm-harness is a toolkit, not an application. Its usefulness comes from the knobs
it exposes to consumers: the CLI flags, the backend constructor arguments, the
`VMH_*` recipe environment variables, and the provider options that a fleet
operator sets. Those are treated as a **public contract** — documented with
name, type, default, effect, and security/performance implications in the
[Parameters catalog](./parameters.md) and the [CLI reference](./cli-reference.md).
Consumers (for example the `metacraft-labs/infra` GitHub-runner fleet) depend on
these defaults staying stable, so changes to them are API changes.
