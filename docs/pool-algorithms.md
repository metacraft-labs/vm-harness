# Pool algorithms: `clone-per-task` and `recycle-from-pool-per-task`

An ephemeral-runner host can serve tasks one of two ways. They are not
interchangeable, they are not tunable at runtime, and which one is right is
**a property of the backend's storage** rather than of the workload.

This page defines both, lists the primitives each requires, states the rule
for choosing between them, and records the per-backend selection.

**The selection is made at development time, from measurement, and then
fixed in code.** It is deliberately NOT a runtime probe: the cost of the
primitives is a stable property of a backend plus its storage driver, so
paying to rediscover it on every host start would be waste, and a
backend that silently switched algorithms would make latency
irreproducible.

## The two algorithms

### `clone-per-task`

```
per task:
  create instance from golden      <- the whole cost lives here
  start + await ready
  ... run the task ...
  destroy instance
```

Every task gets an instance that has never existed before. Isolation is
absolute and free: there is no prior state to leak, because there is no
prior state.

Required primitives:

| primitive | why |
| --------- | --- |
| create-from-golden | the per-task cost |
| start + await-ready | the guest must reach a usable state |
| destroy | reclaim |

### `recycle-from-pool-per-task`

```
once, at pool construction:
  for each of N members:
    create instance from golden
    boot it so it acquires its OWN identity
    checkpoint it as that member's baseline

per task:
  claim an already-warm member
  ... run the task ...
  restore member to its baseline    <- the whole cost lives here
```

Members are long-lived; only their *state* is ephemeral.

Required primitives:

| primitive | why |
| --------- | --- |
| checkpoint (ideally capturing RAM) | defines the baseline |
| restore-to-checkpoint | the per-task cost |
| resume/start + await-ready | back to usable |
| create-from-golden | still needed, but only to change CAPACITY |

Two properties are easy to miss and both matter:

- **The recycle can happen when a task FINISHES, not when the next one
  starts.** A member is already warm and waiting when work arrives, so the
  restore cost sits *between* tasks rather than in front of them, and
  per-task start latency approaches zero.
- **Each member must be checkpointed with its own identity.** A checkpoint
  that captures RAM captures the machine name and DHCP lease with it, so N
  members restored from ONE shared checkpoint collide. The pool is N
  distinct baselines, not N copies of one. Measured, not assumed — see the
  identity-collision section of
  [`per-backend-notes/hyperv-snapshot-benchmarks.md`](per-backend-notes/hyperv-snapshot-benchmarks.md).

## The decision rule

> **Recycle when restoring is cheaper than creating. Clone when it is not.**

Compare, per task:

```
clone-per-task    = create_from_golden + start_to_ready
recycle-per-task  = restore_to_baseline + resume_to_ready
```

Pool construction (N x create) is excluded from the comparison on purpose:
it is amortised over the host's lifetime and nobody waits on it.

Three secondary considerations, applied only when the primary comparison is
close:

- **Disk.** `recycle` holds N instances resident; `clone` holds one golden
  plus whatever is in flight. On copy-on-write storage this difference
  mostly disappears.
- **Isolation confidence.** `clone` is isolated by construction. `recycle`
  is isolated only as far as the restore is complete — it must be verified,
  not assumed, that a restore actually discards task residue.
- **Blast radius of a stuck member.** A `recycle` pool can wedge a member
  and lose capacity until something notices; `clone` has no such state.

## Measurement protocol

Both numbers come from `tools/bench/`, which drives the library API and
emits JSON so results are comparable across hosts:

- `snapshot_revert_bench.nim` measures the **recycle** loop
  (`restoreSnapshot` + `startAndAwaitReady`, N iterations, median reported).
- `clone_per_task_bench.nim` measures the **clone** loop
  (`revertToBaseline` producing a fresh instance + `startAndAwaitReady` +
  `stopAndCleanup(deleteVm = true)`).

Report the **median**, not the mean: both loops have occasional multi-second
outliers from host I/O, and a mean lets one outlier decide an architecture.

Measure with a realistic guest. Recycle cost scales with how much the task
wrote — restoring discards the checkpoint's delta — so a benchmark that
runs no workload measures the floor rather than the operating point.

## Per-backend selection

