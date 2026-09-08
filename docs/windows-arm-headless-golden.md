# Headless Windows ARM64 golden build

## Overview

`qemu-windows-arm` can *consume* a Windows ARM64 golden — a directory
containing `windows.qcow2` — but nothing in this repository can *produce*
one. `provisionBaseline` only validates that the directory exists and holds
that file ([`qemu_windows_arm.nim:497`](../src/vm_harness/backends/qemu_windows_arm.nim)),
and the recipe under
[`guest-recipes/windows-arm-base/`](../guest-recipes/windows-arm-base/)
builds a **UTM bundle** through a GUI step, not a qcow2. The golden that the
`eph-win-arm64` CI lane ran on was therefore promoted by hand, exists in no
build graph, and had no backup.

That artifact was lost between 2026-07-20 and 2026-08-24. The lane has been
down since, and cannot be restored by any automated path. This document
specifies the missing one: drive the Windows ARM64 unattended install through
QEMU with no GUI and no UTM, so the golden is reproducible from the ISO plus
the checked-in answer files.

## Implementation Status

| Component | Status | Notes |
|---|---|---|
| `provisionBaseline` (validate existing golden) | ✓ | Already shipped; unchanged by this work. |
| Headless install boot | ☐ | Phase 1. |
| Install-completion detection | ☐ | Phase 1. |
| Sysprep + generalize | ☐ | Phase 2. |
| Golden finalize + promote | ☐ | Phase 2. |
| `vm-harness provision --backend qemu-windows-arm` entrypoint | ☐ | Phase 3. |
| Nix-side golden provisioning on m3 | ☐ | Phase 3; `metacraft-labs/infra`. |
| Retire the UTM recipe path | ☐ | Phase 4, once Phase 3 has produced a golden twice. |

## Why this is tractable now

The per-job run path is *already* fully headless. `qemuBaseArgs`
([`qemu_windows_arm.nim:336`](../src/vm_harness/backends/qemu_windows_arm.nim))
launches with `-accel hvf`, `-display none`, UEFI pflash firmware, an
`swtpm` TPM 2.0 device, `-serial file:`, a QMP/monitor socket, and user-mode
networking with `hostfwd` for SSH. Every primitive the install needs is in
place and proven — the golden build reuses that argument vector with three
changes:

1. a freshly created empty `windows.qcow2` instead of a CoW copy;
2. the Windows ISO and the autounattend ISO attached as CD-ROMs;
3. `-no-reboot` dropped, because a Windows install reboots several times.

The recipe inputs are likewise already checked in and independent of UTM:
`autounattend.xml`, `repro-sysprep.xml`, `provision-openssh.ps1`, and the
`build-autounattend-iso.sh` that packages them together with the staged
OpenSSH and VirtIO NetKVM payloads. Only the *driver* is missing.

There is also a working precedent in this repo. The Linux libvirt backend
performs the equivalent install headlessly through `virt-install` (see
[`m4-libvirt.md`](m4-libvirt.md), Phase A). This work is that same shape for
the macOS/ARM host, minus libvirt, which does not exist on Darwin.

## Goals

- A golden is reproducible from three inputs: the Windows ARM64 ISO, the
  checked-in answer files, and a pinned VirtIO/OpenSSH payload set.
- The build runs unattended on a macOS ARM host with no GUI, no `utmctl`,
  and no console session — so CI and a remote operator over SSH can both
  run it.
- Failure is loud and diagnosable: every phase has a bounded timeout and
  leaves the serial log and QEMU log behind.
- The produced golden is byte-identical in *shape* to what
  `validateWindowsArmVmDir` already expects, so the consuming path needs no
  change.

## Non-goals

- Building the Windows ISO itself. It stays an operator-supplied input;
  Microsoft's download is manual and unversioned in any usable way.
- Reproducible-to-the-bit output. A Windows install is not deterministic.
  The goal is *reproducible procedure*, not a fixed hash.
- Replacing the x64 libvirt path on `high-mem-server`, which already works.
- UTM parity. The UTM recipe is retired by Phase 4, not preserved.

## Design

A new `buildBaseline` capability on the `qemu-windows-arm` backend, driven by
a new `vm-harness provision --backend qemu-windows-arm` subcommand.

### Phase 1 — headless install

```
vm-harness provision --backend qemu-windows-arm \
  --baseline win-arm-runner \
  --output-dir <golden-dir> \
  --windows-iso <path> \
  --autounattend-iso <path>
```

1. `qemu-img create -f qcow2 <golden-dir>/windows.qcow2 <size>`.
2. Stage UEFI vars from the firmware template, as `revertToBaseline`
   already does.
