---
title: Driving a VM from code
section: guides
order: 1
slug: driving-a-vm
---
# Driving a VM from test / harness code

There are two ways to consume vm-harness: shell out to the `vm-harness` CLI (see
the [CLI reference](/reference/cli-reference)), or import the Nim library and call the
`VmBackend` primitives directly. This guide covers the library path, which is
what test suites and custom harnesses use.

Import the umbrella module — it re-exports the public types, the backend
constructors, the orchestrator, and the output envelope:

```nim
import vm_harness
```

## The golden rule: whoever reverts must clean up

Every `revertToBaseline` (and every `bootFromMedia`) returns a `VmHandle` that
must be passed to `stopAndCleanup`. `stopAndCleanup` is designed to run from
a `finally`/`defer` block: it never raises and is safe to call more than once.
Skipping it leaks VMs, clones, and disk.

```nim
let vm = backend.revertToBaseline("base-clean")
defer: backend.stopAndCleanup(vm)     # runs even if the body raises
# ... use vm ...
```

## Option A: `runGate` — the one-call orchestrator

For the common "reset, run one command, harvest, clean up" gate, use `runGate`.
It wraps the whole `revert → copy-in → shim → exec → copy-out → cleanup`
sequence in a `try/finally` with SIGINT handling, and finalizes the output
envelope with the correct verdict no matter which step failed.

```nim
import vm_harness, std/tables

let backend = newLibvirtBackend()                 # pick your backend
let envelope = newOutputEnvelope("./out")         # standardized layout in ./out
let gate = GateSpec(
  name: "smoke",
  baseline: "base-clean",
  env: {"CI": "1"}.toTable,
  cmd: @["/bin/sh", "-c", "echo hi; uname -s"],
  copyTo: @[(host: "./payload.txt", guest: "/tmp/payload.txt")],
  copyFrom: @[(guest: "/var/log/build.log", host: "./out/build.log")],
  shims: @[],
  timeoutSec: 600)

let result = runGate(backend, gate, envelope)
# result.verdict is vPass / vFail / vError / vIncomplete
# result.exec holds the ExecResult; result.elapsedMs is the wall-clock
```

Verdict mapping: `vPass` (in-guest exit 0), `vFail` (non-zero exit), `vError`
(harness-internal exception), `vIncomplete` (Ctrl-C). The CLI's `run`
subcommand is a thin wrapper over exactly this.

## Option B: compose the primitives yourself

When you run several gates back-to-back inside one session — provision once,
then revert-exec-cleanup per gate — drive the primitives directly. The contract
is the same: pair each revert with a cleanup.

```nim
import vm_harness, std/[options, tables]

let b = newLimaBackend(cpus = 2, memoryGiB = 2, diskGiB = 10)

# 1. One-time, idempotent, slow. Safe to call every session start.
b.provisionBaseline(BaselineSpec(
  name: "base", guestOs: goLinux, guestArch: gaArm64,
  cpus: 2, memoryMB: 2048, diskGB: 10))

for testCase in cases:
  # 2. Fast per-gate reset → started VM ready for exec.
  let vm = b.revertToBaseline("base")
  try:
    doAssert vm.ipAddress.isSome

    # 3. Push inputs in.
    b.copyToGuest(vm, testCase.inputPath, "/tmp/input")

    # 4. (optional) wrap a guest binary so its argv is recorded.
    b.installArgvTraceShim(vm, ArgvTraceShim(
      wrappedBinaryName: "useradd",
      traceLogPath: "/tmp/useradd.log"))

    # 5. Exec with env carried through; capture output.
    let r = b.execInGuest(vm,
      env = {"KEY": "value"}.toTable,
      cmd = @["/bin/sh", "-c", "run-the-thing"],
      timeoutSec = 120)
    doAssert r.exitCode == 0

    # 6. Harvest artifacts out.
    b.copyFromGuest(vm, "/tmp/result", testCase.outputPath)
  finally:
    # 7. ALWAYS. Never raises; safe to double-call.
    b.stopAndCleanup(vm)
```

