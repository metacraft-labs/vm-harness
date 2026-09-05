# M4: libvirt + QEMU/KVM backend (Linux host)

Status: **M4 Phase A shipped.** Phases B + C tracked below.

The M4 milestone of the Multi-OS VM Automation Campaign brings a
libvirt/QEMU adapter to vm-harness so Linux hosts can manage Windows
or Linux guests through the same `VmBackend` contract every other
backend implements. The first slice of M4 (Phase A — this document's
subject) targets the windows-runner-001 prototype on
`high-mem-server`: a single libvirt-managed Win11 24H2 Pro guest
running a self-hosted GitHub Actions runner. Per-gate snapshot
revert, GPU passthrough, and SR-IOV are out of scope for Phase A.

The implementation lives at
[`src/vm_harness/backends/libvirt.nim`](../src/vm_harness/backends/libvirt.nim);
the consumer-facing recipe at
[`guest-recipes/windows-x64-base/`](../guest-recipes/windows-x64-base/).

## What Phase A ships

| Surface | Status | Notes |
|---|---|---|
| `probeAvailability` | shipped | Returns true when `virsh --version` AND `virsh list` against `qemu:///system` both succeed. |
| `provisionBaseline` (ISO + autounattend) | shipped | Shells out to `virt-install` with q35/UEFI/SMM + virtio-blk + virtio-net + virtio-win driver injection. Idempotent when the domain already exists. |
| `revertToBaseline` | shipped (long-lived domain only) | Starts the named domain, polls `virsh domifaddr` for an IP, returns a `VmHandle`. Does NOT itself do per-gate snapshot revert; `restoreSnapshot` is the primitive for that, and wiring the fleet onto it is campaign WR1. |
| `startAndAwaitReady` | shipped | Polls SSH `hostname` until the guest accepts logins. |
| `execInGuest` | shipped | SSH via Windows OpenSSH; argv quoted for cmd.exe; env propagated via `set KEY=VAL && ...`. |
| `copyToGuest` / `copyFromGuest` | shipped | scp with `sshpass -e` (password never on argv). |
| `bootFromMedia` (qcow2/ISO) | shipped | Transient `virt-install --import` (qcow2) or `--cdrom` (ISO); domain name must start with `repro-test-boot-libvirt-` for the safety sweep. |
| `stopAndCleanup` | shipped | ACPI `virsh shutdown` then fall back to `destroy`; optional `undefine --remove-all-storage`. Never raises (finally-safe). |
| `installArgvTraceShim` | NOT shipped (Phase B) | Same shim shape as `hyperv.nim` but install path needs SSH transit. |
| `snapshot` / `snapshotRunning` / `restoreSnapshot` / `listSnapshots` / `removeSnapshot` | shipped (campaign WR0) | EXTERNAL `virsh snapshot-create-as` (`--live` + an external memspec for the hot form) and `snapshot-revert --running`. See [`per-backend-notes/libvirt-snapshot-benchmarks.md`](per-backend-notes/libvirt-snapshot-benchmarks.md) for why external rather than internal, and for what is measured vs not. |
| `exportBaseline` / `importBaseline` | NOT shipped (campaign WR3) | `virsh dumpxml` + `qemu-img convert` with reflinks — and must answer how an exported warm state avoids reproducing one guest identity on many domains. |
| `captureSerial` / `expectLine` | NOT shipped (Phase B) | QEMU `-serial pty` + `virsh console` plumbing. |
| GPU passthrough | NOT shipped (Phase C) | Needs host-side IOMMU bind/unbind. |
| SR-IOV NIC passthrough | NOT shipped (Phase C) | Needs `ip link set vfX` + virsh device-attach. |

Every NOT-shipped method raises `BackendUnavailableError` with an
unambiguous message naming the planned follow-on work, so callers
discover the gap loudly instead of seeing a silent no-op.

## What Phase A is for

The narrow, load-bearing use case is:

1. An operator runs `vm-harness provision` on `high-mem-server`
   (Linux host with KVM + libvirtd).
2. The harness invokes `virt-install` against the Win11 ISO + the
   autounattend ISO + the virtio-win driver ISO and waits for the
   guest to finish installing.
3. The autounattend's FirstLogonCommands install OpenSSH, the
   virtio-win guest tools, and stage + run the operator-supplied
   first-boot.ps1 (which installs the GitHub Actions runner agent,
   registers with the org, and starts the service).
4. The harness marks the domain `virsh autostart` so the runner
   survives a host reboot.
5. `vm-harness run --backend libvirt --baseline windows-runner-001 --
   <cmd>` against the running domain executes `<cmd>` over SSH and
   harvests output the same way every other backend does.

Steps 1-4 are what `LibvirtBackend.provisionBaseline` does; step 5
is `revertToBaseline + execInGuest + copyFromGuest`.

## Operator command examples

### Provision the windows-runner-001 baseline

```bash
# On high-mem-server (or any host with libvirtd + KVM):
vm-harness provision \
    --backend libvirt \
    --recipe windows-x64-base \
    --name windows-runner-001 \
    --vcpu 4 --memory-gb 8 --disk-gb 80 \
    --network-bridge virbr0 \
    --first-boot-script ./bootstrap-windows-runner-001.ps1
```

Wall-clock: 25-50 minutes on first run (mostly Win11 Setup).

Before it launches `virt-install`, `provisionBaseline` validates that the
Windows install ISO carries a UEFI (EFI) El Torito boot record
(`LibvirtBackend.validateWindowsIsoBootable`, via `xorriso`). A BIOS-only
ISO can't boot the UEFI q35 domain — OVMF drops to the UEFI shell and
`--wait` would stall ~90 minutes — so the CLI fails fast with guidance to
supply a UEFI-bootable Win11 ISO. This protects the one-command flow above
even when the operator skipped the recipe's `fetch-iso.sh` prep (which runs
the identical check). Missing `xorriso` ⇒ the check is skipped with a
warning, never a hard failure.

