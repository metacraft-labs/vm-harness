# VM-Harness Design

**Status**: Design draft — implementation-ready for sub-agent execution.
**Created**: 2026-06-01.
**Audience**: implementation agents executing the [Multi-OS VM Automation Campaign](Multi-OS-VM-Automation-Campaign.milestones.org). This document is the canonical design spec; the milestones file tracks per-deliverable progress.

## 1. Overview

**vm-harness** is a focused library + CLI for cross-platform VM lifecycle orchestration in test harnesses and dev workflows. It provides one abstraction over multiple backend hypervisors (Hyper-V, WSL, libvirt/QEMU, Tart, UTM) so test code can drive any of them through the same primitives.

**In scope**: provision a baseline guest image, fast per-gate reset between test invocations, exec command in guest with captured output, copy files in/out, install argv-tracing shims around guest-side tools, write a standardized output envelope. Single-machine, single-process orchestration.

**Out of scope**: image-build pipelines (use Packer for those), agent execution semantics (vm-harness doesn't know what a "task" is — consumers compose), cloud-fleet management (use Terraform or AH's own fleet orchestrator), microVM-grade sub-second cold-starts (use microsandbox if that's the requirement).

The library lives in a standalone repository, `metacraft-labs/vm-harness`, deliberately *not* bundled inside `nixos-modules` — consumers should be able to add it as a focused dependency without pulling in unrelated infrastructure.

## 2. Why this exists (prior-art summary)

A separate web research survey ([report findings 2026-06-01]) confirmed the niche is unfilled. The closest matches each fail structurally:

| Project | Why it doesn't replace vm-harness |
|---|---|
| **libvirt** | Closest abstraction depth; many bindings exist (libvirt-go, libvirt-python, `virt` Rust crate). But its backend set is KVM/QEMU/Xen/ESX/Bhyve plus a *read-mostly* Hyper-V driver. No Tart, no UTM, no WSL — those frameworks aren't libvirt-shaped. |
| **HashiCorp Vagrant** | Right backend topology (built-in Hyper-V, plugins for libvirt/UTM, pending Tart). But Ruby user-tool; the Go rewrite has been alpha since 2022; the Tart provider request ([vagrant#12760](https://github.com/hashicorp/vagrant/issues/12760)) has been open four years with no shipped plugin. Not viable as a library foundation. |
| **KubeVirt v1.8 HAL** (Mar 2026) | Newest serious multi-hypervisor abstraction. But K8s-bound; server hypervisors only. |
| **microsandbox** (Rust, 2025) | Closest *delivery shape* — multi-language SDKs over multiple backends. But optimized for ephemeral OCI microVMs (<200 ms cold start), not golden-image VM testing. Bypasses Tart/UTM/Hyper-V rather than wrapping them. |
| **Cua/Lume**, **Tart**, **Anka**, **Orchard** | Single-backend silos. Tart itself is a CLI, not a library with a stable API. |
| **Packer** | Image-build only — no start/exec/snapshot lifecycle. But its `packer-plugin-tart` and `packer-plugin-utm` are reference implementations for driving those backends programmatically. |

**Design references worth borrowing from**:

- *libvirt domain API* — the battle-tested lifecycle contract; informs which primitives the trait needs (start/stop/snapshot/revert/clone).
- *Cuckoo Sandbox "Machinery" interface* — clean abstract-base-class shape for multi-backend VM management (used for malware analysis). Worth reading their abstraction layer for API design.
- *KubeVirt v1.8 HAL plugin model* — recent thinking on multi-hypervisor abstraction; clean separation of generic lifecycle from per-backend transport.
- *microsandbox API* — the cross-platform Rust+SDK delivery model that informs how vm-harness ships (Nim library + CLI + nearly-identical Rust port).
- *cirruslabs/packer-plugin-tart* and *cirruslabs/packer-plugin-utm* — Go reference implementations for driving Tart and UTM. We won't depend on them but can study the patterns.
- *vagrant_utm* (Ruby+AppleScript) — proves UTM CLI automation is feasible; reference for `utmctl` invocation patterns.

## 3. Architecture

### 3.1 Three-tier ownership model

vm-harness provides *generic primitives only*. Consumer-specific orchestration lives in the consumer's own repo.

- **Tier 1 — vm-harness (this library)**: VM lifecycle (provision, revert, start, stop), generic in-guest scripts (`exec a command`, `install argv tracer for any binary`, `write output to standardized layout`), output envelope.
- **Tier 2 — reprobuild's test suite**: gate-binary build steps, REPRO_M69_*_VM env-var dispatch, reprobuild-specific argv-trace shim installations (`useradd`, `launchctl`, `dscl`, etc.), result parsing for reprobuild's `RESULT.txt` schema.
- **Tier 3 — Agent Harbor**: AH binary install, mutagen source sync, cargo test orchestration with isolation flags, JUnit XML extraction.

vm-harness never imports or references Tiers 2 or 3. Consumers compose Tier-1 primitives.

### 3.2 The VmBackend abstraction

Nim concept (concrete OOP-style for clarity):

```nim
type
  VmBackend* = ref object of RootObj
    id*: string                   # "hyperv" | "wsl" | "tart" | "utm" | "libvirt"
    hostPlatform*: HostPlatform   # what host OS this backend runs on
    supportedGuests*: set[GuestOs]

  HostPlatform* = enum hpWindows, hpLinux, hpMacosArm
  GuestOs* = enum goWindows, goLinux, goMacos
  GuestArch* = enum gaX86_64, gaArm64

  BaselineSpec* = object
    name*: string                 # e.g. "base-clean", "base-with-vs"
    sourceImage*: string          # backend-specific reference
    cpus*: int
    memoryMB*: int
    diskGB*: int

  VmHandle* = ref object
    backend*: VmBackend
    name*: string
    ipAddress*: Option[string]
    sshPort*: int
    sshUser*: string
    sshAuth*: SshAuth

  SshAuth* = object
    case kind*: SshAuthKind
    of saPassword: password*: string
    of saKeyFile: keyPath*: string

  ExecResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string
    elapsedMs*: int

  ArgvTraceShim* = object
    wrappedBinaryName*: string    # e.g. "useradd"
    traceLogPath*: string         # in-guest path where argv lines accumulate

# Methods every backend must implement
method probeAvailability*(b: VmBackend): bool {.base.}
  ## Quick capability check: is the underlying tool installed and usable?
  ## Used by `vm-harness --backend auto` for dispatch.

method provisionBaseline*(b: VmBackend, spec: BaselineSpec) {.base.}
  ## Idempotent. Builds the baseline image if absent, else no-op.
  ## Wall-clock budget: minutes to hours (one-time per baseline).

method revertToBaseline*(b: VmBackend, baselineName: string): VmHandle {.base.}
  ## Fast per-gate reset. Returns a started VM ready for exec.
  ## Per-backend wall-clock budget — see §3.4 Performance Contract.

method execInGuest*(b: VmBackend, vm: VmHandle,
                   env: Table[string, string],
                   cmd: seq[string],
                   stdin: string = "",
                   timeoutSec: int = 600): ExecResult {.base.}

method copyToGuest*(b: VmBackend, vm: VmHandle,
                   hostPath: string, guestPath: string) {.base.}

method copyFromGuest*(b: VmBackend, vm: VmHandle,
                     guestPath: string, hostPath: string) {.base.}

method installArgvTraceShim*(b: VmBackend, vm: VmHandle,
                            shim: ArgvTraceShim) {.base.}
  ## Replaces the named binary with a wrapper that logs argv to traceLogPath
  ## then exec's the real binary. Backend-specific implementation but the
  ## contract is the same regardless of guest OS.

method stopAndCleanup*(b: VmBackend, vm: VmHandle, deleteVm: bool = true) {.base.}
  ## Must be safe to call from a `finally` block. Never raises.
```

### 3.3 Lifecycle phases

```
┌─── Session ─────────────────────────────────────────────────────────────┐
│ 1. provisionBaseline("base-clean")  ← one-time, idempotent, slow (mins) │
│                                                                         │
│ ┌─── Per gate (called 10-15× per session) ───────────────────────────┐  │
│ │ 2. vm = revertToBaseline("base-clean")  ← FAST per §3.4            │  │
│ │ 3. copyToGuest(vm, …)                                              │  │
│ │ 4. installArgvTraceShim(vm, …)   (consumer requests, e.g. Tier-2)  │  │
│ │ 5. execInGuest(vm, env, cmd)     (consumer's actual test command)  │  │
│ │ 6. copyFromGuest(vm, …)          (artifact harvest)                │  │
│ │ 7. stopAndCleanup(vm, deleteVm=true)   in `finally`                │  │
│ └────────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│ 8. Session-end cleanup: ensure no stale ephemerals remain               │
└─────────────────────────────────────────────────────────────────────────┘
```

The `revertToBaseline` semantics are deliberately uniform across backends with different underlying mechanisms:

- Hyper-V: `Restore-VMCheckpoint` (native snapshot)
- libvirt: `virsh snapshot-revert` (native snapshot)
- UTM: `utmctl clone <base-clean.utm> <ephemeral>` (no native snapshots; clone is substitute)
- Tart: `tart delete <ephemeral> && tart clone <golden> <ephemeral>` (no native snapshots; clone-from-OCI-cache is substitute)
- WSL: `wsl --unregister <ephemeral> && wsl --import <ephemeral> <dir> <rootfs.tar.gz>` (no snapshots; throwaway-distro is substitute)

The consumer doesn't care which mechanism the backend uses; it only cares that revert is fast enough to be acceptable between every gate.

### 3.4 Per-Gate Reset Performance Contract

| Backend | Per-gate revert wall-clock target | Mechanism |
|---|---|---|
| Hyper-V | ≤ 10s | `Restore-VMCheckpoint` |
| libvirt/QEMU | ≤ 10s | `virsh snapshot-revert --running` |
| UTM | ≤ 20s | `utmctl clone` from local `base-clean.utm` |
| Tart | ≤ 30s | `tart clone` from local OCI cache (CoW APFS) |
| WSL | ≤ 20s | `wsl --import` from cached rootfs tarball |

Budgets are *targets*, not hard SLAs. Backends that miss budget by >50% must either:

1. Reduce overhead (e.g., keep base-clean VM pre-warmed instead of cold-cloning each time).
2. Implement *gate-grouping* — a consumer-side optimization where pure-logic gates (no host mutations) run back-to-back in one clone, and only destructive gates trigger a fresh revert.

The performance contract is verified by a regression test (`e2e_vm_harness_per_gate_revert_meets_m0_budget`) that records median wall-clock per backend and flags violations.

### 3.5 Output envelope

vm-harness defines the *directory layout and a few mandatory envelope files*; consumers fill in their own domain-specific artifacts.

```
<output-dir>/
├── 00-provision.log    ← vm-harness's session-start log (mandatory)
├── 02-<cmd>-run.txt    ← stdout/stderr/exit of each execInGuest call (mandatory)
├── RESULT.txt          ← vm-harness's per-step status + verdict (mandatory)
├── DONE                ← sentinel written last (mandatory)
│
├── 01-<gate>-build.log ← reprobuild's gate-build output (consumer-written)
├── 03-passwd-cmd-trace.log ← reprobuild's argv-trace harvest (consumer-written)
└── …                   ← arbitrary consumer files
```

The `DONE` sentinel pattern is borrowed from the existing PowerShell harnesses and ensures downstream parsers can distinguish complete from interrupted runs.

### 3.6 Error model

```nim
type
  VmHarnessError* = object of CatchableError
    backend*: string
    phase*: LifecyclePhase  # provisioning, revert, exec, copy, cleanup
    cause*: ref Exception   # the underlying error if any

  LifecyclePhase* = enum lpProvisioning, lpRevert, lpExec, lpCopy, lpCleanup, lpProbe

  TimeoutError* = object of VmHarnessError
  BackendUnavailableError* = object of VmHarnessError
  GuestBootFailureError* = object of VmHarnessError
  CommandFailedError* = object of VmHarnessError
    exitCode*: int
```

Cleanup *never raises* — `stopAndCleanup` swallows errors and logs them. Everything else can raise; consumers wrap calls in `try/finally` and ensure `stopAndCleanup` runs.

## 4. Per-backend specifications

### 4.1 Hyper-V (HostPlatform: hpWindows; Guests: goWindows, goLinux)

- **Transport**: PowerShell Direct via VMBus (no networking needed in guest). `Invoke-Command -VMName <name> -ScriptBlock { ... }`.
- **File transfer**: `Copy-VMFile -VM <name> -SourcePath ... -DestinationPath ...` (Integration Services file-copy channel).
- **Provisioning**: wraps the existing `reprobuild/tools/hyperv-m69-system/provision-base-vm.ps1` (the Windows-11-dev VHDX + Panther-override autounattend + Nim/gcc install + checkpoint pattern). The script stays in reprobuild; vm-harness's HyperVBackend calls it via `osproc.startProcess`.
- **Revert**: `Restore-VMCheckpoint -VMName <name> -Name <baseline>` + `Start-VM`. Poll `Invoke-Command -VMName <name> { hostname }` for ready signal.
- **Auth**: PowerShell Direct uses SAM credentials cached in DPAPI-sealed `vm-cred.xml` (existing mechanism from `provision-base-vm.ps1`). No SSH needed.
- **Cleanup**: `Stop-VM -TurnOff -Force` (never `Save-VM` — saved-state revert desyncs the snapshot).

### 4.2 WSL (HostPlatform: hpWindows; Guests: goLinux)

- **Transport**: `wsl -d <distro> -- <cmd>` direct exec. No SSH; no networking dance.
- **File transfer**: `/mnt/d/...` 9P bridge from host to guest; `cp` from inside the distro to copy out. (Slower than ext4 inside the distro — see existing WSL harness README.)
- **Provisioning**: download Ubuntu cloud rootfs once (`ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz`, ~325 MB, cached); `wsl --import <name> <install-dir> <rootfs.tar.gz>` to register a throwaway distro.
- **Revert**: `wsl --terminate <name> && wsl --unregister <name> && wsl --import <name> <install-dir> <rootfs.tar.gz>`. No real snapshot — re-import is the substitute.
- **Auth**: runs as root inside the throwaway distro by default.
- **Cleanup**: `wsl --terminate <name> && wsl --unregister <name>` in `finally`. Verify post-cleanup that `wsl --list --quiet` no longer lists the distro.

### 4.3 Tart (HostPlatform: hpMacosArm; Guests: goMacos, goLinux ARM64)

- **Transport**: SSH over Tart's user-mode networking. `tart ip <name>` returns the auto-assigned IP. `sshpass -p admin ssh admin@<ip>` for the cirruslabs golden's default password (alternative: seed an authorized_keys file at clone time for key-only auth).
- **File transfer**: `scp` over SSH for small payloads; `tart --dir <name>=<host-path>:<guest-path>` for larger shared folders.
- **Provisioning**: `tart pull <golden-image-ref>` (cirruslabs golden or our own AH-branded golden). Stored in `~/.tart/cache/OCIs/`.
- **Revert**: `tart stop <ephemeral> && tart delete <ephemeral> && tart clone <golden-image-ref> <ephemeral> && tart run --no-graphics <ephemeral> &` + SSH-ready poll. Tart's clone is CoW APFS — fast but not snapshot-fast.
- **Auth**: cirruslabs golden defaults to admin/admin password SSH. AH-branded goldens (M15-M17) may flip to key-only.
- **Cleanup**: `tart stop <ephemeral> && tart delete <ephemeral>` in `finally`. Stale-ephemeral cleanup at session start: `tart list` and delete any `repro-vm-*` left from prior aborted runs.

### 4.4 UTM (HostPlatform: hpMacosArm; Guests: goWindows ARM64)

- **Transport**: SSH over UTM's user-mode networking. `utmctl ip <name>` to get the IP. Windows OpenSSH on the guest side.
- **File transfer**: `scp` over SSH; or virtio-9p/SMB shared folder via UTM bundle config.
- **Provisioning**: download Windows 11 ARM Insider Preview ISO (URL resolved at runtime); build an autounattend ISO mirroring the Hyper-V Panther-override structure (admin user, OOBE skip flags, OpenSSH server enabled); drive install via `qemu-system-aarch64 -accel hvf` with both ISOs attached; capture as `base-clean.utm` bundle.
- **Revert**: `utmctl stop <ephemeral> && utmctl delete <ephemeral> && utmctl clone <base-clean.utm> <ephemeral> && utmctl start <ephemeral>` + SSH-ready poll. utmctl clone is local-disk (faster than Tart's OCI-cache clone).
- **Auth**: admin/<configured-password> set in autounattend.xml.
- **Cleanup**: `utmctl stop <ephemeral> && utmctl delete <ephemeral>` in `finally`.

### 4.5 libvirt/QEMU (HostPlatform: hpLinux; Guests: goLinux, goWindows)

- **Transport**: SSH over libvirt's default-switch NAT. Guest's IP via `virsh domifaddr`.
- **File transfer**: `scp` over SSH; or virtiofs shared folder via libvirt domain XML.
- **Provisioning**: libvirt domain XML defining the VM; cloud-init seed for Linux guests (NoCloud ISO); autounattend.xml for Windows guests. Existing `nixos-modules/vm-images/ubuntu/` and `nixos-modules/vm-images/windows/` recipes inform the provisioning.
- **Revert**: `virsh snapshot-revert <domain> <baseline> --running` (native qcow2 snapshot).
- **Auth**: cloud-init injects SSH pubkey for Linux; autounattend creates admin user for Windows.
- **Cleanup**: `virsh shutdown <domain>` then `virsh undefine --remove-all-storage <domain>` (only for ephemeral domains; baseline domains preserved).

## 5. In-guest scripts (Tier-1 only)

### 5.1 posix.sh

Used by WSL, Tart-macOS, Tart-Linux. Provides POSIX shell primitives.

Signature (CLI):

```
vm-harness-guest.sh <subcommand> [args]
  exec <output-dir> [--env KEY=VAL ...] -- <cmd...>
    # Runs <cmd>, captures stdout to <output-dir>/02-<basename>-run.txt
    # with stderr interleaved, exit code recorded.
  
  install-trace-shim <real-binary> <log-path>
    # Replaces /usr/local/bin/<real-binary> with a wrapper that appends
    # argv (one per line, format: "ts <tab> argv0 <tab> argv1 ..."), then
    # exec's the original via /usr/bin/<real-binary>.real.
    # Backs up the original to <real-binary>.real if not already done.
  
  uninstall-trace-shim <real-binary>
    # Restores the original binary, removes the .real backup.
  
  write-result <output-dir> <step-name> <status>
    # Appends a row to <output-dir>/RESULT.txt.
  
  finalize <output-dir> <verdict>
    # Writes final verdict to RESULT.txt, then creates the DONE sentinel.
```

Output format:

```
RESULT.txt:
  step: provision  status: ok      elapsed_ms: 12345
  step: exec       status: ok      elapsed_ms: 234
  step: harvest    status: ok      elapsed_ms: 567
  verdict: PASS
```

The shim wrapper template (for `install-trace-shim`):

```bash
#!/bin/sh
printf '%s\t%s\n' "$(date +%s%N)" "$0 $*" >> "@TRACE_LOG_PATH@"
exec "@REAL_BIN_PATH@" "$@"
```

(`@…@` placeholders are replaced at install time.)

### 5.2 windows.ps1

Used by Hyper-V and UTM backends. Same subcommand surface as posix.sh, PowerShell semantics:

```powershell
vm-harness-guest.ps1 -Subcommand exec -OutputDir <dir> -Env @{...} -Cmd <args>
vm-harness-guest.ps1 -Subcommand install-trace-shim -RealBinary <name> -LogPath <path>
…
```

Trace shim template (PowerShell):

```powershell
"$([DateTimeOffset]::Now.ToUnixTimeMilliseconds())`t$($MyInvocation.MyCommand.Path) $($args -join ' ')" |
    Out-File -FilePath "@TRACE_LOG_PATH@" -Append -Encoding utf8
& "@REAL_BIN_PATH@" @args
exit $LASTEXITCODE
```

### 5.3 Shim semantics

- Shim writes happen *before* the real exec, so even if the real binary hangs, the call is recorded.
- Multi-second precision (POSIX uses nanoseconds; Windows uses milliseconds) is sufficient for argv-trace ordering.
- Shims preserve argv0, exit code, stdin, stdout, stderr — they are transparent except for the log line.
- Multiple shims can wrap the same binary if they chain via `.real` / `.real.real` — but the design assumes one shim layer.

## 6. CLI reference

```
vm-harness <subcommand> [flags]

PROVISION:
  vm-harness provision \
    --backend <hyperv|wsl|tart|utm|libvirt|auto> \
    --baseline <name> \
    [--cpus N] [--memory-mb N] [--disk-gb N] \
    [--source-image <ref>]

REVERT-AND-EXEC (one-shot — provisions if needed, reverts, execs, cleans up):
  vm-harness run \
    --backend <name|auto> \
    --baseline <name> \
    --output-dir <path> \
    [--env KEY=VAL ...] \
    [--copy-to host:guest ...] \
    [--copy-from guest:host ...] \
    [--install-shim binary:logpath ...] \
    -- <command args>

PROBE (capability detection):
  vm-harness probe
    # Prints a JSON report of available backends + supported guests.

SHELL (interactive, useful for debugging):
  vm-harness shell \
    --backend <name|auto> \
    --baseline <name>

LIST-BACKENDS:
  vm-harness backends
    # Tabular listing.
```

The `auto` backend selection picks based on `(host OS, requested guest OS)`:

```
(Windows host, Windows guest) → hyperv
(Windows host, Linux guest)   → wsl
(Linux host, Linux guest)     → libvirt
(Linux host, Windows guest)   → libvirt    (QEMU+autounattend)
(macOS host, macOS guest)     → tart
(macOS host, Linux guest)     → tart       (Linux ARM64 via tart)
(macOS host, Windows guest)   → utm
```

## 7. Library API (Nim consumers)

reprobuild's tests import vm-harness as a regular Nim library:

```nim
import vm_harness

let backend = autoSelectBackend(guest = goMacos)
backend.provisionBaseline(BaselineSpec(name: "base-clean", ...))

try:
  let vm = backend.revertToBaseline("base-clean")
  backend.copyToGuest(vm, "build/bin/repro", "/tmp/repro")
  backend.installArgvTraceShim(vm,
    ArgvTraceShim(wrappedBinaryName: "dscl",
                  traceLogPath: "/tmp/dscl-trace.log"))
  let r = backend.execInGuest(vm,
    env = {"REPRO_PHASE5_MACOS_PASSWD_VM": "1"}.toTable,
    cmd = @["/tmp/repro", "test", "passwd-user-mac"])
  backend.copyFromGuest(vm, "/tmp/dscl-trace.log",
                            outputDir / "03-dscl-cmd-trace.log")
  if r.exitCode != 0:
    raise newException(GateFailureError, ...)
finally:
  backend.stopAndCleanup(vm)
```

The dotfiles `vm` CLI invokes vm-harness as a child process:

```sh
vm-harness shell --backend tart --baseline base-clean
# or
vm-harness run --backend tart --baseline base-clean ... -- <cmd>
```

## 8. Rust port (M15: ah-vm-harness)

The Rust port is a *nearly mechanical translation* of the Nim design once it's proven across all five backend cells (M10).

### 8.1 Mapping

| Nim concept | Rust mapping |
|---|---|
| `VmBackend` ref object + base methods | `trait VmBackend { fn ... }` + `Box<dyn VmBackend>` |
| `Option[T]`, `Table[K, V]`, `seq[T]` | `Option<T>`, `HashMap<K, V>`, `Vec<T>` |
| `osproc.startProcess` | `std::process::Command` |
| `try/finally` | `Drop` impl on `VmHandle` for guaranteed cleanup |
| `osproc + reader thread` for streaming stdout | `tokio::process::Command` with stdout/stderr piped |
| Nim's exception hierarchy | `thiserror::Error` derive |

### 8.2 Crate layout

```
agent-harbor/main/crates/ah-vm-harness/
├── Cargo.toml
├── src/
│   ├── lib.rs                   # public API + trait
│   ├── backends/
│   │   ├── mod.rs
│   │   ├── hyperv.rs
│   │   ├── wsl.rs
│   │   ├── tart.rs
│   │   ├── utm.rs
│   │   └── libvirt.rs
│   ├── guest_scripts.rs         # include_str! of vendored posix.sh and windows.ps1
│   ├── output.rs                # output envelope writer
│   └── auto.rs                  # backend auto-selection
├── tests/
│   └── integration/             # one file per backend
└── third-party/vm-harness/      # git submodule: metacraft-labs/vm-harness
    └── guest-scripts/           # the canonical Tier-1 scripts
```

### 8.3 Correctness gate

The Rust port's acceptance test is *byte-identical artifacts*: run both the Nim and Rust ports against the same backend cell with the same gate, then `diff -r` the output directories. Modulo timestamps (which are normalized via a deterministic-time flag for testing), every file must match. This is a hard CI gate.

### 8.4 Consumed by

- `agent-harbor/main/crates/ah-vm/` — extends with low-level backend access via `ah-vm-harness`. (Existing `ah-vm` keeps its higher-level orchestration; `ah-vm-harness` becomes its dispatch layer.)
- `agent-harbor/main/crates/ah-harness-vm/` — Phase C test-isolation harness composes `ah-vm-harness` lifecycle with AH's Tier-3 scripts (mutagen sync, cargo test, JUnit harvest).

## 9. Test methodology

This is the most important section for sub-agents executing the implementation campaign.

### 9.1 Mock policy: almost nothing

**Default position: test against real backends.** vm-harness exists to coordinate real VMs; testing it against mocked VMs would just verify that the mocks are wired up correctly, not that the backends work.

What's allowed to be mocked:

- *Pure-logic helpers* that take a string and return a struct (e.g., parsing `virsh list --all` output into a domain list). Unit tests here are fine; record real output once, replay it.
- *Time*, in performance-budget regression tests. Deterministic-clock injection for testing the `e2e_vm_harness_per_gate_revert_meets_m0_budget` regression assertions.

What is NOT allowed to be mocked:

- The VM backends themselves. `HyperVBackend::start` must actually start a Hyper-V VM. `TartBackend::clone` must actually run `tart clone`. No `MockBackend` substituted for `TartBackend` in any test that purports to verify Tart behavior.
- Process spawning. No mocking `osproc.startProcess`/`std::process::Command`. If a test wants to verify what arguments are passed to `tart`, it can use a shell shim (a real binary on PATH that records its argv and exits) — but that's still a real `osproc` call.
- File I/O. The output envelope is verified by *reading the actual files vm-harness wrote*, not by mocking the writer.
- SSH/PSDirect transports. Tests run actual `ssh` against actual `sshd` in the guest, or actual `Invoke-Command -VMName` against actual Hyper-V.

The one exception to "no backend mocks" is `NoopBackend` (M0 deliverable), which is a *deliberate test fixture* that implements the trait but does nothing. It exists for testing the dispatcher, output envelope, and lifecycle orchestration in isolation from any real backend. Tests that use `NoopBackend` must be named and described to make clear they're testing the harness scaffolding, not backend behavior (e.g., `e2e_vm_harness_finally_cleanup_on_panic`).

### 9.2 Test types

| Prefix | Type | What it tests | Where it runs |
|---|---|---|---|
| `unit_` | Unit test | Pure-logic helpers (parsers, struct builders, path math). | Any host, any CI. |
| `integration_` | Backend integration | Single backend + single primitive. E.g., "TartBackend::clone produces a clonable VM." | Host with that backend's tool installed. |
| `e2e_` | End-to-end | Full session lifecycle through one backend with at least one gate invocation. | Host with backend tool installed; may require real network for image pulls. |
| `cross_` | Cross-backend | Same gate run against multiple backends; asserts behavioral parity. | Host with all relevant backends; only Mac+Windows hosts have full coverage. |
| `verify_` | Verification script | Property-based golden-image verification. | Wherever the golden runs. |
| `just <target>` | Justfile target | Aggregates other tests into a runnable bundle. | Recorded as test name in milestone verifications when the Justfile target is the primary entry point. |

### 9.3 CI layering

Not every test runs on every host. Layers:

1. **Universal layer**: `unit_*` tests + `integration_noop_*` tests. Run on every CI host regardless of available backends.
2. **Per-host backend layer**:
   - Windows runner: `integration_hyperv_*`, `integration_wsl_*`, `e2e_*_on_hyperv`, `e2e_*_on_wsl`.
   - Linux runner: `integration_libvirt_*`, `e2e_*_on_libvirt`.
   - macOS-Apple-Silicon runner: `integration_tart_*`, `integration_utm_*`, `e2e_*_on_tart`, `e2e_*_on_utm`.
3. **Cross-backend layer** (most expensive): `cross_*` tests that compare results across backends. Only runs on hosts with multiple backends available — currently macOS hosts (Tart + UTM) and Windows hosts (Hyper-V + WSL).

The matrix is hand-mapped in the Justfile + CI config; no magic auto-detection.

### 9.4 What an integration test looks like

Concrete example for `integration_tart_clone_produces_running_vm`:

```nim
suite "TartBackend integration":
  test "clone from cirruslabs golden produces running VM":
    # NO MOCKS. Requires: Mac host, pkgs.tart installed, network access.
    let backend = newTartBackend()
    requireBackendAvailable(backend)
    
    let baselineName = "test-clone-baseline-" & $getpid()
    backend.provisionBaseline(BaselineSpec(
      name: baselineName,
      sourceImage: "ghcr.io/cirruslabs/macos-tahoe-base:latest",
      cpus: 2, memoryMB: 4096, diskGB: 50))
    
    defer:
      backend.removeBaseline(baselineName)  # cleanup
    
    let vm = backend.revertToBaseline(baselineName)
    
    defer:
      backend.stopAndCleanup(vm, deleteVm = true)
    
    # The actual assertion: SSH actually works.
    let r = backend.execInGuest(vm,
      env = initTable[string, string](),
      cmd = @["hostname"])
    check r.exitCode == 0
    check r.stdout.strip.len > 0
```

Note: real `tart clone`, real `tart run`, real `ssh`. No mocks anywhere. The test takes ~60-90 seconds wall-clock and is acceptable as a per-PR integration test.

### 9.5 What an e2e test looks like

`e2e_vm_harness_phase5_macos_gates_on_tart` (the M10 verification):

```nim
suite "Phase-5 macOS gates on Tart end-to-end":
  test "M5-M9 gates run back-to-back with revert-between, all PASS":
    # NO MOCKS. Requires: Mac host, pkgs.tart, repro binary built for Mac.
    let backend = newTartBackend()
    let baseline = "phase5-test-baseline"
    backend.provisionBaseline(BaselineSpec(name: baseline, ...))
    
    let gates = @[
      ("fs-systemfile",   "REPRO_PHASE5_MACOS_FS_VM"),
      ("fs-userfile",     "REPRO_PHASE5_MACOS_FS_VM"),
      ("env-userpath",    "REPRO_PHASE5_MACOS_ENV_VM"),
      # ...
    ]
    
    var revertTimings: seq[int]
    for (gateName, envVar) in gates:
      let revertStart = epochTime()
      let vm = backend.revertToBaseline(baseline)
      revertTimings.add(int((epochTime() - revertStart) * 1000))
      
      defer:
        backend.stopAndCleanup(vm)
      
      backend.copyToGuest(vm, reproBinaryPath, "/tmp/repro")
      let r = backend.execInGuest(vm,
        env = {envVar: "1"}.toTable,
        cmd = @["/tmp/repro", "test", gateName])
      check r.exitCode == 0
    
    # Performance contract regression: median revert wall-clock under budget.
    revertTimings.sort
    let median = revertTimings[revertTimings.len div 2]
    check median <= 30_000  # 30s budget per §3.4
```

### 9.6 Failure-mode tests

Specific tests for the failure modes that matter:

- `e2e_vm_harness_finally_cleanup_on_panic`: gate throws mid-run; verify stale VM is cleaned up.
- `integration_<backend>_handles_stale_ephemeral_from_prior_run`: pre-create a stale ephemeral; verify the backend cleans it up at session start.
- `integration_<backend>_timeout_on_hung_guest`: exec a command that hangs; verify the backend respects timeoutSec and recovers.
- `integration_<backend>_ssh_unreachable_recovery`: guest IP not reachable; verify clear error message, not infinite poll.

## 10. Repository layout

```
metacraft-labs/vm-harness/
├── README.md
├── LICENSE
├── flake.nix                        # dev shell with Nim + tart + utmctl + virsh
├── vm_harness.nimble                # Nimble package manifest
├── src/
│   ├── vm_harness.nim               # main module
│   └── vm_harness/
│       ├── types.nim                # VmBackend, VmHandle, ExecResult, etc.
│       ├── output.nim               # envelope writer
│       ├── auto.nim                 # backend dispatch
│       ├── cli.nim                  # CLI binary entry point
│       ├── backends/
│       │   ├── noop.nim             # test-only fixture
│       │   ├── hyperv.nim
│       │   ├── wsl.nim
│       │   ├── tart.nim
│       │   ├── utm.nim
│       │   └── libvirt.nim
│       └── guest_scripts.nim        # staticRead of guest-scripts/ for embedding
├── guest-scripts/
│   ├── posix.sh
│   ├── posix-shim-template.sh
│   ├── windows.ps1
│   └── windows-shim-template.ps1
├── guest-recipes/
│   └── windows-arm-base/
│       ├── autounattend.xml
│       └── README.md
├── tests/
│   ├── unit/
│   ├── integration/
│   │   ├── noop_lifecycle_test.nim
│   │   ├── tart_test.nim         # macOS-only
│   │   ├── utm_test.nim          # macOS-only
│   │   ├── hyperv_test.nim       # Windows-only
│   │   ├── wsl_test.nim          # Windows-only
│   │   └── libvirt_test.nim      # Linux-only
│   └── e2e/
│       └── full_session_smoke.nim
├── golden-outputs/                  # reference artifacts for Rust port cross-check
│   ├── hyperv-m69-feature-capability/
│   ├── wsl-m69-passwd-user/
│   └── ...
└── docs/
    ├── README.md
    ├── design.md                    # mirror of this document, kept in repo
    └── per-backend-notes/
        ├── tart.md
        ├── utm.md
        ├── hyperv.md
        └── ...
```

## 11. Implementation sequence (sub-agent build order)

The milestones file ([Multi-OS-VM-Automation-Campaign.milestones.org](Multi-OS-VM-Automation-Campaign.milestones.org)) defines the dependency graph. The implementation sequence:

1. **M0 — scaffold + NoopBackend + envelope writer + CLI shell.** Prerequisite: a fresh `metacraft-labs/vm-harness` repo. Sub-agent reads this doc + M0 deliverables, builds the trait, NoopBackend, envelope writer, CLI dispatcher. Tests: `unit_*` + `integration_noop_*`. Verification: `e2e_vm_harness_smoke` PASSes with NoopBackend.

2. **M1 — refactor existing Hyper-V + WSL backends.** Prerequisite: M0 + Windows host with existing reprobuild PowerShell harnesses. Sub-agent wraps `run-hyperv-m69-system.ps1` and `run-wsl-m69-posix.ps1` behind the trait. Tests: existing M69 gates pass via `vm-harness run --backend hyperv/wsl ...`.

3. **M2 — Tart backend.** Prerequisite: M0 + Mac host + `pkgs.tart` + network for image pull. Tests: `integration_tart_*` + `e2e_*_on_tart` (against cirruslabs golden, no AH-specific setup).

4. **M3 — UTM backend.** Prerequisite: M0 + Mac host + UTM installed + Windows ARM ISO. Bigger lift than M2 because the autounattend.xml + ISO assembly is new code; the existing Hyper-V autounattend can be the model.

5. **M4 — Phase-5 gate scaffolding.** Independent of M0–M3; can land in parallel. Test files compile with `nim check`; non-destructive halves PASS without any VM.

6. **M5–M9 — driver validation.** Each requires M2 + M4 + the relevant macOS driver code in reprobuild. Sub-agents can parallelize M5/M6/M7/M8/M9 since they're disjoint drivers.

7. **M10 — cross-backend integration.** Requires M1 + M2 + M3 + M5–M9. This milestone records golden output artifacts for the M15 Rust port's correctness gate.

8. **M15 — Rust port.** Reads the recorded artifacts from M10 as test inputs. Sub-agent translates Nim trait → Rust trait, ports each backend, runs `diff -r` against M10 outputs. Hard CI gate: byte-identical artifacts.

9. **M11–M14, M16–M26** — proceed per the milestones file dependency graph.

For each milestone, the sub-agent's session starts with reading the milestone's `Deliverables`, then this design doc's relevant section, then implementing. Session ends with updating the milestone's `Verification` test statuses and `last_updated`.

## 12. Implementation choices for M0 (no deferred questions)

Per the campaign's autonomous-execution policy, this section commits the answers up front rather than punting to sub-agent discretion. Sub-agents implement as specified; deviations require updating this doc.

1. **In-guest script delivery**: vendor via `staticRead` (compile-time embed). Simpler distribution; the Rust port (M17) does the same via `include_str!`. Either implementation reads the canonical scripts from `vm-harness/guest-scripts/` at build time.

2. **CLI binary distribution**: both Nimble package (`nimble install vm_harness` for Nim consumers / dev work) *and* pre-built binaries on GitHub Releases (for users without a Nim toolchain — primarily Mac users who just want `vm-harness` to run their Tart guest). Single repo, two distribution channels via CI.

3. **Logging strategy**: both. Human-readable on stderr by default (color when isatty, plain when piped). Structured JSON via `--log-format json` flag (events go to stderr too; stdout reserved for command output). Library API exposes a `LogSink` trait so consumers can route however they want.

4. **Async vs sync**: synchronous core API in the Nim library (matches Nim's `osproc` shape, simpler error handling). Backends that need parallel ops use threads via Nim's `std/threadpool`, *not* `asyncdispatch` (`asyncdispatch` is heavier than threads for this use case and adds dependency surface). The Rust port (M17) uses `tokio` since AH is already tokio-based.

## 13. References

- [Multi-OS-VM-Automation-Campaign.milestones.org](Multi-OS-VM-Automation-Campaign.milestones.org) — the campaign milestones that implement this design.
- [Tart-Based-macOS-VM-Provisioning.md](Tart-Based-macOS-VM-Provisioning.md) — Tart vs Lima vs UTM research, AVF entitlement handling.
- `metacraft/reprobuild/tools/hyperv-m69-system/README.md` — reference for the Hyper-V harness pattern wrapped by M1.
- `metacraft/reprobuild/tools/wsl-m69-posix/README.md` — reference for the WSL harness pattern wrapped by M1.
- `metacraft/reprobuild/tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim` — reference gate-file shape that Phase-5 gates (M4–M9) mirror.
- [libvirt domain XML reference](https://libvirt.org/formatdomain.html) — for libvirt backend.
- [Cuckoo Sandbox Machinery docs](https://cuckoo.readthedocs.io/) — abstract base class reference design.
- [cirruslabs/packer-plugin-tart](https://github.com/cirruslabs/packer-plugin-tart) — Tart driving reference.
- [naveenrajm7/packer-plugin-utm](https://github.com/naveenrajm7/packer-plugin-utm) — UTM driving reference.
- [naveenrajm7/vagrant_utm](https://github.com/naveenrajm7/vagrant_utm) — utmctl invocation patterns.
