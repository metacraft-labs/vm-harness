# `tools/bench/` — backend-agnostic benchmarks

Reproducible measurement programs that drive the vm-harness library
API against a real backend and emit JSON timings. Designed to be
re-run on different hardware so consumers can publish their own
reference numbers without re-implementing the harness.

The numbers measured here back the per-backend notes under
`docs/per-backend-notes/`.

## Programs

### `snapshot_revert_bench.nim`

Measures the per-iteration cost of `restoreSnapshot` to a hot
snapshot followed by `startAndAwaitReady` — the inner loop of any
per-gate revert workflow that uses `snapshotRunning` for cheap
isolation.

Build:

```
nimble buildBench
```

Run (Hyper-V example):

```
build/bin/vm-harness-bench-snapshot-revert \
  --backend hyperv \
  --vm repro-m69-hyperv \
  --baseline base-clean \
  --iterations 5 \
  --output bench-result.json
```

Output is a single JSON object with `phase_a_setup_ms`,
`phase_a_snapshot_ms`, `iterations_per_revert_ms` (per-iteration
restoreSnapshot wall-clock), `iterations_per_ready_ms` (per-iteration
startAndAwaitReady wall-clock), `per_iteration_total_ms`, and
`median_per_iteration_ms`.

A reference run on the hardware documented in
`docs/per-backend-notes/hyperv-snapshot-benchmarks.md` produces
median per-iteration totals around 5.4 s.

### Future programs

- `portable_baseline_bench.nim` — round-trips `exportBaseline` /
  `importBaseline` and times the import + resume cycle on the
  receiving host. See `docs/per-backend-notes/hyperv-snapshot-benchmarks.md`
  for the cold-boot artifact-caching model the bench measures.

### `clone_per_task_bench.nim`

The counterpart to `snapshot_revert_bench.nim`. That one measures the inner
loop of `recycle-from-pool-per-task`; this measures the inner loop of
`clone-per-task` (`revertToBaseline` -> `startAndAwaitReady` ->
`stopAndCleanup(deleteVm = true)`). Emits the same JSON shape and the same
median so the two are directly comparable.

Running both against a backend is what decides which algorithm that backend
should use. The rule, and the recorded per-backend selections, are in
[`docs/pool-algorithms.md`](../../docs/pool-algorithms.md).

```
nim c -r tools/bench/clone_per_task_bench.nim \
  --backend libvirt --baseline golden-win11 --iterations 5
```

Two flags worth knowing:

- `--assert-creates-instance` fails the run unless each iteration produced a
  DISTINCT instance. `revertToBaseline` means "produce a task-ready guest",
  which some backends satisfy by creating one (libvirt, incus) and others by
  resetting a long-lived one (Hyper-V). Only the former is clone-per-task,
  and without this flag the difference is invisible in the output.
- `--provision-baseline` provisions before measuring, so the program can be
  smoke-tested against `--backend noop` with no hypervisor. Real backends
  already have their baseline and should not pass it.
