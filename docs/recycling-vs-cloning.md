# Recycling vs cloning, per backend

An ephemeral-runner pool needs two different operations, and they are
routinely conflated:

- **Clone** — add a member. Changes pool CAPACITY. Rare, and nobody is
  waiting on it.
- **Recycle** — return a member to its baseline between jobs. Constant, and
  it is what determines both per-job latency and the isolation guarantee.

Which of the two is cheap is **not a property of the design, it is a
property of the backend's storage**. The answer differs per backend, so the
right pool architecture differs per backend too. This page records what was
measured or read, and what follows from it.

## Hyper-V — measured 2026-08-21 on win-ci-bare-001

Numbers and method in
[`per-backend-notes/hyperv-snapshot-benchmarks.md`](per-backend-notes/hyperv-snapshot-benchmarks.md).

| operation | cost |
| --------- | ---- |
| clone (`Export-VM` + `Import-VM`) | ~50 s |
| recycle (`Restore-VMCheckpoint` + resume) | 7-14 s |
| cold boot, for comparison | 36 s |

Cloning is a real file copy, so clone-per-job (35.9 s) is no better than
just cold-booting. Recycling restores a checkpoint that carries RAM, so a
member resumes in ~5 s instead of booting in 36 s.

**Verdict: warm pool.** N members, each hot-checkpointed with its OWN
identity, recycled after each job.

## libvirt / QEMU — the premise INVERTS

The Hyper-V conclusion does not transfer, and assuming it would be a
mistake.

**Cloning is already cheap here.** `libvirt.nim:652` creates the per-job
disk with

```
qemu-img create -f qcow2 -b <golden> -F qcow2 <overlay>
```

a copy-on-write overlay over the golden — O(1), no bytes copied. There is
no `Import-VM` equivalent to dominate the cost. So the thing that made
clone-per-job unattractive on Hyper-V simply does not exist here, and the
current libvirt ephemeral path (a fresh CoW overlay per job) is already the
right shape for capacity.

**But recycling does not exist at all.** `snapshot`, `snapshotRunning`,
`restoreSnapshot`, `listSnapshots` and `removeSnapshot` are all
unimplemented stubs that raise, tagged "M4 Phase B"
(`libvirt.nim:1561-1602`). The doc header lists them under *out of scope*.

So a libvirt guest today is always COLD: cheap to create, but it pays a
full guest boot every job. For the Linux guests that hardly matters. For
the **Windows** guest on `eph-win-x64` it matters a lot — it is the same
Windows 11 image, so it pays the same ~36 s boot that the Hyper-V warm path
was measured to reduce to ~5 s.

**Verdict: the win is available and unclaimed.** Implementing M4 Phase B —
specifically `virsh snapshot-create-as --live` (memory + CPU + device
state) or `virsh save`/`restore` — would give the Windows libvirt runners
the same 36 s -> 5 s improvement, on top of cloning that is already free.
That is the highest-value unimplemented thing found in this audit.

## incus — the answer depends entirely on the storage driver

Unlike libvirt, incus **has** the primitives: `snapshot`,
`snapshotRunning`, `restoreSnapshot`, `listSnapshots` and `removeSnapshot`
are all implemented (`incus.nim:598-665`), wrapping
`incus snapshot create` / `incus snapshot restore`.

Two things qualify that, and the second is the important one.

**1. Recycling a container is not the same optimisation.** `snapshotRunning`
deliberately takes a *filesystem* snapshot rather than a CRIU stateful one,
noting that this "is what the per-gate reset model wants" — correct, because
a container has no boot to skip. A container starts in about a second, so
there is no 36 s -> 5 s prize here. **For containers, recycling buys
isolation, not speed.**

**2. The default storage pool is `dir`.** `per-backend-notes/incus.md:36`
declares `driver = "dir"`, i.e. `incus admin init --minimal`'s default. On
the `dir` driver an instance is a plain directory tree, so
`incus snapshot create` and `incus snapshot restore` are **full recursive
copies**, not metadata operations. Cost scales with the size of the
instance's filesystem.

That is the crux, and it points straight at work already in flight:

> **On `dir`, restore-to-baseline may be a pessimisation** — copying a
> whole rootfs back can cost more than deleting the instance and launching
> a fresh one from the image, which incus already does cheaply.
>
> **On ZFS (or btrfs), the same two commands become O(1)** — a snapshot is
> a ZFS snapshot and a restore is a `zfs rollback`, both metadata-only and
> independent of instance size. `incus copy` also becomes a `zfs clone`,
> making capacity changes near-free as well.

So enabling a ZFS storage driver for incus is not a tuning detail; it is
the thing that decides whether the recycle model is worth using there at
all. vm-harness currently has **no ZFS awareness for incus anywhere** — the
existing ZFS mentions are all libvirt image-path advice ("put the qcow2 on
a ZFS pool"), which is a different thing entirely.

**Verdict: blocked on storage.** Revisit once the ZFS driver lands, and
measure `incus snapshot restore` on both drivers before choosing — the
comparison to beat is "delete and relaunch", not "cold boot".

## Summary

| backend | clone (capacity) | recycle (per job) | what to do |
| ------- | ---------------- | ----------------- | ---------- |
| Hyper-V | ~50 s, real copy | **7-14 s, carries RAM** | warm pool + recycle (measured) |
| libvirt | **O(1) CoW overlay** | not implemented (M4 Phase B) | implement stateful snapshots; biggest unclaimed win, especially for Windows |
| incus | `incus copy` | implemented, cost = f(driver) | **`dir` makes it a full copy; ZFS makes it O(1)** — re-measure when ZFS lands |

The general rule, stated once: **recycle when restoring is cheaper than
creating, clone when it is not.** Hyper-V and incus-on-ZFS sit on one side
of that line, incus-on-`dir` on the other, and libvirt cannot answer yet
because it has no restore to price.
