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

**Cloning is already cheap here.** `provisionEphemeralClone`
(`libvirt.nim:736`) creates the per-job disk with

```
qemu-img create -f qcow2 -b <golden> -F qcow2 <overlay>
```

a copy-on-write overlay over the golden — O(1), no bytes copied. There is
no `Import-VM` equivalent to dominate the cost. So the thing that made
clone-per-job unattractive on Hyper-V simply does not exist here, and the
current libvirt ephemeral path (a fresh CoW overlay per job) is already the
right shape for capacity.

**Recycling now exists, and is unmeasured.** As of campaign WR0,
`snapshot`, `snapshotRunning`, `restoreSnapshot`, `listSnapshots` and
`removeSnapshot` are implemented as EXTERNAL `virsh` snapshots
(`libvirt.nim:1852-2035`); `exportBaseline` / `importBaseline` remain stubs
and belong to WR3. `snapshotRunning` wraps
`virsh snapshot-create-as --live` with an external memspec, which is what
captures RAM — and `--live` is *only* legal for external snapshots, so an
internal one would have quietly given up the resume.

Two storage properties were measured on `high-mem-server` against real
libvirt 11.7 and both favour recycling:

- **A restore does not rewrite the saved state.** Two consecutive restores
  left the frozen disk byte-identical, mtime unchanged. So "prepare the warm
  state once, restore it many times" is the cheap direction.
- **One restore writes one empty overlay** (kilobytes), then reads the
  memory image. Unlike Hyper-V, where recycle cost scales with how much the
  job wrote (6.67 s clean vs 13.59 s after a write-heavy job), the write
  side here does not scale with the guest.

What is still missing is the **number**: nobody has yet timed
restore-to-ready against boot-to-ready on a libvirt guest, because that means
booting the 16 GiB Windows golden on a host that is already heavily
CPU-contended during CI hours. Hyper-V's 36 s → ~5 s is the analogy that
motivated the work, not a measurement of this backend.

**Verdict: the capability is claimed; the measurement is not.** Run the
maintenance-window procedure in
[`per-backend-notes/libvirt-snapshot-benchmarks.md`](per-backend-notes/libvirt-snapshot-benchmarks.md).
`defaultAlgorithmFor(biLibvirt)` stays `clone-per-task` until it produces
restore-to-ready p50 ≤ 10 s and ≥ 4× faster than a cold boot in the same run;
flipping on an analogy would put every libvirt pool — Linux guests included,
where a boot costs a second or two and recycling buys nothing — onto a path
that has never run against a live guest.

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
| libvirt | **O(1) CoW overlay** | implemented (WR0), **not yet timed** | measure restore-vs-boot on the Windows golden, then decide; saved state is immutable across restores, which favours recycling |
| incus | `incus copy` | implemented, cost = f(driver) | **`dir` makes it a full copy; ZFS makes it O(1)** — re-measure when ZFS lands |

The general rule, stated once: **recycle when restoring is cheaper than
creating, clone when it is not.** Hyper-V and incus-on-ZFS sit on one side
of that line, incus-on-`dir` on the other, and libvirt now has a restore to
price but has not yet been priced.
