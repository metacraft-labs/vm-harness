# libvirt snapshot benchmarks

The sibling of
[`hyperv-snapshot-benchmarks.md`](hyperv-snapshot-benchmarks.md), for the
libvirt/QEMU backend. Same operation set, same reporting shape, so the two
backends' numbers are comparable rather than merely adjacent.

> **Read this first.** The timing tables below are **empty on purpose**.
> The snapshot *semantics* in this note were measured on `high-mem-server`
> against real `libvirt 11.7.0` / `qemu 10.1.5`; the *wall-clock* numbers
> were not, because producing them means booting a Windows guest, and that
> host is heavily CPU-contended during CI hours — contention that is already
> known to stretch Windows guest boots badly. Adding a 16 GiB Windows guest
> on top of it would cause real job failures, and would make the resulting
> numbers meaningless anyway.
> [Run the procedure below](#the-measurement-procedure) in a maintenance
> window instead.
>
> Hyper-V's 36 s → 7.2 s is the **analogy that motivated** this work, on a
> different hypervisor and a different disk format. It is not a measurement
> of libvirt and must not be quoted as one.

## What the primitives are

Implemented in `src/vm_harness/backends/libvirt.nim` (campaign WR0):

| method | `virsh` invocation |
| --- | --- |
| `snapshot` (cold) | `snapshot-create-as --domain D --name S --atomic --disk-only --diskspec <t>,snapshot=external,file=…` |
| `snapshotRunning` (hot) | `snapshot-create-as --domain D --name S --atomic --live --memspec file=…,snapshot=external --diskspec <t>,snapshot=external,file=…` |
| `restoreSnapshot` | `snapshot-revert --domain D --snapshotname S --running` (retried once with `--force` if, and only if, libvirt answers "revert requires force") |
| `listSnapshots` | `snapshot-list --domain D --name` |
| `removeSnapshot` | `snapshot-delete --domain D --snapshotname S`, then the RAM image |

`exportBaseline` / `importBaseline` remain unimplemented; they are WR3's.

## External, not internal — and why

`virsh snapshot-create-as` offers two families, and the choice is not
cosmetic:

* **Internal** (the no-flag default) writes the disk delta and, for a
  running domain, the RAM image *inside* the domain's own qcow2. The guest
  is stunned for the whole memory dump, and `--live` is rejected outright.
  virsh(1): *"If `--live` is specified, libvirt takes the snapshot while the
  guest is running. … This is currently supported only for external full
  system snapshots."*
* **External** freezes the current disk file — that frozen file *is* the
  snapshot — layers a fresh overlay on top for subsequent writes, and
  streams the RAM image to a separate file by live migration-to-file, so the
  guest keeps running.

The warm-pool model prepares a member's warm state once and restores it many
times (`pool.nim`: `release` restores, not `acquire`), so it wants the saved
state immutable and the per-cycle write small. External gives exactly that.

Reverting *to* an external snapshot requires libvirt ≥ 10.9. `high-mem-server`
runs 11.7.0. On an older libvirt `restoreSnapshot` surfaces the refusal as a
plain `virsh` error rather than silently degrading to a cold boot.

### Where the snapshot state file lives

This was WR0's one open design point (campaign, *Outstanding Tasks*). The
answer, measured rather than assumed:

The snapshot stacks **on top of** whatever the domain's active disk already
is. A warm pool member is a long-lived domain whose active disk is its own
CoW overlay over the shared golden, so after `snapshotRunning` the chain is

```
golden.qcow2            shared, read-only, never written
  └── member overlay    FROZEN — this is the snapshot's disk state
        └── scratch     re-created by every restore, discarded on the next
```

plus a separate `<domain>.<snapshot>.memstate` holding the RAM. The golden is
never touched, which is what keeps this compatible with the per-job CoW path
the GARM provider uses today (`virsh.go` teardown is untouched by WR0).

The artifacts default to the image pool dir and are relocatable with
`newLibvirtBackend(snapshotStateDir = …)`, because a warm Windows member's
RAM image is the guest's entire memory (16 GiB on `eph-win-x64`) and an
operator may want that off the golden's volume.

## Measured on high-mem-server, 2026-09-05 — semantics, not timings

Real `virsh 11.7.0`, `qemu:///session`, a 64 MiB scratch domain with no OS.
Reproduced by `tests/e2e/t_libvirt_snapshot_surface_conformance.nim`.

| question | answer | how it was established |
| --- | --- | --- |
| Does `--live` work on its own — the stub's original prescription? | **No.** `error: Operation not supported: live snapshot creation is supported only during full system snapshots`. Identical on a running domain, on a shut-off one, and with `--live --disk-only`. | direct `virsh` invocation |
| What makes `--live` legal, then? | An external **memspec**. `--live --memspec file=…,snapshot=external` succeeds. (`--memspec file=…` alone also succeeds under `--live` — libvirt records `<memory snapshot='external'/>` either way — but the backend passes `snapshot=external` explicitly rather than relying on that default.) | direct `virsh` invocation |
| Where does `memory state cannot be saved with offline or disk-only snapshot` come from? | The *other* refusal: a memspec on a **disk-only or shut-off** snapshot (`--disk-only --memspec …`, or `--memspec …` against a shut-off domain). It is not what plain `--live` returns. | direct `virsh` invocation |
| Can libvirt 11.7 revert *to* an external snapshot? | **Yes** | `snapshot-revert` returned "Domain snapshot … reverted"; the qemu driver exports `qemuSnapshotRevertExternal*` and carries no "not supported" string for it |
| **Does a restore rewrite the saved state?** | **No.** | Three consecutive reverts to a **hot** (memstate-carrying) snapshot left both the frozen disk file *and* the memory image byte-identical, with mtimes unchanged to the nanosecond. Each revert *deleted* the previous scratch overlay and created a new empty one (`disk.<epoch>`, backed by the frozen file). Asserted by the conformance gate. |
| What does one restore write? | one fresh, empty qcow2 overlay — `qemu-img info` allocated size **4.5 KiB** | `qemu-img info --backing-chain` after a revert |
| What does one restore cost, on an OS-less 64 MiB domain? | **≈1.3–1.5 s** wall for `snapshot-revert --running` | three timed reverts; a floor for the primitive, *not* the WR0 headline (see [NOT measured](#not-measured-here)) |
| Does `snapshot-delete` leave residue? | **No.** The active disk returned to the pre-snapshot file, the scratch overlay was removed, and `removeSnapshot` swept the `.memstate`. | `domblklist` + `ls` before/after |
| Are shared install ISOs at risk? | **No** — cdroms are passed `--diskspec <t>,snapshot=no` explicitly. | argv, pinned by `tests/unit/t_libvirt_snapshot_args.nim` |

**The consequence that matters:** "prepare the warm state once, restore it
many times" is the cheap direction on qcow2. The recycle cost does *not*
scale with the guest's memory on the write side; each cycle re-reads the same
memory image and writes only a disposable overlay.

This is a stronger result than Hyper-V's, where recycle cost *does* scale
with how much the job wrote (6.67 s clean vs 13.59 s after a job wrote to
disk, because the restore discards a bigger `.avhdx` delta).

## NOT measured here

| operation | status |
| --- | --- |
| cold boot → SSH-ready (Windows golden) | not measured |
| `restoreSnapshot` + resume → SSH-**ready** | not measured |
| **resume-not-boot semantics** (the guest's kernel survives a restore) | not measured |
| RAM-capture cost / write bandwidth at Windows-lane memory sizes (16 GiB) | not measured |
| identity preservation across a restore (machine name, DHCP lease) | not measured |

Every row above needs a **booted guest with an OS**. None was booted for this
note.

What *is* covered without one, and is asserted by the conformance gate: the
`snapshotRunning` **success path** against a real running domain — `--live`
with an external memspec is accepted by virsh 11.7, a real memory image is
written, the scratch overlay lands at exactly the path `snapshotDiskPathFor`
generates, `restoreSnapshot` consumes that hot snapshot and leaves the domain
`running`, and `removeSnapshot` sweeps the memory image. That is the
*mechanism*. It is **not** evidence that a restore RESUMES rather than boots —
proving that needs a kernel to survive, which needs a guest OS. Do not read
the two as the same claim.

<a id="the-measurement-procedure"></a>

## The measurement procedure

Run in a maintenance window, on `high-mem-server`, when the `eph-win-x64`
queue is idle. Nothing here touches `garm-*` or `win-ci-vm-001`.

**1. Make a throwaway domain from the golden.** A CoW overlay over
`/storage/iso/golden-win11-cloudbase.qcow2`, named outside the fleet's
prefixes:

```
qemu-img create -f qcow2 -b /storage/iso/golden-win11-cloudbase.qcow2 \
  -F qcow2 /storage/libvirt/wr0-warm-scratch.qcow2
virt-install --name wr0-warm-scratch --import \
  --disk path=/storage/libvirt/wr0-warm-scratch.qcow2,format=qcow2 \
  --memory 16384 --vcpus 4 --osinfo win11 --noautoconsole
```

**2. Run the gate.** It boots, snapshots live, mutates, restores, and
asserts resume-not-boot plus the timing thresholds:

```
export LIBVIRT_DEFAULT_URI=qemu:///system
export VMH_LIBVIRT_WARM_DOMAIN=wr0-warm-scratch
export VMH_LIBVIRT_WARM_SSH_USER=admin
export VMH_LIBVIRT_WARM_SSH_PASSWORD=…      # or …_SSH_KEY
export VMH_LIBVIRT_WARM_REPS=10
nim r --hints:off tests/e2e/t_libvirt_live_snapshot_restore.nim
```

The gate's boot-id assertions are Linux-guest specific. For the Windows
golden, either run it against a Linux throwaway for the semantic arms and
use the bench below for the numbers, or substitute
`(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` for the boot id.

**3. Produce the comparable pair.** The two bench programs emit the same
JSON shape and the same median, which is what makes them comparable:

```
build/bin/vm-harness-bench-snapshot-revert \
  --backend libvirt --vm wr0-warm-scratch --baseline wr0-warm-scratch \
  --hot-name wr0-warm --iterations 10 --output warm.json

nim c -r tools/bench/clone_per_task_bench.nim \
  --backend libvirt --baseline wr0-warm-scratch --iterations 10 \
  --assert-creates-instance --output clone.json
```

**4. Tear down.** `virsh destroy` / `virsh undefine --nvram` the throwaway,
delete its overlay, and confirm `virsh list --all` shows only the fleet.

### Targets, and where each comes from

| quantity | target | derivation |
| --- | --- | --- |
| `restoreSnapshot` + resume → ready, p50 | **≤ 10 s** | the pre-existing per-backend budget for libvirt in `docs/design.md` §3.4, and the threshold `Multi-OS-VM-Automation-Campaign` M4 already named |
| ratio vs cold boot → ready, same run | **≥ 4×** | Hyper-V measured 36 s / 7.2 s = 5.0× on the same guest OS, discounted to 4× to absorb qcow2-vs-VHDX and host differences without letting a null result pass |

Report the absolutes **separately** from the ratio. The ratio is the claim; an
unrelated host-side CPU-scheduling change landing in the same window moves the
absolutes and must not be mistaken for this backend's effect.

## Identity, and why a pool is N warm states rather than N copies of one

A snapshot that carries RAM carries the guest's machine name and DHCP lease
with it. On Hyper-V, two guests restored from one warm checkpoint came up as
`WIN-EDC8DG9PTDT` on `172.27.94.244` — *both of them*.

libvirt's snapshots are per-domain, so `snapshot-revert` cannot itself apply
one warm state to two domains. The route that *would* is file sharing, so
`snapshotRunning` refuses to run when:

* another defined domain has the same writable disk file attached, or
* the memory-state path it is about to write already exists.

Both refusals name the colliding domain or file. The other route is
export/import of a baseline — which is exactly why `exportBaseline` /
`importBaseline` are left unimplemented for WR3 rather than bolted on here:
whoever writes them owes this problem an answer.

## Selection: libvirt still uses `clone-per-task`

`defaultAlgorithmFor(biLibvirt)` was **not** flipped to
`paRecycleFromPool` by WR0. The primitives exist and the storage semantics
are favourable, but the number that decides the trade-off does not exist yet,
and libvirt's trade-off is genuinely unlike Hyper-V's: cloning here is already
O(1) (a qcow2 CoW overlay), so the recycle win is the skipped *boot* alone,
not an avoided file copy. Flip it when step 2/3 above produces ≤ 10 s p50 and
≥ 4×. See the comment on the selector in `src/vm_harness/pool.nim`.
