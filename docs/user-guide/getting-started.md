# Getting started

This walks you from a clean checkout to a booted VM and a first in-guest
assertion. You need a host that has a backend available (see
[Backends](./backends.md)); the examples below use Lima or Incus because they
have the lightest setup, but the CLI shape is identical for every backend.

## 1. Enter the dev shell

vm-harness builds and runs inside a Nix dev shell that provides Nim, `just`, and
the host's backend tooling (libvirt/QEMU/Lima on Linux; Lima/QEMU on macOS —
Tart and UTM are installed out-of-band, see [Backends](./backends.md)).

```sh
cd vm-harness
nix develop          # or: direnv allow   (an .envrc is checked in)
```

Inside the shell you will see the Nim and Nimble versions printed, and
`VM_HARNESS_ROOT` is exported to the repo root.

## 2. Build the CLI

```sh
just build
```

This compiles `src/vm_harness/cli.nim` to `build/bin/vm-harness` (plus the
snapshot-revert benchmark). Put that on your `PATH` or call it by path:

```sh
export PATH="$PWD/build/bin:$PATH"
vm-harness --help
```

The Nix package path (`nix build .#default`, or the flake output `default`)
installs the same binary to `$out/bin/vm-harness` and ships the guest scripts
and recipes under `$out/share/vm-harness/`.

## 3. See what backends this host can drive

```sh
vm-harness backends      # tabular listing of every known backend; * = registered here
vm-harness probe         # JSON: which backends are actually available + supported guests
```

`backends` lists every backend the toolkit knows about and marks the ones
compiled in on this host. `probe` goes further and actually checks whether each
backend's underlying tool is installed and usable — this is what `--backend
auto` uses to dispatch.

## 4. Bring a VM up and run your first assertion

The one-shot `run` subcommand does the whole per-gate lifecycle for you:
idempotent provision → fast revert to baseline → exec your command in the guest
→ harvest output → guaranteed cleanup (even on failure or Ctrl-C).

```sh
# Lima on macOS/Linux, Linux guest:
vm-harness run \
  --backend lima --guest linux \
  --baseline demo-linux \
  --output-dir ./out \
  -- /bin/sh -c 'echo hello-from-guest; uname -s'
```

Everything after `--` is the command executed *inside the guest*. The process
exit code encodes the verdict: `0` PASS (the in-guest command exited 0), `1`
FAIL (non-zero), `2` ERROR (harness-internal), `130` INCOMPLETE (interrupted).

The `--output-dir` receives the standardized **output envelope**:

```
out/
├── 00-provision.log     session-start log (backend, baseline, per-step timings)
├── 02-<cmd>-run.txt     stdout/stderr of each execInGuest call
├── RESULT.txt           per-step status + final verdict
└── DONE                 sentinel written last (present ⇒ the run completed)
```

The `DONE` sentinel lets downstream parsers tell a completed run from an
interrupted one — a fresh envelope removes any stale `DONE` before starting.

### Ephemeral one-shot (containers / per-job VMs)

The Incus and libvirt backends also expose a fully ephemeral path — launch a
fresh clone from a base/golden image, probe it, and destroy it leaving no
residue:

```sh
# Incus system container, launched fresh, probed, then deleted:
vm-harness run --ephemeral --backend incus \
  --baseline demo-job --base-image vmh-base \
  -- true
```

See [Driving a VM from code](./driving-a-vm.md) for the ephemeral lifecycle and
the JIT cloud-init injection seam, and the [CLI reference](./cli-reference.md)
for every flag.

## 5. (Optional) drive it from your own code

If you are writing a harness rather than shelling out to the CLI, import the
library and call the primitives directly:

```nim
import vm_harness

let b = newLimaBackend(cpus = 2, memoryGiB = 2, diskGiB = 10)
b.provisionBaseline(BaselineSpec(name: "demo", guestOs: goLinux))
let vm = b.revertToBaseline("demo")
defer: b.stopAndCleanup(vm)          # ALWAYS pair revert with cleanup
let r = b.execInGuest(vm, initTable[string, string](),
                      @["/bin/sh", "-c", "uname -s"])
assert r.exitCode == 0 and "Linux" in r.stdout
```

Continue in [Driving a VM from test / harness code](./driving-a-vm.md).

## Running the test suite

```sh
just test         # deterministic Nix CI catalog (no live hypervisor needed)
just test-host    # opt-in gates that require a real host hypervisor
just lint         # nim check + nix formatting check
```
