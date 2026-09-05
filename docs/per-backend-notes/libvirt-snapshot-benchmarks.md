# libvirt snapshot benchmarks

The sibling of
[`hyperv-snapshot-benchmarks.md`](hyperv-snapshot-benchmarks.md), for the
libvirt/QEMU backend. Same operation set, same reporting shape, so the two
backends' numbers are comparable rather than merely adjacent.

> **Read this first — the headline was measured on 2026-09-05, and it is a
> NEGATIVE result.** On the real 16 GiB Windows golden, restore-in-place +
> resume → SSH-ready has a p50 of **46.9 s** and is only **1.57×** faster
> than cold boot in the same interleaved run. The bar was p50 ≤ 10 s AND
> ≥ 4×. **Both thresholds fail, and not narrowly.**
> `defaultAlgorithmFor(biLibvirt)` therefore stays `paClonePerTask`.
> Full numbers and conditions: [Measured on high-mem-server, 2026-09-05 —
> the WR0 headline](#the-wr0-headline).
>
> The *diagnosis* is more useful than the verdict, and points somewhere
> specific: the resume is not the problem. Once the domain is running again
> the guest answers SSH in **1.7 s** — better than Hyper-V's 5.08 s. The
> entire cost is `virsh snapshot-revert --running` itself (**34.4 s**),
> which re-reads a 2.61 GiB memory image at roughly **81 MB/s**. Hyper-V
> moves a comparable 3,395 MB image in ~5 s (~670 MB/s). Whatever WR1 does
> next, this one number is the thing to attack.
>
> Hyper-V's 36 s → 7.2 s remains the **analogy that motivated** this work, on
> a different hypervisor and a different disk format. It is not a measurement
> of libvirt and must not be quoted as one — and now it does not need to be,
> because libvirt has its own.

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
| What does one restore cost, on an OS-less 64 MiB domain? | **≈1.3–1.5 s** wall for `snapshot-revert --running` | three timed reverts; a floor for the primitive on an EMPTY memory image, *not* the WR0 headline — at the real 2.61 GiB memstate the same call costs **34.4 s**, so this primitive's cost is almost entirely memstate size (see [the WR0 headline](#the-wr0-headline)) |
| Does `snapshot-delete` leave residue? | **No.** The active disk returned to the pre-snapshot file, the scratch overlay was removed, and `removeSnapshot` swept the `.memstate`. | `domblklist` + `ls` before/after |
| Are shared install ISOs at risk? | **No** — cdroms are passed `--diskspec <t>,snapshot=no` explicitly. | argv, pinned by `tests/unit/t_libvirt_snapshot_args.nim` |

**The consequence that matters:** "prepare the warm state once, restore it
many times" is the cheap direction on qcow2. The recycle cost does *not*
scale with the guest's memory on the write side; each cycle re-reads the same
memory image and writes only a disposable overlay.

This is a stronger result than Hyper-V's, where recycle cost *does* scale
with how much the job wrote (6.67 s clean vs 13.59 s after a job wrote to
disk, because the restore discards a bigger `.avhdx` delta).

<a id="the-wr0-headline"></a>

## Measured on high-mem-server, 2026-09-05 — the WR0 headline

The rows this note previously listed as "not measured" now have numbers.
Every one of them needed a booted guest with an OS; one was booted.

### What was booted

A throwaway domain `wr0-warm-scratch`: a qcow2 CoW overlay over
`/storage/iso/golden-win11-cloudbase.qcow2`, **16384 MiB / 4 vCPU**, i.e. the
production `eph-win-x64` shape rather than a scaled-down stand-in. Its XML was
derived from the live `win-ci-vm-001` (UEFI/OVMF, `pc-q35-10.1`, `smm`, the
hyperv enlightenments, virtio disk + NIC) so the guest ran on the same virtual
hardware the Windows lane actually uses. Guest reports hostname
`REPRO-N226DFJUD`; login `admin` over Windows OpenSSH.

One deviation from the procedure below, and it matters if you re-run this:
the procedure's `virt-install ... --osinfo win11` produced an interface
attached to the **raw bridge** `virbr0`, i.e. `<interface type='bridge'>`.

The distinction that bites is the **attachment type, not the bridge**.
`domainIpAddress` shells out to `virsh domifaddr`, which reads libvirt's DHCP
lease table, and libvirt only keeps leases for interfaces attached to a
network it manages. A `type='bridge'` interface onto `virbr0` gets an address
from that same dnsmasq and is perfectly reachable, but it is invisible to
`domifaddr` — so `domainIpAddress` returns empty forever, and with it
`revertToBaseline`, `startAndAwaitReady` and every gate that depends on them,
against a guest that is up and healthy.

Both spellings are live on this host, which is why this is easy to trip over:
`win-ci-vm-001` is `type='bridge'` onto `virbr0`, while the `garm-*` ephemeral
runners that `buildEphemeralDomainXml` emits are
`<interface type='network'><source network='default'/>` — same bridge
underneath, different attachment. Use the latter. So if you derive the XML
from `win-ci-vm-001` (below), you **must** replace its interface; inheriting
it verbatim reproduces exactly this failure.

### Host conditions — record these with every number

`high-mem-server`: 32 threads (2 sockets × 8 cores × 2), 377 GiB RAM, ZFS,
`libvirt 11.7.0` / `qemu 10.1.5`. The host was **contended throughout and
increasingly so** — this is the CI host whose contention the campaign exists
to fix, and no maintenance window was taken. `load1` at the start of each
measurement is given per row. The concurrent tenants were `win-ci-vm-001`
plus 2–6 `garm-*` ephemeral runners; none was touched.

### Cold boot → SSH-ready (the baseline)

`virsh start` → guest answers `hostname` over SSH. Prior shutdown graceful,
so this is a clean boot, not crash recovery.

| n | load1 at start | boot → SSH-ready |
| --- | --- | --- |
| 1 | 10.6 | 32.8 s |
| 2 | 34.5 | 52.0 s |
| 3 | 35.2 | 59.0 s |
| 4 | 45.4 | 62.6 s |
| 5 | 49.1 | 63.2 s |
| | **p50 (n=5)** | **59.0 s** |
| | p50 of the load 34–49 cluster (n=4) | 60.8 s |

Cold boot is strongly load-sensitive — 32.8 s at `load1` 10.6 against ~63 s at
`load1` ~49 — so every row above carries the load it was taken at, and the p50
is a p50 *of this host, in this state*, not a property of the guest.

**Do not compare this figure to a runner's end-to-end startup time.** This
interval is `virsh start` → the guest answering SSH. A runner is only useful
some way past that: cloudbase-init still has to finish and the runner agent
still has to be fetched and started. Measured end-to-end startup is
correspondingly larger, and a larger number there is not evidence against the
59 s here — they are different intervals.

One further sample, kept separate because it is a *different* quantity: after
a hard `virsh destroy` the next boot is crash-consistent recovery, and took
**70.9 s** at `load1` 15.5 (n=1).

### Hot snapshot capture (`snapshotRunning`)

| quantity | value |
| --- | --- |
| `snapshot-create-as --live` wall-clock | **34.6 s** (n=1, `phase_a_snapshot_ms`) |
| memory image written | **2,801,249,567 B = 2.61 GiB** |
| memory image ÷ guest RAM | 2.61 GiB / 16 GiB = **16%** |

The memstate is far smaller than the guest's RAM because qemu's
migration-to-file skips zero pages, and a freshly-booted Windows guest is
mostly zeroes. **This is good news for WR1's pool sizing** and it is the
number to size on: a warm member at rest costs ~2.6 GiB of disk, not 16 GiB.
It will grow as a member does real work.

### Restore-in-place + resume → ready

Two independent runs. The gate interleaves the arms so both share host load
(the ratio is the claim); the bench decomposes the warm arm into revert vs
resume (the diagnosis is the value).

**Gate, `VMH_LIBVIRT_WARM_REPS=10`, interleaved, `load1` 11 → 38:**

| arm | per-rep ms | p50 |
| --- | --- | --- |
| warm: `restoreSnapshot` + resume → ready | 41301, 102461, 55069, 48599, 58348, 53335, 21710, 22637, 45238, 27634 | **46.9 s** |
| cold: `restoreSnapshot` (disk-only) + boot → ready | 75227, 82331, 72189, 48103, 46594, 98365, 63705, 85606, 67098, 98651 | **73.7 s** |
| **ratio (cold ÷ warm)** | | **1.57×** |

**Bench (`vm-harness-bench-snapshot-revert`), 5 iterations, `load1` 38 → 71:**

| phase | per-iteration ms | p50 |
| --- | --- | --- |
| `virsh snapshot-revert --running` | 37412, 27432, 34444, 35512, 32179 | **34.4 s** |
| resume → SSH-ready | 2138, 1410, 1486, 1729, 1915 | **1.7 s** |
| total | 39550, 28842, 35930, 37241, 34094 | **35.9 s** |
| teardown (`phase_c_cleanup_ms`) | — one-time phase C, n=1 | 72.8 s |

### Against the targets

| quantity | target | measured | verdict |
| --- | --- | --- | --- |
| restore + resume → ready, p50 | ≤ 10 s | 46.9 s (gate, n=10) / 35.9 s (bench, n=5) | **FAIL, by 3.6–4.7×** |
| ratio vs cold boot → ready, same run | ≥ 4× | **1.57×** (n=10, interleaved) | **FAIL** |

Neither is marginal, and neither is an artifact of the host being busy. The
bench ran at a *higher* load than the gate (38→71 vs 11→38) and produced a
*faster* warm arm, and its per-revert spread stayed tight (27.4–37.4 s) across
that whole load range. A cost dominated by CPU contention would have widened,
not held. The 34 s is structural.

### Where the 34 s sits, and why that is the useful finding

The decomposition is the part WR1 should act on:

```
warm cycle = snapshot-revert --running   34.4 s   ← 96% of it
           + resume to SSH-ready          1.7 s   ←   5% of it
```

**The resume is excellent.** 1.7 s from "domain running again" to the guest
answering SSH beats Hyper-V's 5.08 s on the same guest OS. Nothing about
Windows-on-libvirt coming back from RAM is slow.

**The reload is the whole problem.** 2.61 GiB in 34.4 s ≈ **81 MB/s**.
Hyper-V's `Start-VM` from `Saved` moves a comparable 3,395 MB image in 5.08 s
≈ **668 MB/s** — an ~8× throughput gap on a path that is, in both cases, a
sequential read of a memory image off local storage. That gap, not the guest
and not the algorithm, is what makes libvirt miss a budget Hyper-V clears.

This note deliberately does not guess the cause. Candidates an implementer
should separate before building on top of them: qemu's incoming
migration-from-file may be single-threaded and CPU-bound (`multifd` does not
apply to a file source); the memstate sits on ZFS and may be paying
checksum/ARC costs a raw device would not; and libvirt's external-snapshot
revert tears down and re-creates the QEMU process rather than resuming one in
place. Each is separately measurable and none was measured here.

### The structural properties still hold, now at Windows scale

The earlier OS-less findings were re-confirmed against a real Windows guest
with a real 2.61 GiB memory footprint, across **20 reverts** (10 warm + 10
cold) sampled every 5 s for the snapshot's whole lifetime (286 samples):

| question | answer | evidence |
| --- | --- | --- |
| Does a restore rewrite the memory image? | **No.** | `wr0-warm-scratch.wr0-warm.memstate` held size 2,801,249,567 and mtime `19:38:31.915881177` unchanged **to the nanosecond** from the moment capture finished until the snapshot was deleted at 20:01. |
| Does a restore rewrite the frozen disk? | **No.** | The frozen `wr0-warm-scratch.qcow2` held size 3,899,719,680 / mtime `19:38:11.252419083` across every revert; it first changed at 20:01:53, when teardown deleted the snapshot and libvirt committed the chain back down. |
| What does one restore write? | One fresh, empty, epoch-named qcow2 overlay (`wr0-warm-scratch.<epoch>`), which the NEXT restore deletes. 17 distinct overlay names were observed. | `ls --full-time` sampling |
| **What does one cycle cost on disk?** | **~115–121 MB**, and it is the GUEST's writes, not the restore's. Each warm-restore overlay grew to that size over a rep and was then discarded. The restore itself creates an empty overlay. | max size per overlay: 114.6–120.9 MB |
| Does teardown leave residue? | **No.** | After `removeSnapshot` + `undefine --nvram`: no snapshots, no memstate, no overlay, nothing in `/var/lib/libvirt/images` or the nvram dir. |
| Is the golden untouched? | **Yes.** | `/storage/iso/golden-win11-cloudbase.qcow2` identical size and mtime (`2026-08-23 16:02:03.055280925`) before and after. |

**The consequence for pool sizing:** recycle cost does not scale with guest
memory on the *write* side. A warm member at rest is ~2.6 GiB of immutable
disk plus ~120 MB of disposable per-cycle overlay, and zero host RAM and zero
cores. That part of the campaign's cost argument survives this measurement
intact. What does not survive is the *latency* claim.

### Resume-not-boot: proven

The load-bearing semantic assertion passed on the Windows guest, using
`LastBootUpTime` as the boot witness in place of Linux's `boot_id`:

```
boot witness before/after warm restore:
  2026-09-05T19:32:43.5000000+00:00 / 2026-09-05T19:32:43.5000000+00:00   ← UNCHANGED

boot witness before/after cold restore:
  2026-09-05T19:32:43.5000000+00:00 / 2026-09-05T19:40:25.5000000+00:00   ← CHANGED
```

The non-vacuity arm is what makes the first line mean something: the same
domain, the same `restoreSnapshot` call, a snapshot taken *without* vm state,
and the witness moves. So the warm path is doing something the cold path is
not, and that something is resuming from captured RAM.

**Scope of "proven".** The boot witness above is the whole of the evidence.
The gate's *other* corroboration — the post-snapshot sentinel process, which
must be gone again after a restore — carries none of the weight here, because
the run that produced these lines was also the run that discovered the
sentinel check was self-matching (next section), and **the sentinel arm has
not been re-run to green since that fix**. Re-running it is cheap and should
be folded into the next session on this host; until then the claim rests on
the witness pair alone, which is sufficient but is not the belt-and-braces the
gate was written to provide.

### Two gate bugs this run found

Recorded because both would have made the gate report a pass it had not
earned, and both are fixed in
`tests/e2e/t_libvirt_live_snapshot_restore.nim`:

1. **The sentinel search self-matched.** Re-finding the post-snapshot process
   by command line finds the *query* — `Get-CimInstance Win32_Process`
   enumerates the `powershell.exe` running the `Where-Object` filter, and
   `pgrep -f 'sleep 9999'` matches the `sh -c` that invoked it. The check
   answered "yes" unconditionally, so it could never have observed the
   sentinel's absence after a restore. **This is latent in the shipped Linux
   arm too.** Fixed by returning the PID from `startSentinel` and holding it
   host-side, where the guest cannot roll it back.
2. **The Windows sentinel did not survive its own SSH session.** Windows
   OpenSSH puts session descendants in a job object and kills the job on
   disconnect, so a `Start-Process` child was dead before the snapshot was
   taken. Demonstrated side by side on the live guest: a `Start-Process`
   sentinel (pid 4128) was gone on the next connection, a
   `Win32_Process.Create` sentinel (pid 744) was still alive. Fixed by using
   `Win32_Process.Create`, which parents the process outside the SSH job.

### What is still not measured

| operation | status |
| --- | --- |
| identity preservation across a restore (machine name, DHCP lease) | not measured — one domain, so the collision this would expose could not arise |
| the clone-per-task arm of the comparable pair | **not runnable** — see below |
| whether the 81 MB/s reload is qemu, ZFS, or the process teardown | not measured — the three candidates above are unseparated |

`tools/bench/clone_per_task_bench.nim` could not produce libvirt's clone arm.
Its loop is `revertToBaseline` → `startAndAwaitReady` →
`stopAndCleanup(deleteVm = true)`, and on libvirt `revertToBaseline` does not
clone: it starts the one long-lived domain it was given (`libvirt.nim`, "the
M4 Phase A slice does NOT implement a per-gate-revert clone model"). So
iteration 1 `undefine`s that domain and iteration 2 fails with "is not
defined".

Stronger than "cannot run": **do not point this bench at a domain you want to
keep.** `stopAndCleanup(deleteVm = true)` on a non-ephemeral libvirt handle
calls `undefineDomain` and then `deleteDomainDisk`, so the first iteration
destroys the domain definition, and its disk too if that disk happens to sit
at the conventional `<imagePoolDir>/<name>.qcow2` path.

`--assert-creates-instance` is a weaker guard here than it looks, and this
should be fixed alongside the bench. The check runs *after* the loop, on the
collected handle names, so at the ≥ 2 iterations any real run uses it is never
reached — the "is not defined" crash comes first. At `--iterations 1` it is
reached and *passes* (one handle, one iteration), emitting JSON labelled
`"bench": "clone_per_task"` for what was actually a recycle. So it does not
"refuse to mislabel"; it happens to be shadowed by a crash. What is
straightforwardly wrong is the bench's *header*, where it claims libvirt
"creates a fresh per-job qcow2 CoW overlay… This IS clone-per-task" — that
describes `provisionEphemeralClone`, which this bench does not call. Producing
the arm means pointing it there, which is not WR0's.

This did not block the verdict: the gate's interleaved cold arm is the
apples-to-apples denominator the ratio needs, and the standalone cold-boot
table above is the clean baseline.

One caveat on that denominator, stated so it is not over-read in libvirt's
favour: the gate's cold arm reverts to a disk-only snapshot taken while the
guest was running, so it boots from a crash-consistent image. That is slower
than a clean boot (73.7 s against the 59.0 s clean p50), which makes the
1.57× ratio **flattering**. Against the clean cold-boot p50 the ratio is
59.0 / 46.9 = **1.26×**.

<a id="the-measurement-procedure"></a>

## The measurement procedure

**This procedure was executed on 2026-09-05; its results are
[above](#the-wr0-headline).** It is kept here so the numbers can be
reproduced or re-taken on a quieter host. Three corrections learned by
running it are folded in below and flagged **[2026-09-05]**.

Run on `high-mem-server`, preferably when the `eph-win-x64` queue is idle
(the recorded run was not — see the host-conditions note above). Nothing here
touches `garm-*`, `win-ci-vm-001` or `l3prod-*`.

**1. Make a throwaway domain from the golden.** A CoW overlay over
`/storage/iso/golden-win11-cloudbase.qcow2`, named outside the fleet's
prefixes:

**[2026-09-05]** `/storage/libvirt/` does not exist on this host; the run used
`/storage/wr0-bench/`. And `virt-install --osinfo win11` alone does **not**
produce a domain the harness can drive — it attaches the NIC to the raw bridge
`virbr0`, and `virsh domifaddr` cannot resolve a DHCP lease for a raw-bridge
interface, so `domainIpAddress` returns empty forever while the guest sits
there perfectly healthy with an address. Derive the XML from `win-ci-vm-001`
(`virsh dumpxml --inactive`, then change name/uuid/disk/nvram) so the guest
gets the same UEFI + q35 + hyperv-enlightenment hardware the Windows lane
uses, and give it a **network**-attached interface:

```
mkdir -p /storage/wr0-bench
qemu-img create -f qcow2 -b /storage/iso/golden-win11-cloudbase.qcow2 \
  -F qcow2 /storage/wr0-bench/wr0-warm-scratch.qcow2

virsh dumpxml --inactive win-ci-vm-001 > wr0.xml
# edit wr0.xml: <name>wr0-warm-scratch</name>, drop <uuid>, point the disk at
# /storage/wr0-bench/wr0-warm-scratch.qcow2, point <nvram> at
# .../wr0-warm-scratch_VARS.fd, and replace the interface with:
#   <interface type='network'><source network='default'/>
#     <model type='virtio'/></interface>
virsh define wr0.xml
```

**2. Run the gate.** It boots, snapshots live, mutates, restores, and
asserts resume-not-boot plus the timing thresholds:

```
export LIBVIRT_DEFAULT_URI=qemu:///system
export VMH_LIBVIRT_WARM_DOMAIN=wr0-warm-scratch
export VMH_LIBVIRT_WARM_GUEST_OS=windows
export VMH_LIBVIRT_WARM_SSH_USER=admin
export VMH_LIBVIRT_WARM_SSH_PASSWORD=…      # or …_SSH_KEY
export VMH_LIBVIRT_WARM_REPS=10
export VMH_LIBVIRT_WARM_STATE_DIR=/storage/wr0-bench
nim r --hints:off --path:src tests/e2e/t_libvirt_live_snapshot_restore.nim
```

**[2026-09-05]** The gate is now guest-OS-aware: `VMH_LIBVIRT_WARM_GUEST_OS=windows`
substitutes `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` for
Linux's `boot_id` and PowerShell for the marker/sentinel primitives, so the
semantic arms and the timing arms run against the **same** Windows guest in
one pass. Running the semantic arms on a Linux throwaway is no longer
necessary. `sshpass` must be on `PATH`.

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

**[2026-09-05] The warm arm runs; the clone arm does not.**
`snapshot_revert_bench` works as written and is where the revert-vs-resume
decomposition above came from — run it, it is the more informative of the two.
`clone_per_task_bench` **cannot** be run against libvirt: its loop ends in
`stopAndCleanup(deleteVm = true)`, which undefines the long-lived domain that
libvirt's `revertToBaseline` was given, so iteration 2 fails. See "What is
still not measured" above. Use the standalone cold-boot table as the clone-arm
substitute until the bench is pointed at `provisionEphemeralClone`.

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

**[2026-09-05] Both targets were missed** — 46.9 s against ≤ 10 s, and 1.57×
against ≥ 4×. Keeping the ≥ 4× discount honest paid off exactly as intended:
had the bar been set at Hyper-V's raw 5.0× the verdict would be the same, and
had it been relaxed to "any improvement at all" a 1.57× result would have
passed and put the whole Windows lane on a path that is barely faster than the
boot it replaces. See [the headline](#the-wr0-headline).

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

`defaultAlgorithmFor(biLibvirt)` was **not** flipped to `paRecycleFromPool`,
and as of 2026-09-05 that is a **measured** decision rather than a deferred
one. The measurement ran, on the real Windows golden, and the answer was no:
p50 46.9 s against a ≤ 10 s budget, 1.57× against a ≥ 4× bar.

Be precise about what that does and does not say. Recycling is **not slower**
— it is modestly faster than the cold-boot stand-in, 1.57× against the gate's
interleaved cold arm and 1.26× against a clean boot. What it is not is *worth
it*: `paRecycleFromPool` buys a warm member that carries state between jobs,
and a 1.26–1.57× saving does not pay for that isolation risk, where a 4×+
saving would have. `paClonePerTask` stays because it cannot be wrong about
isolation and the speedup on offer is too small to trade for that — **not**
because it is faster.

And the true clone arm was never measured (the bench that would produce it is
unrunnable here, see above), so even "1.26× faster than clone" is really
"1.26× faster than *booting an existing domain*", which is a **lower bound on
clone cost**: a real clone also creates the overlay and defines the domain.
The honest reading is that recycling wins by somewhat more than 1.26× and
still nowhere near enough.

The reasoning that predicted this is worth keeping, because it turned out to
be right for the right reason: libvirt's trade-off is genuinely unlike
Hyper-V's. Cloning here is already O(1) (a qcow2 CoW overlay), so the recycle
win was only ever the skipped *boot*, not an avoided file copy — and the
measurement now shows the reload of the memory image costs about as much as
the boot it replaces.

**What would justify revisiting the flip:** not a re-run of the same
benchmark, but a change to the 81 MB/s memory-image reload identified in
[the headline section](#the-wr0-headline). Get
`snapshot-revert --running` under ~10 s for a 2.6 GiB memstate and the
arithmetic changes completely, because the other half of the cycle — the
guest's 1.7 s return to SSH-ready — already clears the budget with room to
spare. See the comment on the selector in `src/vm_harness/pool.nim`.
