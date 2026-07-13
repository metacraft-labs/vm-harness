# windows-x64-base — libvirt + QEMU/KVM Windows 11 Pro 24H2 baseline recipe (M4 Phase A)

This recipe produces a libvirt-managed domain (default name
**`windows-runner-001`**) that the M4 slice of `LibvirtBackend` boots
on a Linux host with KVM + libvirtd. The Nim backend
(`src/vm_harness/backends/libvirt.nim`) consumes already-defined
domains via `revertToBaseline`; this directory is the documentation +
scripts that produce one.

The recipe is the x86_64-on-Linux sibling of `windows-arm-base/`
(which targets UTM on macOS). It exists so the windows-runner-001
prototype on `high-mem-server` can be brought up by a single
`vm-harness provision --backend libvirt` invocation.

## What you get

A `qemu:///system` libvirt domain configured for:

- 4 vCPU, 8 GB RAM, 80 GB qcow2 in `/var/lib/libvirt/images/`.
- q35 board with UEFI + SMM (Win11 requires both).
- virtio-blk system disk, virtio-net adapter on `virbr0` (default
  NAT bridge; overridable via `--network-bridge`).
- `admin` user, password `repro-windows-x64`, auto-logon enabled.
- OOBE skipped via autounattend.xml (no first-run dialogs, no
  Microsoft account, no telemetry prompts).
- Windows OpenSSH server (`Server` capability) enabled and set to
  start automatically on boot.
- Firewall rule allowing inbound TCP/22.
- WinRM disabled (we use SSH, not PSRemoting, to mirror the cross-
  backend transport contract).
- virtio-win guest tools installed (qemu-guest-agent + paravirt
  driver MSI bundle) so `virsh domifaddr` returns the guest IP
  without leaning on the DHCP lease table.

## When to (re-)run this recipe

