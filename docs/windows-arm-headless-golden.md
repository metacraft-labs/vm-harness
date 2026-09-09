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
| Headless install boot — argument vector | ✓ | `buildQemuWindowsArmInstallArgs`. |
| Headless install boot — orchestration | ☐ | Phase 1 remainder: launch, then wait. |
| Install-completion detection | ☐ | Phase 1. |
| Rebuild safety guard (never build in place) | ✓ | `prepareGoldenBuildDir`. |
| Overlay backing-path symlink resolution | ✓ | Prerequisite for a safe flip; landed early with the guard. |
| Golden disk allocation | ✓ | `createGoldenDisk`. |
| Free-space precondition | ✓ | `checkGoldenBuildSpace`; floor refuses, comfort band warns. |
| Sysprep + generalize | ☐ | Phase 2. |
| Golden finalize + promote | ☐ | Phase 2. Versioned dir + pointer flip; never in place. |
| Previous-golden retention + reclaim | ☐ | Phase 2. Gated on the per-instance advisory lock. |
| Build manifest | ☐ | Phase 2. Identifies a golden's provenance. |
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

## Golden lifecycle: a read-only base under live overlays

The golden is not a template that gets copied. In the default disk mode
(`overlay`, see `qwaDiskMode`) `createEphemeralOverlay` creates a thin
`overlay.qcow2` whose **qcow2 backing file is the golden's
`windows.qcow2`**. The golden is never copied; it is shared read-only by
every concurrent instance, and only the overlay records guest writes. Clone
mode — a full per-instance copy — is a fallback behind
`VMH_QEMU_WINDOWS_ARM_DISK_MODE=clone`.

That makes one thing a hard constraint on this work:

> **A golden must never be rebuilt in place.** qcow2 does not validate that a
> backing file still holds the content an overlay was created against. Writing
> a new `windows.qcow2` at a path some overlay still references does not fail
> — the guest silently reads a different disk underneath its own writes.
> Every live instance, and every orphaned instance directory, is exposed.

So a rebuild is an *addition*, not a replacement:

1. Build into a **new versioned directory**, `golden/win-arm-runner-<build-id>/`,
   which is inert until anything points at it.
2. Flip `golden/win-arm-runner` — a symlink — to the new build. This selects
   what *subsequent* instances get; it must not disturb existing overlays.
3. Retain the previous golden until no overlay references it. The existing
   per-instance advisory lock (`qwaInstanceLockPath`, which `prune` already
   uses to distinguish a live instance from an orphan) is the signal for
   when that is true.

Two consequences worth stating plainly:

- **Overlays must record the resolved versioned path, not the symlink.**
  `validateWindowsArmVmDir` returns `absolutePath(dir)`, which does not
  resolve symlinks, so an overlay created through the pointer would record
  the pointer — and flipping it would corrupt exactly the instances this
  scheme exists to protect. Instance creation has to resolve the symlink
  before handing a backing path to `qemu-img create`.
- **This supplies the rollback the "no fallback" risk asked for.** Retaining
  the previous golden for the lifetime of its overlays means the
  last-known-good build is already on disk. Reverting a bad recipe change is
  a symlink flip, not a rebuild.

Periodic refreshes — Windows updates, a newer runner toolchain — are the
normal case for this path, not an exceptional one.

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

1. `qemu-img create -f qcow2 <golden-dir>/windows.qcow2 <size>`, where
   `<golden-dir>` is a fresh versioned directory — never an existing golden
   (see the lifecycle constraint above).
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
- **~8 GB ISO plus a 40–60 GB qcow2** on a host already at 88% disk, shared
  with a live fleet. Addressed by the free-space precondition above, but the
  50 GB install-peak figure it rests on is an estimate until a build
  measures it.
- **A bad recipe change is caught by retention, not by a published copy.**
  Nothing is published, but the previous golden stays on disk until its
  overlays drain, so rollback is a symlink flip. That only holds if
  retention is actually implemented; without it a regressed build is a lane
  outage until the recipe is fixed. The host e2e gate remains the thing that
  should catch it first.
- **Silent corruption if the versioning is got wrong.** Rebuilding over a
  golden that still backs an overlay does not error — it produces guests
  reading a disk that no longer matches their writes. This is the highest
  severity failure mode in this work and the reason the build refuses to
  write into an existing golden directory at all.
- **Long feedback loop.** A full cycle is 30–60 minutes, so Phase 1 should
  land the argument construction behind unit tests before any host run.

## Decisions

**The recipe is the artifact.** ✓ Decided 2026-09-09. A golden is rebuilt by
applying the recipe to a base ISO; the built golden is never published or
pulled. There is no cached copy to fall back on, so the build path is the
*only* path and has to be dependable enough to be run on demand.

Two consequences follow, and they are requirements rather than preferences:

- The build must be **re-runnable**, which the versioned-directory scheme
  gives for free: each run writes a fresh directory and a failed run simply
  leaves one that nothing ever points at. A partially built golden is never
  adopted, because adoption only happens by an explicit pointer flip after
  validation.
- Each golden carries a **manifest** — ISO SHA-256, recipe commit, answer
  file digests, build timestamp, vm-harness version. Not for reproducibility,
  which the recipe provides, but so that a golden of unknown provenance is
  identifiable as one. The artifact that was lost had no way to say what it
  was built from.

The ISO itself remains the one operator-supplied input, pinned by hash.

**The build gates on free space, with two thresholds.** ✓ Decided
2026-09-09. A single threshold would have to choose between blocking builds
that would have succeeded and permitting ones that cannot, so the check
separates the two questions:

| Threshold | Default | Behaviour |
|---|---|---|
| Floor — the build cannot finish | `min(diskGB, 50) + 10` = **60 GB** | Refuse |
| Comfortable — a saturated fleet also fits | floor + **116 GB** = **176 GB** | Warn, proceed |

Derivation, biased pessimistic throughout:

- **50 GB install peak.** A Windows 11 ARM64 install lands around 25 GB, plus
  the component store before `/ResetBase`, a pagefile sized to guest RAM, the
  staged toolchain, and sysprep's working set. This is an *estimate* — the
  golden it would have been measured against was lost — and should be
  replaced with a real figure after the first successful build.
- **116 GB fleet peak**, from live scale-set limits and measured instance
  footprints: 2 macOS at ~36 GB, 3 Linux at ~8 GB, 2 Windows overlays at
  ~10 GB.
- The floor scales down with a smaller requested image, since a qcow2 cannot
  outgrow its requested size, and stops scaling up past the install peak,
  since the image stays sparse.

`VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB` overrides the floor for an operator who
knows better than the estimate. An undeterminable free figure warns and
proceeds — refusing to build because a `statvfs` call failed would be worse
than the risk it guards.

For calibration: m3 measured 231 GB free with an idle fleet and 156 GB an
hour later with five instances running, which lands in the warn band. Free
space on that host moves by roughly the fleet peak over a day, which is the
reason the second threshold exists at all.

## Assumptions

- The Windows ARM64 ISO remains operator-supplied and is validated by hash,
  not re-downloaded by the harness.
- `swtpm`, `qemu-system-aarch64`, and `sshpass` stay available through the
  Nix-provided environment, as they are today on m3.
- The existing `autounattend.xml` is correct — it produced a working golden
  before. If Phase 1 disproves that, the answer file becomes part of this
  work rather than an input to it.
