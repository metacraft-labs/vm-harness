# CLI reference

The `vm-harness` binary is built by `just build` to `build/bin/vm-harness` and
installed by the Nix package to `$out/bin/vm-harness`. Run `vm-harness --help`
for the built-in usage text. This page documents every subcommand and flag as
verified against `src/vm_harness/cli.nim`.

```
vm-harness <subcommand> [flags] [-- <command args>]
```

Process exit codes double as the verdict for `run`: `0` PASS, `1` FAIL, `2`
ERROR / usage error, `130` INCOMPLETE (interrupted).

## Subcommands

| Subcommand | Purpose |
| --- | --- |
| `provision` | Ensure a baseline image exists (idempotent). |
| `run` | One-shot revert + exec + harvest + cleanup (the gate runner). |
| `run --ephemeral` | libvirt/incus: launch one per-job clone, probe, destroy (no residue). |
| `ephemeral-destroy` | libvirt: reclaim a clone left running by `run --ephemeral --keep`. |
| `probe` | Print available backends as JSON (capability detection). |
| `backends` | Tabular listing of every known backend (`*` = registered here). |
| `shell` | (Placeholder in M0) open an interactive shell into a baseline. |
| `snapshot create\|restore\|list` | Snapshot lifecycle for the resolved backend. |
| `baseline export\|import` | Export/import a baseline (and its snapshot tree). |
| `prune` | Reclaim ephemeral instances leaked by hard-killed launchers. |

### `provision`

```
vm-harness provision --backend <id|auto> --guest <linux|windows|macos> \
                     --baseline <name> [--source-image <ref>] \
                     [--cpus N] [--memory-mb N] [--disk-gb N] [--recipe <id>]
```

Builds the baseline if absent; no-op if present. `--baseline` is required.

### `run`

```
vm-harness run --backend <id|auto> --guest <linux|windows|macos> \
               --baseline <name> --output-dir <path> \
               [--env KEY=VAL ...] [--copy-to host:guest ...] \
               [--copy-from guest:host ...] \
               [--install-shim binary:logpath ...] \
               [--timeout-sec N] [--log-format human|json] \
               -- <command args>
```

