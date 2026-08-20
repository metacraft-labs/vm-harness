---
title: Guides
section: guides
order: 0
---
# Guides

Task-oriented guides for driving vm-harness once you know the concepts.

- [Driving a VM from test / harness code](/guides/driving-a-vm) — the
  library API: `runGate` for the one-call gate, or compose
  `provisionBaseline` → `revertToBaseline` → `execInGuest` →
  `stopAndCleanup` yourself, plus the ephemeral per-job path and serial
  boot assertions.
- [Backends: setup and caveats](/guides/backends) — per-backend host
  requirements, guest support, reset mechanism, and known gotchas for Tart,
  UTM, Hyper-V, WSL, libvirt/QEMU, Lima, and Incus.
- [Authoring a guest recipe](/guides/guest-recipes) — how baseline images
  are built, and a walk-through of the Linux GitHub-Actions runner-image recipe.