3. Start `swtpm`, then QEMU with `qemuBaseArgs` plus both ISOs as
   `-drive if=none,media=cdrom` + `-device usb-storage`/`scsi-cd`, with
   `bootindex` ordering the install ISO ahead of the NVMe disk, and
   without `-no-reboot`.
4. Poll for install completion by SSHing to the forwarded port and testing
   for `C:\Windows\Temp\repro-install-done` — the sentinel
   `autounattend.xml` already writes from `FirstLogonCommands` after
   OpenSSH and NetKVM are confirmed up. This reuses `waitForSshReady`.
5. Bounded by a single overall deadline (default 90 min; the README budgets
   15–30 min for install plus 1–3 for OpenSSH, so this is generous).

The install boot is where the answer file does all the real work, so Phase 1
carries almost no new Windows-side logic.

### Phase 2 — sysprep and finalize

6. Copy `repro-sysprep.xml` to `C:\` and invoke
   `sysprep /generalize /oobe /shutdown /unattend:C:\repro-sysprep.xml`
   over SSH.
7. Wait for the guest to power off, observed through the QMP socket rather
   than SSH, since SSH dies with the guest.
8. Kill `swtpm`, drop the CD-ROM drives, and leave `windows.qcow2` plus the
   firmware vars in `<golden-dir>`.
9. Validate the result through the existing `validateWindowsArmVmDir` so the
   build cannot produce something the consuming path rejects.

Sysprep `/generalize` is load-bearing and must not be skipped: without it
every ephemeral clone shares one machine SID. That is the same property the
x64 lane gates on in `metacraft-labs/infra`'s
`checks/t_windows_sysprep_golden.sh`, and the ARM lane should gain the
equivalent check.

### Phase 3 — make it callable

- Expose the subcommand in `cli.nim` alongside the existing `provision`.
- In `metacraft-labs/infra`, add a golden-provisioning path so
  `/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner` is
  populated by a documented command rather than by hand. The activation
  script currently `install -d`s that directory and nothing fills it
  ([`services/ephemeral-runner-host/darwin.nix:699`](https://github.com/metacraft-labs/infra)).

## Verification

| Gate | Layer | Runs where |
|---|---|---|
| Argument-vector unit test: install boot attaches both ISOs, orders bootindex, and omits `-no-reboot` | unit | anywhere |
| `qemu-img`/`swtpm` invocation shape | unit | anywhere |
| Golden shape accepted by `validateWindowsArmVmDir` | unit | anywhere |
| Full install → sysprep → golden | host e2e, opt-in | macOS ARM host with the ISO |
| Two clones of the golden have distinct machine SIDs | host e2e, opt-in | macOS ARM host with a golden |

The unit layer must not claim coverage of the e2e layer. Following this
repo's existing convention, a missing ISO or a non-macOS host **skips with an
explicit message** rather than passing quietly.

## Risks

- **Windows setup is opaque when it fails.** A wrong answer file leaves a
  guest sitting at an OOBE prompt with no SSH and no console. Mitigation:
  the serial log and `ramfb` framebuffer are both captured, and the overall
  deadline bounds the failure.
- **The install may need more reboots than HVF+UEFI tolerates.** Untested on
  this exact firmware/machine combination; Phase 1 is where that is found
  out.
- **~8 GB ISO plus a 40–60 GB qcow2** on a host already at 86% disk. Golden
  builds must run against a checked free-space precondition.
- **Long feedback loop.** A full cycle is 30–60 minutes, so Phase 1 should
  land the argument construction behind unit tests before any host run.

## Open Questions

> **Decision needed:** Where does the golden's provenance live? Options:
> - A. A plain text manifest in the golden dir recording ISO SHA-256,
>   recipe commit, and build timestamp. Cheap, no infrastructure.
> - B. Publish the golden as an OCI artifact so hosts pull it like the tart
>   images, making the m3 rebuild a download rather than a 60-minute build.
> - C. Both — A now, B when a second ARM host needs one.
>
> B is what makes this durable against a second loss; A is what makes the
> loss *detectable*. Recommend C.

> **Decision needed:** Should the golden build gate on free disk space, and
> at what threshold? m3 currently carries 121 GB of stale ephemeral VM
> directories, which is the kind of thing that makes a build fail at 90%
> completion.

## Assumptions

- The Windows ARM64 ISO remains operator-supplied and is validated by hash,
  not re-downloaded by the harness.
- `swtpm`, `qemu-system-aarch64`, and `sshpass` stay available through the
  Nix-provided environment, as they are today on m3.
- The existing `autounattend.xml` is correct — it produced a working golden
  before. If Phase 1 disproves that, the answer file becomes part of this
  work rather than an input to it.