| backend | clone/task | recycle/task | selected | basis |
| ------- | ---------- | ------------ | -------- | ----- |
| **Hyper-V** | ~50 s (`Export-VM` + `Import-VM`, real copy) | **12-19 s** (restore + resume, carries RAM; see the variance section before quoting a lower number) | **`recycle-from-pool-per-task`** | measured 2026-08-21, win-ci-bare-001 |
| **libvirt** | **O(1)** (`qemu-img create -b <golden>` CoW overlay) + full guest boot | *not implemented* (`snapshot`/`restoreSnapshot` raise; M4 Phase B) | **`clone-per-task`** (forced) | read from `libvirt.nim:652`, `1561-1602` |
| **incus** | `incus copy` / launch from image | implemented, but cost = f(storage driver) | **undecided** | needs measurement on `dir` vs ZFS |

### Hyper-V — `recycle`, and the margin is large

Cloning is a real file copy: `Import-VM` alone is 28.67 s, making
clone-per-task 35.9 s — no better than the 36 s cold boot it was supposed
to avoid. Recycling restores a checkpoint carrying RAM, so a member resumes
in ~5 s. Selection is not marginal.

### libvirt — `clone`, but only because `recycle` does not exist

Here the premise inverts: cloning is already O(1), a qcow2 CoW overlay over
the golden with no bytes copied. But `snapshot`, `snapshotRunning`,
`restoreSnapshot`, `listSnapshots` and `removeSnapshot` are unimplemented
stubs that raise, so `recycle` cannot be selected at all.

This makes the selection **forced rather than reasoned**, and the
consequence is specific: a libvirt guest always pays a full boot. For Linux
guests that is minor. For the **Windows** guest on `eph-win-x64` it is the
same image Hyper-V takes from 36 s to 5 s, so the unclaimed win is large.
Implementing M4 Phase B (`virsh snapshot-create-as --live`, or
`virsh save`/`restore`) would make libvirt a genuine choice rather than a
default, and it should be re-measured then.

### incus — undecided, and blocked on storage

The primitives exist (`incus.nim:598-665`). Two things stop a selection:

1. **A container has no boot to skip.** It starts in about a second, so
   there is no 36 s -> 5 s prize; recycling buys *isolation*, not speed.
   `snapshotRunning` already takes a filesystem rather than a CRIU stateful
   snapshot for exactly this reason.
2. **The default pool is `driver = "dir"`**
   (`per-backend-notes/incus.md:36`), where an instance is a plain
   directory tree — so `incus snapshot create` and `restore` are full
   recursive copies whose cost scales with rootfs size. On ZFS the same
   commands are metadata-only (snapshot / rollback), and `incus copy`
   becomes a `zfs clone`, so BOTH sides of the comparison change at once.

So incus is the one backend where the answer genuinely flips with
configuration. The comparison to beat there is **delete-and-relaunch**, not
cold boot — on `dir`, restoring a rootfs can plausibly cost more than
launching a fresh container from the image, which would make `recycle` a
pessimisation.

Re-measure when the ZFS storage driver lands, on both drivers, and record
the result here.

## Proven end to end on Hyper-V, 2026-08-21

`recycle-from-pool-per-task` now serves real GitHub Actions jobs on
`win-ci-bare-001`, via `tools/hyperv-pool.ps1` (capacity) and
`tools/hyperv-scale-set.ps1` (jobs). The proving workflow is
`infra/.github/workflows/pm6-hyperv-pool-selftest.yml`.

One full cycle, measured:

```
job dispatched   -> run 32505536668, conclusion: success
served by        -> runner hv-pool-000 on guest REPRO-POOL-000
                    Windows 11 Pro build 26200, 4 vCPU
                    (NOT the bare-metal host -- the workflow fails if it is)
job wrote        -> C:\_pm6\residue.txt
recycle          -> restore 17.41s, ready at 22.88s
after recycle    -> residue gone, directory gone, runner UNCONFIGURED,
                    runner + pwsh still installed,
                    identity intact: REPRO-POOL-000 / 172.27.93.235
```

That last line is the property the design exists for: the member came back
as ITSELF, not as a copy of some shared state, with everything the task did
erased and everything the baseline provides still present.

### Restore cost is NOT the 2.16s the earlier benchmark suggested

Every `Restore-VMCheckpoint` measured on this host, in order taken:

```
2.16   12.63   20.89   26.80   56.29   80.07   169.96   17.41   (seconds)
```

Two orders of magnitude, including 169.96s on a completely idle host with
the disk queue at zero, on a member whose delta from its baseline was only
0.50 GB. **The 7.2s per-task figure quoted earlier came from a favourable
sample and should not be planned against.** Whatever drives the variance is
not explained by contention, delta size or memory image size -- all three
were checked -- and it is the open question this design most needs answered,
because it decides whether recycling beats the 36s cold boot reliably or
only sometimes.