This is the lifecycle from the
[design reference](https://github.com/metacraft-labs/vm-harness/blob/main/docs/design.md)
§3.3: `provisionBaseline` once, then `revertToBaseline` / exec / `stopAndCleanup`
per gate.

## Constructing a backend

Each backend has a `new<Name>Backend(...)` constructor with keyword arguments
that default to the values a normal host uses. Override them to point at custom
tool paths, credentials, images, or timeouts. Highlights (see each backend
source under `src/vm_harness/backends/` for the complete signature):

```nim
newLimaBackend(cpus = 2, memoryGiB = 2, diskGiB = 10, bootTimeoutSec = 240)

newLibvirtBackend(
  libvirtUri = "qemu:///system",        # DefaultLibvirtUri
  imagePoolDir = "/var/lib/libvirt/images",
  networkBridge = "virbr0",             # DefaultLibvirtBridge
  sshUser = "admin", sshPassword = "repro-windows-x64")   # Windows-guest defaults

newTartBackend(guestOs = goLinux, goldenImage = "",
               sshUser = "admin", sshPassword = "admin")   # cirruslabs image defaults

newIncusBackend(incusCmd = @["incus"],  # or @["sudo","-n","incus"]
                baseImage = "vmh-base", storagePool = "default")

newHyperVBackend(vmName = "...")        # PowerShell Direct over VMBus
newWslBackend(distroPrefix = "...", rootfsTarballPath = "...")
newUtmBackend(utmctlCmd = "utmctl", ...)
```

For auto-selection without hard-coding a constructor, use the registry:

```nim
let id = autoSelectBackendId(detectHostPlatform(), goLinux)
let backend = newBackend(id)            # or newBackendForGuest(goLinux)
```

## The ephemeral (per-job) path

The Incus and libvirt backends additionally support a create → probe →
destroy ephemeral lifecycle with no residual VM/container or storage. This is
what a GitHub-runner provider drives per job. The CLI exposes it via `run
--ephemeral`; in code the Incus backend uses `provisionEphemeralClone` +
`startAndAwaitReady` + `execInGuest` + `stopAndCleanup(vm, deleteVm = true)`.

The seam that makes it useful for JIT runner registration is cloud-init
`user-data` injection: pass a rendered bootstrap script (via `--user-data` on
the CLI, or `EphemeralIncusSpec.userData` in code) and the backend injects it so
the guest runs it on first boot. On libvirt the same idea is delivered by
building a config-drive ISO from `--user-data` and attaching it so cloudbase-init
consumes it. See the
[ephemeral lifecycle notes](https://github.com/metacraft-labs/vm-harness/blob/main/docs/ephemeral-lifecycle-and-cleanup.md)
and the
[Incus backend notes](https://github.com/metacraft-labs/vm-harness/blob/main/docs/per-backend-notes/incus.md)
for the mechanics, and the [Parameters catalog](/reference/parameters) for the
provider knobs that shape the per-job container.

## Notes on `execInGuest`

- `env` is carried into the guest environment (verified for every backend by
  the integration tests); the output you read is the guest's, not the host's.
- `cmd` is an argv sequence, not a shell string — wrap in `/bin/sh -c "..."`
  (POSIX guests) or the equivalent when you need shell parsing.
- `timeoutSec` defaults to 600. On timeout the backend raises `TimeoutError`
  (part of the `VmHarnessError` hierarchy).

## Boot-time (serial) assertions

To assert against a guest while it boots — before it is exec-ready — use the
boot-media primitives: `bootFromMedia(spec)` returns a `VmHandle`, then
`captureSerial(vm)` gives a `SerialStream` you drive with `expectLine`,
`serialSend`, and `closeSerial`. This is how ReproOS boot tests assert on
systemd's serial output. Backends without direct-boot support raise
`BackendUnavailableError`.

For a real installer lifecycle, set `BootMediaSpec.targetDiskPath` with ISO
media, assert the installer success marker, and call `waitForShutdown` before
cleanup. The target path is caller-owned: backends reject an existing path and
`stopAndCleanup` removes the transient VM without deleting the installed disk.
The CLI packages this sequence as:

```sh
vm-harness install --backend auto --source-image installer.iso \
  --target-disk build/installed.qcow2 --disk-gb 16 \
  --expect 'INSTALL COMPLETE' --timeout-sec 1800
```
