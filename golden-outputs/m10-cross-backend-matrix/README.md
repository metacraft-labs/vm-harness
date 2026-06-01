# M10 Cross-Backend Matrix — Reference Output Artifacts

Per the M10 deliverable "Reference artifacts for M17 (Rust port)", this
directory captures byte-stable output samples from every Mac-host-runnable
cell of the reprobuild cross-backend matrix runner
(`reprobuild/tests/e2e/macos-phase5/run_cross_backend_matrix.nim`).

The Rust `ah-vm` port (M17) consumes these artifacts as the
cross-language correctness gate: running the same cell through the Rust
binary must produce a byte-identical `DONE` sentinel and (modulo the
`elapsed_ms: <varies>` placeholders) a `RESULT.txt` whose step ordering
+ verdict line match `RESULT.normalized.txt` here.

## Layout

```
m10-cross-backend-matrix/
├── README.md                                       (this file)
├── tart-linux-arm-passwd-user/
│   ├── DONE                                        ("PASS\n", byte-stable)
│   └── RESULT.normalized.txt                       (elapsed_ms scrubbed)
├── tart-linux-arm-fs-system-file/        ...
├── tart-linux-arm-env-system-variable/   ...
├── tart-linux-arm-systemd-system-unit/   ...
├── lima-passwd-user/                     ...
├── lima-fs-system-file/                  ...
├── lima-env-system-variable/             ...
└── lima-systemd-system-unit/             ...
```

## Cells captured (Mac-host runnable)

| Backend          | Gate                  | Status   |
|------------------|-----------------------|----------|
| tart-linux-arm   | passwd-user           | passing  |
| tart-linux-arm   | fs-system-file        | passing  |
| tart-linux-arm   | env-system-variable   | passing  |
| tart-linux-arm   | systemd-system-unit   | passing  |
| lima             | passwd-user           | passing  |
| lima             | fs-system-file        | passing  |
| lima             | env-system-variable   | passing  |
| lima             | systemd-system-unit   | passing  |

## Cells NOT captured (require non-Mac hosts or pending bundles)

| Backend          | Pending reason                                       |
|------------------|------------------------------------------------------|
| tart-macos       | runnable on Mac host — capture during next refresh   |
| libvirt          | requires Linux host                                  |
| hyperv           | requires Windows host                                |
| wsl              | requires Windows host                                |
| utm-windows-arm  | requires M3 UTM golden bundle                        |

When those hosts come online, run the matrix runner there and copy the
new envelopes into sibling directories under this tree following the
existing per-cell layout.

## Byte-stability contract

* `DONE` — the verdict sentinel — IS byte-stable across runs and across
  language ports. The Rust port MUST emit byte-identical content
  (`PASS\n`, `FAIL\n`, `ERROR\n`, `INCOMPLETE\n`).
* `RESULT.normalized.txt` is `RESULT.txt` with `elapsed_ms: <int>`
  replaced by `elapsed_ms: <varies>`. The Rust port's `RESULT.txt`,
  passed through the same normalization, MUST equal the captured
  file byte-for-byte (same step ordering, same statuses, same final
  `verdict:` line).
* `02-<cmd>-run.txt` (the captured stdout/stderr of the gate binary) is
  NOT captured here because its contents are dominated by the test
  framework's own output (`std/unittest`), which is byte-stable per
  Nim version but irrelevant to vm-harness's correctness gate. The
  Rust port wraps native `repro` binaries — the framework's output
  is the gate's responsibility, not vm-harness's.

## Refresh procedure

```
cd /Users/zahary/metacraft/reprobuild
nim c -r --threads:on tests/e2e/macos-phase5/run_cross_backend_matrix.nim
# then copy DONE + normalized RESULT.txt from the work dir per cell.
```

Captured 2026-06-01 against:
- host: macOS arm64 (M-series), nim 2.2.4, zig 0.16.0
- vm-harness: /Users/zahary/metacraft/vm-harness (build/bin/vm-harness)
- tart-linux-arm golden: ghcr.io/cirruslabs/ubuntu:latest
- lima image: default template:_images/ubuntu-lts