What IS stable: the resume half. Once the restore completes, the guest is
reachable again in 4-9s across every measurement, because it resumes from
RAM rather than booting.

#### A lead: every wild outlier was on a long-uptime host

After an unplanned host reboot the same pool was re-measured, six recycles
in fifteen minutes, host uptime under 20 minutes throughout:

```
recycle (restore + resume), seconds
12.32   13.34   14.25   16.82   19.00   18.03
of which resume:
 1.63    2.35    1.13    2.00    2.15    1.96
```

So restore alone was 10.7-16.9s, in a 1.6x band — against the 79x spread of
the earlier series. Every measurement over 50s came from a host that had
been up for hours and had built and torn down VMs the whole time; none of
tonight's did.

**This is a correlation with n=1 reboot, not a cause.** It is recorded
because it is the first variable that tracks the outliers after contention,
delta size and memory-image size were each checked and ruled out, and it
suggests where to look: host-side state that accumulates with uptime
(free-memory fragmentation, the VMMS working set, or Hyper-V's own page
file), rather than anything about the member being restored. The test that
would settle it is cheap — recycle on a freshly booted host, then again
after a day of pool churn, same member, same delta.

Until that is done, plan against the **upper** end. Even 19s beats the 36s
cold boot, and it beats it off the critical path, so the selection stands
either way; what is not yet safe is quoting a single-digit figure.

### Golden hygiene is not optional

Two properties had to be forced into the image before the pool behaved:

* **Windows Update disabled.** The golden had network during its install,
  so updates were staged; members then applied them on FIRST BOOT (one sat
  at "You're 1% there" for over an hour) and would otherwise apply them
  mid-job. Disabling it took a member's settle time from 280s to 33s and
  its checkpoint from 92.78s to 7.9s.
* **The declared tool surface actually present.** The first PM6 run failed
  with `pwsh: command not found` -- the golden had Windows PowerShell 5.1
  only. `guest-recipes/lib/provision-pwsh.ps1` pins 7.4.6, matching the
  persistent Windows runner, so both halves of the fleet stay on one
  version.

### Two members, concurrent jobs, 2026-08-21

The pool serves in parallel, which is what makes it a scale set rather than
a runner:

```
run 32507593960  nonce par-a  ->  runner hv-pool001  on  REPRO-POOL-001
run 32507601122  nonce par-b  ->  runner hv-pool000  on  REPRO-POOL-000
```

Both succeeded, on distinct guests with distinct identities
(172.27.90.110 and 172.27.93.235). And member 000 served its second job
AFTER a recycle -- the state looking clean is not the same as the member
still working, so the repeat is the property worth proving.

### The daemon, and a false-green it used to hide

`hyperv-scale-set.ps1` with no `-Member` is the multi-member form: it starts
one worker PROCESS per member and supervises them. Proven 2026-08-21 after a
host reboot -- two workers, two jobs dispatched 7s apart, served
concurrently by REPRO-POOL-000 and REPRO-POOL-001, both green, both
recycled, `all workers exited`.

That run exposed a defect worth recording, because it is the failure mode
this design is most exposed to. Member 001's runner served its job
successfully but then exited with `Failed to create a session. The runner
registration has been deleted from the server`, rather than the clean
`Removed .runner` / `exit with 0 return code` that 000 printed. The job was
fine; the runner's exit was not.

The serve loop treated **any** exit of `run.cmd` as "job finished". A
listener that comes up, fails to create a session and leaves looks exactly
the same from outside -- so the loop would have recycled, re-registered, and
spun through registration tokens indefinitely while logging finished jobs
and serving nothing. The loop now requires the runner's own
`completed with result: <x>` line as proof a job ran, and treats its absence
as a failed cycle. A job that ran and FAILED is still a success for this
purpose: that is somebody's workflow failing, not a sick member, and it must
not count toward parking.

Verified by reproducing 001's exact transcript through the real script: the
guard raised, the recovery restore ran (erasing the stub, which is how the
restore proved itself real), and a second consecutive failure parked the
member with the console-capture and rebaseline commands printed. Then a live
job confirmed the success path still reports
`job completed with result: Succeeded (runner exit 0)`.

Construction from the HARDENED golden is roughly an order of magnitude
faster than from the unhardened one, because members no longer spend their
first boot applying staged Windows updates:

| step | unhardened | hardened |
| ---- | ---------- | -------- |
| import | 350-490 s | **24.4 s** |
| first boot to reachable | 293 s | **32.9 s** |
| settle | 280 s | **32.3 s** |
| baseline checkpoint | 92.8 s | **4.5 s** |

Capacity changes went from ~10 minutes per member to well under two.