Provisions (idempotent), reverts to baseline, execs everything after `--` in the
guest, writes the [output envelope](./getting-started.md#4-bring-a-vm-up-and-run-your-first-assertion)
to `--output-dir`, and always cleans up. `--baseline`, `--output-dir`, and a
command after `--` are required.

### `run --ephemeral`

libvirt (CoW-clone VM) or incus (fresh container). Launch a fresh clone, probe
it, destroy it leaving no residue.

- **incus:** `run --ephemeral --backend incus --baseline <container> [--base-image <alias>] [--user-data <file>] -- <probe cmd>`. Default base image `vmh-base`; `--user-data` injects cloud-init (the JIT seam); the probe defaults to `true`.
- **libvirt:** `run --ephemeral --baseline <vm> --golden-image <qcow2> [--user-data <file>] [--kernel/-initrd/-kernel-cmdline ...] [--uefi-loader/-uefi-nvram-template ...] -- [expected-serial-marker]`. A positional arg after `--` is an expected serial boot-marker substring.
- **`--keep`:** clone + boot (UEFI) and **leave the domain running** (no probe/teardown); reclaim it later with `ephemeral-destroy`. Used to drive an out-of-band in-guest probe (e.g. the Windows JIT bootstrap over SSH).

### `ephemeral-destroy`

```
vm-harness ephemeral-destroy --baseline <vm>
```

libvirt-only. Reclaims a clone left running by `run --ephemeral --keep`:
`virsh destroy` + `virsh undefine --nvram` + remove the overlay, config-drive
ISO, and per-job OVMF nvram. The golden and OVMF template are never touched.

### `probe` / `backends`

`probe` prints a JSON array of `{id, available, host, supported_guests}` — it
constructs each backend and calls `probeAvailability`. `backends` prints a table
of every backend the toolkit knows about, marking the ones registered on this
host with `*`.

### `snapshot`

```
vm-harness snapshot create [--running] <vm> <name>
vm-harness snapshot restore <vm> <name>
vm-harness snapshot list <vm>
```

`--running` captures RAM + CPU + device state so restore resumes from memory
instead of a fresh boot (Hyper-V Standard Checkpoint; Tart `tart suspend`
planned). Backends without snapshot support raise `BackendUnavailableError`.

### `baseline`

```
vm-harness baseline export <vm> <dest-dir> [--baseline <name>]
vm-harness baseline import <src-dir>
```

Export a baseline (and its snapshot tree, on Hyper-V/libvirt) as a
self-contained artifact for CI baseline-caching; `--baseline` asserts the named
snapshot exists before exporting. `import` prints the names now available.
Bundle layouts are backend-specific and not cross-backend portable.

### `prune`

```
vm-harness prune --ephemeral-prefix <p> [--backend all|tart|qemu-windows-arm] \
                 [--state-dir <dir>] [--older-than <sec>] [--sweep-tmp] [--dry-run]
```

Reclaims ephemeral instances/clones leaked by hard-killed launchers, scoped to
`--ephemeral-prefix` (required). Never removes a running instance (advisory lock
held, or creator PID alive). `--older-than` guards the PID-fallback path
(default 3600s; 0 disables). `--sweep-tmp` also age-removes transient `/tmp`
scratch (SSH password files, mount-share scripts). `--dry-run` reports only.

## Flag reference

### Backend / target selection

| Flag | Meaning |
| --- | --- |
| `--backend <id\|auto>` | One of `auto`, `noop`, `hyperv`, `wsl`, `tart-macos`, `tart-linux-arm`, `utm-windows-arm`, `qemu-windows-arm`, `libvirt`, `lima`, `incus`. |
| `--guest <linux\|windows\|macos>` | Required when `--backend auto`. |
| `--allow-noop-fallback` | Use `NoopBackend` if the real backend isn't installed (selection tests on hypervisor-less hosts). |
| `--baseline <name>` | Logical baseline tag (== libvirt domain name). |
| `--name <vm>` | Alias for `--baseline` (canonical libvirt-M4 command shape); if both are given they must match. |

### Baseline sizing

| Flag | Default | Meaning |
| --- | --- | --- |
| `--cpus <int>` / `--vcpu <int>` | 2 | vCPU count (`--vcpu` is the libvirt spelling). |
| `--memory-mb <int>` | 4096 | Guest RAM in MiB. |
| `--memory-gb <int>` | — | Alias for `--memory-mb`, in GiB (converted at parse time). |
| `--disk-gb <int>` | 50 | Guest disk in GiB. |
| `--source-image <ref>` | — | Backend-specific base image reference. |

### Recipe / Windows provisioning

| Flag | Meaning |
| --- | --- |
| `--recipe <id>` | Select `guest-recipes/<id>/` as the source of per-baseline artifacts. |
| `--recipe-build-dir <path>` | Writable location for the recipe's `build/` outputs (needed when the recipe is read-only under `/nix/store`). |
| `--first-boot-script <path>` | libvirt: host script the recipe wraps into the per-VM autounattend ISO. Requires `--recipe`; file must exist. |
| `--controller-pubkey <path>` | libvirt: SSH pubkey baked into the autounattend ISO so the guest installs it in `authorized_keys` before first boot. Requires `--recipe`. |
| `--network-bridge <name>` | libvirt: host bridge for the guest NIC (default `virbr0`). Ignored by other backends. |

### Ephemeral (per-job) clone

| Flag | Meaning |
| --- | --- |
| `--ephemeral` | Run one per-job CoW-clone VM / fresh container, then destroy it. |
| `--keep` | libvirt: with `--ephemeral`, leave the domain running for an out-of-band probe; reclaim with `ephemeral-destroy`. |
| `--golden-image <path>` | libvirt: golden qcow2 the overlay is cloned from. Requires `--ephemeral`. |
| `--base-image <alias>` | incus: base image alias the container launches from (default `vmh-base`). |
| `--kernel` / `--initrd` / `--kernel-cmdline` | libvirt: optional direct-kernel-boot for the tiny-Linux golden. |
| `--user-data <path>` | Cloud-init user-data injected into the ephemeral clone (config-drive on libvirt; `cloud-init.user-data` on incus). The JIT bootstrap seam. |
| `--meta-data <path>` | libvirt: optional config-drive `meta_data.json` override. |
| `--uefi-loader <path>` / `--uefi-nvram-template <path>` | libvirt: OVMF code fd + vars template for UEFI (Windows) ephemeral boot. |

### Gate execution

| Flag | Meaning |
| --- | --- |
| `--output-dir <path>` | Where the output envelope is written. Required for `run`. |
| `--env KEY=VAL` | Env var carried into the guest (repeatable). |
| `--copy-to host:guest` | Copy a host file into the guest before exec (repeatable). |
| `--copy-from guest:host` | Copy a guest file out after exec (repeatable). |
| `--install-shim binary:logpath` | Install an argv-trace shim around a guest binary (repeatable). |
| `--timeout-sec <int>` | Per-exec timeout (default 600). |
| `--log-format <human\|json>` | Structured log output on stderr. |
| `--` | End of flags; everything after is the in-guest command. |

### `prune` flags

| Flag | Meaning |
| --- | --- |
| `--ephemeral-prefix <p>` | Project scope (required). |
| `--state-dir <dir>` | qemu-windows-arm state directory scope. |
| `--older-than <sec>` | PID-fallback age guard (default 3600; 0 disables). |
| `--sweep-tmp` | Also age-sweep transient `/tmp` scratch. |
| `--dry-run` | Report what would be reclaimed. |

## Environment variables

Beyond flags, several backends and recipes read `VMH_*` environment variables
(tool paths, credentials, timeouts, golden/ISO locations) and the recipes take
`VMH_RUNNER_*` build seams. These are catalogued in the
[Parameters catalog](./parameters.md). The most commonly used from the CLI:

- `VMH_INCUS_CMD` — override the incus invocation, e.g. `"sudo -n incus"`.
- `VMH_RECIPES_DIR` — override where `--recipe <id>` is resolved from.
- `VMH_TART_CMD` — override the `tart` binary path (also honored by `prune`).