When the host's storage lives outside the default libvirt image pool
(`/var/lib/libvirt/images`) — e.g. a large ZFS pool mounted at
`/storage` — add `--image-pool-dir /storage/libvirt`; the domain's
qcow2 then lands at `/storage/libvirt/<name>.qcow2` instead. Omit it to
keep the default byte-for-byte. This threads through
`BaselineSpec.imagePoolDir` into `LibvirtBackend.imagePoolDir` and is
honoured by both the ISO-install and the `.qcow2`-import provision
paths.

The flags `--recipe`, `--name`, `--vcpu`, `--memory-gb`,
`--network-bridge`, and `--first-boot-script` are the canonical
libvirt-slice surface — `parseCliOpts` resolves them at parse time
(see `src/vm_harness/cli.nim`) and threads them through into
`BaselineSpec.recipeDir / firstBootScript / networkBridge`. The
`LibvirtBackend.provisionBaseline` method then invokes the recipe's
`build-autounattend-iso.sh --first-boot-script <path>` before
`virt-install`, so a single invocation produces the per-VM
autounattend ISO and starts the install in one step.

Aliases preserved for compatibility with the historical vm-harness
surface: `--vcpu` ≡ `--cpus`, `--memory-gb` ≡ `--memory-mb` (× 1024),
`--name` ≡ `--baseline` (must agree if both are passed).

### Run a one-shot command in the guest

```bash
vm-harness run \
    --backend libvirt \
    --baseline windows-runner-001 \
    --output-dir /tmp/vmh-run-$(date +%s) \
    -- powershell.exe -NoProfile -Command "Get-Service actions.runner.*"
```

### Probe what's available on this host

```bash
vm-harness probe
# Expected on high-mem-server:
#   {"id":"libvirt","available":true,"host":"linux", ...}
```

### Manual virsh — same operations as the harness

```bash
virsh --connect qemu:///system list --all
virsh --connect qemu:///system domifaddr windows-runner-001
virsh --connect qemu:///system shutdown windows-runner-001
```

## Known issues and rough edges

1. **`virsh domifaddr` against the DHCP lease table can race with the
   guest's first DHCP lease renewal.** The harness retries for
   `sshReadyTimeoutSec` (default 300s) which is plenty for a normal
   boot, but if the lease times out exactly during the poll window
   you'll see a transient "no IP" error. Re-running the gate is
   safe.
2. **The virtio-win driver path baked into autounattend.xml assumes
   the operator did not reorder the sata CD attach order.** The
   recipe attaches Win11 ISO -> virtio-win.iso -> autounattend.iso,
   which gives `D:` to virtio-win under WindowsPE. Changing the
   bus/order in `buildVirtInstallArgs` requires updating
   `<DriverPaths>` in `autounattend.xml` to match.
3. **`provisionBaseline` does not support a pre-built qcow2 import
   path.** Passing a `.qcow2` as `sourceImage` raises
   `BackendUnavailableError` with a clear message — the qcow2
   fast-path is a planned Phase B addition.
4. **No serial-console capture.** Boot-time assertions (the
   `captureSerial` / `expectLine` surface that `WslBackend` and
   `HyperVBackend` use for ReproOS bring-up tests) are not wired
   yet. Operators debugging a stuck install must use
   `virt-viewer` / VNC on `127.0.0.1:5900` (or whatever
   `--graphics vnc,listen=...` opened).
5. **`installArgvTraceShim` raises immediately.** The Tier-2
   reprobuild useradd/useradd-trace gates can't run against the
   libvirt backend yet; use `HyperVBackend` on a Windows admin
   workstation if you need that today.

## What's NOT in this slice — Phase B + C

**M4 Phase B (snapshot / shim / serial — next libvirt slice):**

- `snapshot` via `virsh snapshot-create-as <vm> <name>`.
- `snapshotRunning` via `virsh snapshot-create-as <vm> <name>
  --live` (hot snapshot including RAM + CPU + device state).
- `restoreSnapshot` via `virsh snapshot-revert <vm> <name>
  --running`.
- `removeSnapshot` via `virsh snapshot-delete`.
- `exportBaseline` via `virsh dumpxml` + `qemu-img convert`
  (reflinks when destination volume supports them).
- `importBaseline` consuming the Phase B export bundle.
- `installArgvTraceShim` — Windows shim install via SSH transit
  (the shim shape is identical to `hyperv.nim`'s).
- `captureSerial` / `expectLine` / `serialSend` — QEMU `-serial
  pty` + reader thread, mirroring `hyperv.nim`'s named-pipe
  pattern.

**M4 Phase C (passthrough — final libvirt slice):**

- GPU passthrough (vfio-pci bind/unbind helpers + per-domain XML
  device fragment).
- SR-IOV NIC passthrough (`ip link set vfX` + virsh device-attach).
- USB device passthrough.

Phase C is gated on a host with the right hardware
(`high-mem-server` has neither a discrete GPU nor SR-IOV-capable
NIC, so the work waits for an applicable runner host).

## Related files

- [`src/vm_harness/backends/libvirt.nim`](../src/vm_harness/backends/libvirt.nim) — the backend implementation (~600 lines).
- [`tests/integration/t_libvirt_backend.nim`](../tests/integration/t_libvirt_backend.nim) — no-live-virsh smoke test.
- [`guest-recipes/windows-x64-base/`](../guest-recipes/windows-x64-base/) — the autounattend + helper scripts that produce the Win11 x64 baseline.
- The infra-repo windows-runner-001 prototype README (sibling worktree) — operator-facing documentation that consumes this backend.