- **First time on a new Linux host** — once you've installed
  `libvirt`, `qemu`, `virt-install` (already provided by the
  vm-harness flake's dev shell on Linux), follow the build steps
  below to produce the baseline domain.
- **Microsoft rotates the Win11 24H2 ISO** — drop the new ISO at
  `/storage/iso/Win11_24H2_EnglishInternational_x64.iso` (or set
  `VMH_WIN11_X64_ISO`) and re-run.
- **The virtio-win driver disk rotates** — Red Hat publishes a new
  `virtio-win.iso` to fedorapeople every quarter or so; re-running
  `fetch-iso.sh` picks the latest stable.

## Build steps

The build is fully scripted; no GUI step is needed (unlike
`windows-arm-base/`, where UTM's bundle import is GUI-only). The
single hands-off invocation is:

```bash
vm-harness provision \
    --backend libvirt \
    --recipe windows-x64-base \
    --name windows-runner-001 \
    --vcpu 4 --memory-gb 8 --disk-gb 80 \
    --network-bridge virbr0 \
    --first-boot-script ./bootstrap-windows-runner-001.ps1
```

This is what the windows-runner-001 README on the infra repo
documents as the canonical operator command. If `vm-harness` isn't
on PATH yet, fall back to the manual sequence below.

### 1. Prerequisites

Inside the vm-harness dev shell (`nix develop`):

```bash
# libvirt + virt-install (Linux only).
# `virt-install` ships in pkgs.virt-manager.
which virsh virt-install qemu-img genisoimage curl
```

If you're on `high-mem-server`, libvirtd is already enabled (see
`infra/machines/server/high-mem-server/configuration.nix`); on any
other Linux host:

```bash
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"
# log out + back in for the group change to take effect.
```

### 2. Fetch the install media

```bash
./fetch-iso.sh
# Downloads: ./build/virtio-win.iso
# Verifies:  ${VMH_WIN11_X64_ISO:-/storage/iso/Win11_24H2_EnglishInternational_x64.iso}
```

The Win11 ISO is operator-supplied (Microsoft does not provide a
stable no-login direct URL); the virtio-win driver disk is fetched
from <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>.

### 3. Assemble the autounattend ISO

```bash
./build-autounattend-iso.sh --first-boot-script ./bootstrap-windows-runner-001.ps1
# Writes: ./build/autounattend.iso
```

This wraps `autounattend.xml` (the SysPrep answer file in this
directory) and the supplied first-boot.ps1 as an ISO9660+Joliet ISO
that libvirt attaches as a CD. Windows Setup looks for
`autounattend.xml` on every attached removable medium at first
boot and applies it automatically.

The autounattend.xml mirrors `windows-arm-base/autounattend.xml`
with three significant differences:

1. `processorArchitecture="amd64"` everywhere.
2. A `<DriverPaths>` block in the WindowsPE pass that pulls
   virtio-blk + virtio-net drivers from the virtio-win driver disk
   so Setup can see the qcow2-backed system disk on the q35 board.
3. A new FirstLogonCommand (#5/#6) that stages and runs the
   operator-supplied first-boot.ps1.

### 4. Run virt-install (or `vm-harness provision`)

The harness invocation at the top of this README does everything in
this step automatically. The equivalent manual virt-install is:

```bash
# See src/vm_harness/backends/libvirt.nim → buildVirtInstallArgs for
# the canonical argv.
virt-install --connect qemu:///system \
    --name windows-runner-001 \
    --osinfo win11 \
    --vcpus 4 --memory 8192 --cpu host \
    --machine q35 --boot uefi --features smm.state=on \
    --disk path=/var/lib/libvirt/images/windows-runner-001.qcow2,size=80,format=qcow2,bus=virtio \
    --disk device=cdrom,path=./build/Win11_24H2_x64.iso,bus=sata,readonly=on \
    --disk device=cdrom,path=./build/virtio-win.iso,bus=sata,readonly=on \
    --disk device=cdrom,path=./build/autounattend.iso,bus=sata,readonly=on \
    --network bridge=virbr0,model=virtio \
    --graphics vnc,listen=127.0.0.1 \
    --noautoconsole --wait 60
```

The autounattend drives Win11 Setup through to the desktop; the
FirstLogonCommands install OpenSSH, the virtio-win guest tools, and
the operator's first-boot.ps1. Wall-clock is 20-40 minutes on
typical hardware (Win11 Setup itself is ~70% of that).

The recipe is complete when:

- `virsh domstate windows-runner-001` reports a running domain.
- `virsh domifaddr windows-runner-001` returns an IP.
- An SSH probe (`ssh admin@<ip>` with password `repro-windows-x64`)
  succeeds and `Test-Path C:\Windows\Temp\repro-install-done`
  returns `True`.

### 5. Finalize

Once the install is verified:

```bash
./finalize-golden.sh
```

This:

- Confirms the domain is defined and in the `shut off` state.
- Detaches the three install ISOs (Win11, virtio-win,
  autounattend) so subsequent boots come straight off the qcow2.
- Marks the domain `autostart` so a host reboot brings it back.

### 6. Smoke test

```bash
# From the vm-harness repo root.
nimble test
```

The M4 verification test (`tests/integration/t_libvirt_backend.nim`)
runs without booting any VM and asserts on the argv shape +
stub-method clarity. The live-libvirt lifecycle test will land
with M4 Phase B (snapshots).

## Total wall-clock

Rough budget on a 2024-era AMD EPYC server with NVMe storage:

| Step | Time |
|---|---|
| Download virtio-win.iso | 1-2 min |
| Verify Win11 ISO is in place | <1 min |
| Assemble autounattend ISO | <1 min |
| virt-install + Win11 Setup | 20-40 min |
| OpenSSH install (FirstLogonCommands) | 1-3 min |
| virtio-win guest tools | 2-5 min |
| **Total** | **25-50 min** |

The good news: this is a one-time cost per Linux host per Win11
release. After the domain is finalized, every per-gate revert is
the harness's ≤10s `virsh snapshot-revert --running` budget — but
**snapshot wiring is M4 Phase B**; the M4 Phase A slice treats the
domain as long-lived and skips per-gate revert.

## Files in this directory

- `README.md` — this document.
- `autounattend.xml` — the Win11 answer file. Single source of
  truth for admin credentials, locale, OOBE skip flags,
  FirstLogonCommands (OpenSSH install, firewall rule, virtio-win
  guest tools install, first-boot.ps1 run, install-done sentinel).
- `fetch-iso.sh` — downloads virtio-win.iso, verifies the
  operator-supplied Win11 ISO.
- `build-autounattend-iso.sh` — wraps autounattend.xml + an optional
  first-boot.ps1 as a CD-ROM ISO9660+Joliet image.
- `finalize-golden.sh` — verifies the domain is in the expected
  state, detaches install ISOs, marks autostart.

All scripts are POSIX `bash` and self-contained; they accept
`--help` for usage.

## What's NOT in this recipe

- **Per-gate snapshot revert** — the M4 Phase B slice will wire
  `virsh snapshot-create-as` and `virsh snapshot-revert --running`
  into `LibvirtBackend.snapshot` / `restoreSnapshot`. Today the
  recipe produces a long-lived "runner" domain that survives across
  vm-harness invocations.
- **SR-IOV NIC passthrough / GPU passthrough** — tracked as M4
  Phase C; needs host-side IOMMU group manipulation that lives
  outside the per-baseline recipe.
- **Activation** — the install uses Win11 Pro's generic install
  key; productionization would activate against KMS or a MAK.
- **Argv-trace shim** — `LibvirtBackend.installArgvTraceShim`
  raises `BackendUnavailableError` today; the Windows shim shape
  ports cleanly from `hyperv.nim` but the SSH-transit install path
  needs Phase B work.
