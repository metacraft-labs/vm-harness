# Hyper-V snapshot benchmarks

Reference wall-clock measurements for the three Hyper-V revert paths
that `revertToBaseline` can use: **cold checkpoint**, **hot Standard
Checkpoint**, and a **portable** (exported + re-imported) hot
checkpoint. The numbers exist to inform implementers — they are
reproducible reference data, not a per-host guarantee.

## TL;DR

| Path | Per-revert wall-clock | Per-Gate Reset budget (`docs/design.md` §3.4) |
|---|---|---|
| Cold checkpoint (`Restore-VMCheckpoint` to a snapshot taken with VM Off) | 28 - 46 s | misses ≤ 10 s by 3-4× |
| **Hot Standard Checkpoint** (`Restore-VMCheckpoint` to a snapshot taken with VM running, captures RAM + CPU + device state) | **5.4 s** | meets ≤ 10 s |
| Hot checkpoint imported on a fresh host (`Import-VM` of a previously `Export-VM`'d image, then `Restore-VMCheckpoint` + `Start-VM`) | **~8 s** | meets ≤ 10 s |

The path the backend picks at runtime is determined entirely by **how
the baseline checkpoint was created**, not by any change to the API
surface. `Restore-VMCheckpoint` is the same cmdlet in all three cases.

## Hardware (reference host)

These numbers were collected on:

- **CPU**: AMD Ryzen 9 9950X (16 cores / 32 threads, base 4.3 GHz, Zen 5)
- **RAM**: 128 GB DDR5
- **Disk**: Kingston KC3000 NVMe SSD (PCIe 4.0, sequential ~7 GB/s)
- **OS**: Windows 11 Pro, build 26200
- **Hyper-V**: built-in, Generation 2 guest VM, 4 GB guest RAM, 4 vCPUs
- **Guest**: Windows 11 dev VHDX (the Microsoft Quick Create gallery image)

Hot-checkpoint revert is **memory + state image deserialization**, so
absolute numbers track NVMe sequential read speed and host CPU
single-thread performance. On a host with SATA SSD or a smaller CPU,
expect the revert times to scale roughly linearly with disk bandwidth.

## Methodology

Reproducible PowerShell scripts that emit timestamped checkpoints
(`T0`…`T5`) into a flat TIMINGS file. Each phase is timed with a
`System.Diagnostics.Stopwatch` started immediately before the
operation under test. The scripts are short and self-contained; any
implementer can adapt them to drive the equivalent measurement on a
different host.

The same payload (a trivial `Invoke-Command -VMName { hostname }`)
runs in every cycle so the per-environment overhead is the only
variable.

For each path:

- **Cold revert**: `Stop-VM -TurnOff` → `Restore-VMCheckpoint -Name <cold>`
  → `Start-VM` → poll `Invoke-Command -VMName { hostname }` until success.
- **Hot revert**: One-time setup creates a hot baseline by
  `Start-VM` → wait for PSDirect → `Checkpoint-VM -SnapshotName <hot>`.
  Then per-test cycle is `Restore-VMCheckpoint -Name <hot>` → poll PSDirect.
- **Portable**: `Export-VM -Path <dir>` of the VM after the hot
  checkpoint is taken → `Import-VM -Path <vmcx> -Copy -GenerateNewId`
  on the destination → `Restore-VMCheckpoint` → `Start-VM` → poll.

## Cold revert

| Phase | Wall-clock |
|---|---|
| `Restore-VMCheckpoint` (cold snapshot) | 0.2 s |
| `Start-VM` + Windows boot to PSDirect-ready | 26 - 44 s |
| `Copy-VMFile` (host → guest, small file) | 0.2 s |
| `Invoke-Command -VMName` round-trip | 1.5 s |
| `Stop-VM -TurnOff` | 0.3 s |
| **Total** | **28 - 46 s** |

Variability comes from Windows guest boot — file-cache state on the
host disk, background services in the guest, and Windows Update
opportunism on first boot all contribute. The 28 s figure was measured
shortly after a previous run (warm file cache); the 46 s figure was a
cold first-boot of the day.

The dominant cost is `Start-VM` + guest boot, not the
`Restore-VMCheckpoint` call itself.

## Hot revert

One-time setup (paid once per baseline):

| Phase | Wall-clock |
|---|---|
| Cold boot to PSDirect-ready | 43.8 s |
| `Checkpoint-VM -SnapshotName <hot>` (Standard, captures RAM + CPU + device state of the running VM) | 2.1 s |

Per-test cycle (×3 iterations, averaged):

| Phase | Wall-clock |
|---|---|
| `Restore-VMCheckpoint -Name <hot>` | 4.5 s |
| `Invoke-Command -VMName` first successful round-trip | 0.95 s |
| **Per-revert total** | **5.4 s** |

Iteration consistency: 5.10 s, 5.65 s, 5.48 s — variance is small,
dominated by the `Restore-VMCheckpoint` memory-image read.

Hot revert is **faster than the cold cmdlet's network/RPC stage
alone** (Invoke-Command round-trip ~1.5 s on cold path → ~0.95 s on
hot path) because the guest's PowerShell host process is already
warm.

## Portable hot checkpoint

`Export-VM` of a VM that has a hot Standard Checkpoint produces an
export folder containing `.VMRS` files — Hyper-V's Virtual Machine
Runtime State (memory + CPU + device-state image of each Standard
Checkpoint).

### Export

| Item | Value |
|---|---|
| `Export-VM -Path <dir>` returned | 1.7 s |
| Total export folder size | 53 GB |
| `.vhdx` files (base + diff) | 52 GB |
| `.avhdx` files (snapshot diffs) | 1.3 GB |
| **`.VMRS` files (memory + CPU + device state)** | **0.69 GB** |
| `.vmgs` files (guest state) | 12 MB |
| `.vmcx` files (VM/snapshot configs) | < 1 MB |

The 1.7 s figure is misleading for cross-host transfer: on the same
NTFS volume, `Export-VM` uses reflinks/hardlinks for the VHDX content,
so the "53 GB export" did not actually move 53 GB of bytes. **The real
cross-host transfer payload is ~10 GB** (the VHDX content the
differencing chain depends on) + **0.69 GB** (the memory-state image)
+ ~13 MB (config) ≈ **10.7 GB uncompressed**.

VHDX content is sparse-provisioned with many zero regions, so the
on-wire size after compression (`xz` / `zstd`) is materially smaller.

### Import + resume

| Phase | Wall-clock |
|---|---|
| `Import-VM -Path <vmcx> -Copy -GenerateNewId` | 3.0 s |
| Imported snapshot tree (verified) | `cold, hot` ✓ both present |
| `Restore-VMCheckpoint -Name <hot>` on imported VM | 0.13 s |
| `Start-VM` (memory resume from saved state) | 3.7 s |
| `Invoke-Command -VMName` round-trip | 1.0 s |
| **Total import + resume** | **~8 s** |

The imported VM's `Start-VM` is fast (3.7 s) because the snapshot's
memory state is being loaded from disk rather than a Windows kernel
performing a cold boot. 0.69 GB memory state → 3.7 s loading ≈
180 MB/s, well within NVMe bandwidth.

### Cross-host caveats

Tested on a single host (round-trip Export → Import on the same
machine). Cross-host transfer should work, with these caveats:

- **CPU compatibility.** Memory-state snapshots capture CPU registers
  and feature flags. Importing on a CPU that lacks features the
  snapshot expects (e.g., older AVX support) may fail or produce
  subtle runtime errors. Hyper-V VM CPU configuration has a "Migrate
  to a physical computer with a different processor version" option
  that masks features down to a baseline — set it on the warmer host
  if the destination fleet is heterogeneous.
- **Hyper-V version skew.** A newer Hyper-V's export should import on
  the same or newer version; downgrade is not supported.
- **Generation 1 vs 2.** Both ends must match the VM generation.

## Implication for `revertToBaseline`

The performance contract in `docs/design.md` §3.4 budgets Hyper-V at
≤ 10 s per revert. The same `Restore-VMCheckpoint` invocation meets or
misses the budget by **3-4×** depending solely on **how the
checkpoint was created**:

- Checkpoints taken with the VM **Off** → cold path, 28-46 s, **misses**.
- Checkpoints taken with the VM **running** (Standard Checkpoint type)
  → hot path, 5.4 s, **meets**.

The `HyperVBackend.provisionBaseline` step should therefore boot the
VM, wait for guest readiness (PSDirect / SSH), then call
`Checkpoint-VM -SnapshotType Standard` while the VM is running. The
existing `Restore-VMCheckpoint`-based revert code needs no change.

For multi-runner fleets where each runner would otherwise pay the
44 s boot cost, the **portable hot checkpoint** pattern enables a
warm-image cache:

1. One "warmer" runner boots the baseline, takes a hot checkpoint,
   `Export-VM`s, compresses, and uploads the export as a build artifact.
2. Every other runner downloads the artifact, `Import-VM`s, and
   immediately runs `Restore-VMCheckpoint` → `Start-VM` to reach
   PSDirect-ready in ~8 s.

The artifact is ~10 GB uncompressed; compressed it is materially
smaller (high VHDX zero-fraction).

## Reproducing

The PowerShell scripts that produced these numbers live outside this
repository — they are reproducible against any provisioned Hyper-V VM
with a known baseline snapshot. The procedure has no project-specific
dependencies; it requires only:

- A Hyper-V host (Windows 10/11 Pro or Server with the Hyper-V role).
- A Generation 2 VM with PowerShell Direct / SSH reachable.
- A baseline checkpoint named (e.g.) `base-clean`.
- Credentials cached for `Invoke-Command -VMName -Credential`.

Adapting the scripts to a different baseline VM is a matter of
changing the VM and snapshot names; the timing structure is unchanged.

---

## win-ci-bare-001, 2026-08-21 — a real Windows 11 golden, and what it settles

The numbers above were taken on a Quick Create gallery image. These were
taken on the actual artifact the ephemeral-runner pool will use: a Windows
11 Pro 25H2 (build 26200) golden built by
`guest-recipes/windows-x64-base/build-golden-hyperv.ps1`, 20.25 GB
installed, 4 vCPU / 8 GB, on an i9-12900K with NVMe.

| operation | time | what it is |
| --------- | ---- | ---------- |
| cold boot to PSDirect-ready | **36 s** | the baseline to beat |
| `Checkpoint-VM` (cold, VM off) | 0.46 s | |
| `Checkpoint-VM` (hot, VM running) | 5.38 s | captures RAM + CPU + device state |
| `Export-VM` (live) | 21.07 s | 3,395 MB `.VMRS` memory image |
| `Import-VM -Copy -GenerateNewId` | 28.67 s | |
| `Restore-VMCheckpoint` | 2.16 s | leaves the VM in `Saved` |
| `Start-VM` from `Saved` → ready | **5.08 s** | resumes; does not boot |

The clone reported `Uptime 00:02:41` immediately on resume — it inherited
the golden's uptime, which is the proof that it resumed from captured RAM
rather than booting.

### The win is restore-in-place, NOT clone-per-job

Adding the columns up decides the architecture:

```
A) clone per job : Import 28.67 + Restore 2.16 + Resume 5.08 = 35.9 s
B) warm pool     :                Restore 2.16 + Resume 5.08 =  7.2 s
```

**A is no better than just cold-booting a VM (36 s).** The ~8 s figure in the
portable-path section above is the restore+resume tail only; it is not the
cost of producing a fresh guest from an export. Import dominates, and it is
pool-CONSTRUCTION cost — pay it once per pool member, never per job.

### A hot checkpoint captures network identity, and that is load-bearing

Two guests restored from the SAME warm checkpoint, running concurrently:

```
repro-golden-win11-x64   name=WIN-EDC8DG9PTDT  ip=172.27.94.244
repro-hot-001            name=WIN-EDC8DG9PTDT  ip=172.27.94.244
```

Identical computer name AND identical IP. RAM state includes the DHCP lease
and the machine name, so cloning one warm state N times yields N colliding
guests — NetBIOS conflicts and two VMs claiming one lease, which breaks the
outbound reachability a CI runner exists to use.

This is not an argument for sysprep. Sysprep `/generalize` forces OOBE on
first boot, which destroys the entire benefit — a generalized golden can
only ever be cold-booted.

It is an argument for the same design the timings already point at:
**pre-create N pool members, boot each so it acquires its OWN name and
lease, then hot-checkpoint each individually.** Restoring member *n* returns
it to *its own* identity, so there is nothing to collide. The pool is N
distinct warm states, not N copies of one.

### Consequences for pool sizing

Per-member cost is one 20 GB VHDX plus a ~3.4 GB memory image. The
`Import-VM` step is where cheap block copies would pay off (this host's C:
is NTFS, D: is ReFS) — but only at pool construction, which is the one time
nobody is waiting.

### Recycling: restore-to-baseline is the per-job path, cloning is not

Cloning and restoring answer different questions, and conflating them is
what made clone-per-job look attractive:

* **Clone (`Export-VM` + `Import-VM`, ~50 s)** changes POOL CAPACITY. It
  adds a member. Nobody is waiting on it.
* **Restore (`Restore-VMCheckpoint` + resume, 7-14 s)** RECYCLES a member
  between jobs. It happens constantly.

And because a member can be restored the moment its job FINISHES rather than
when the next one arrives, the recycle cost sits between jobs instead of in
front of them: a pool member is already warm and waiting when work is
dispatched, so per-job start latency approaches zero.

Verified on the 25H2 golden, 2026-08-21:

| step | time |
| ---- | ---- |
| restore to `warm` + resume, from a clean member | 6.67 s |
| restore to `warm` + resume, after a job wrote to disk | 13.59 s |

**Recycle cost scales with how much the job wrote**, because restoring
discards the checkpoint's `.avhdx` delta and a busy job makes a bigger one.
6.67 s is the floor, not the number to plan capacity against; budget the
higher figure for real workloads.

The isolation guarantee was checked rather than assumed. A simulated job
created `C:\_work\job-42\artifact.txt`; after the restore both the file and
its directory were gone, while the member kept its own computer name, its
own DHCP lease, and an uptime of 00:33:39 — i.e. it resumed into its warm
state rather than rebooting, and did not acquire a new identity. That is
exactly the property the N-distinct-warm-states design needs: recycling
returns a member to ITS baseline, so nothing ever collides.
