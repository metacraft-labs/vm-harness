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
