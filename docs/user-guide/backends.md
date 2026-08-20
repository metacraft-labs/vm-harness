# Backends: setup and caveats

vm-harness selects a backend from the (host OS, guest OS) pair, or you name one
explicitly with `--backend <id>` (CLI) / a `new<Name>Backend(...)` constructor
(library). This page covers what each **shipped** backend needs on the host,
which guests it drives, how it resets, and its known gotchas. Check what is
actually available on your host with `vm-harness probe`.

For the deep per-backend transport details (SSH vs PowerShell Direct vs
`incus exec`, file-transfer mechanism, snapshot strategy) read the notes under
[`../per-backend-notes/`](../per-backend-notes/) and `../design.md`.

## Support matrix (shipped)

| Backend id | Host | Guests | Reset mechanism | In-guest transport |
| --- | --- | --- | --- | --- |
| `hyperv` | Windows | Linux, Windows | `Restore-VMCheckpoint` | PowerShell Direct (VMBus) |
| `wsl` | Windows | Linux | `wsl --import` of cached rootfs | `wsl --exec` |
| `libvirt` | Linux | Linux, Windows | `virsh snapshot-revert --running`; per-job CoW clone (ephemeral) | SSH |
| `incus` | Linux | Linux (system container) | fresh ephemeral container per job | `incus exec` |
| `lima` | macOS, Linux | Linux | `limactl delete + create + start` | `limactl shell` |
| `tart-macos` | macOS (Apple Silicon) | macOS | `tart clone` from local OCI cache | SSH |
| `tart-linux-arm` | macOS (Apple Silicon) | Linux (ARM) | `tart clone` | SSH |
| `utm-windows-arm` | macOS (Apple Silicon) | Windows (ARM) | `utmctl clone` from local bundle | SSH |
| `qemu-windows-arm` | macOS (Apple Silicon) | Windows (ARM) | per-job qcow2 overlay | SSH |
| `noop` | any | any | — | — (test fixture only) |

The `noop` backend is a reference fixture for exercising harness scaffolding
without any real hypervisor — the only mock allowed by the test methodology
(`../design.md` §9).

---

## libvirt / QEMU (Linux host)

- **Host needs:** `libvirt`, `qemu`, `virt-install`, `virsh`, `qemu-img` (the
  dev shell provides these on Linux). Access to `qemu:///system` (default URI).
- **Guests:** Linux, or x86_64 Windows via `virt-install` + an autounattend ISO.
- **Reset:** native snapshot revert for a persistent baseline; or a fully
  ephemeral **per-job CoW clone** (`run --ephemeral`): fresh overlay from a
  golden qcow2 → boot on KVM → probe → destroy overlay + config-drive + nvram,
  leaving no residue.
- **Constructor defaults:** `libvirtUri = qemu:///system`, `imagePoolDir =
  /var/lib/libvirt/images`, `networkBridge = virbr0`. Windows-guest SSH defaults
  to `admin` / `repro-windows-x64`.
- **Windows guests** are provisioned from a `guest-recipes/windows-x64-base`
  recipe that assembles an autounattend ISO; a controller SSH pubkey and a
  first-boot script can be baked into that ISO (`--controller-pubkey`,
  `--first-boot-script`, both require `--recipe`). See
  [`../m4-libvirt.md`](../m4-libvirt.md) for the canonical command shapes and the
  Phase B/C scope (snapshot/restore, GPU/SR-IOV/USB passthrough are outstanding).
- **Caveat:** the golden qcow2 and *every parent directory* must be readable by
  the libvirt/QEMU user, or the clone fails to open its backing file.

## Incus (Linux host, system-container guests)

- **Host needs:** the `incus` daemon initialized (declaratively via NixOS
  `virtualisation.incus`, or `incus admin init --minimal` once on a non-NixOS
  host), plus the service user in the `incus-admin` group for socket access.
- **Guests:** Linux system containers. Sub-second launch, no `/dev/kvm` — the
  container analog of the libvirt per-job path.
- **Reset:** ephemeral only — `incus launch <base> <name>` → `incus exec` probe
  → `incus delete --force`, no residual container or storage volume.
- **Constructor defaults:** `baseImage = vmh-base`, `storagePool = default`.
- **Socket-access caveat:** if your session pre-dates the `incus-admin` group
  grant (or you are in a sandbox), prefix the CLI:
  `export VMH_INCUS_CMD="sudo -n incus"`. The backend reads `VMH_INCUS_CMD`
  (space-split) as its command vector; production leaves it unset.
- **JIT seam:** `provisionEphemeralClone` leaves a cloud-init `user-data`
  injection point (`incus config set <name> cloud-init.user-data ...`) for a
  GARM JIT bootstrap. The base image is pinned locally, e.g.
  `incus image copy images:debian/12 local: --alias vmh-base`.
- **Networking caveat (host-dependent):** on hosts where `incusbr0` DHCP does
  not lease, a static per-job IP is injected via cloud-init and large files are
  streamed in via `cat | incus exec tar` rather than `incus file push` (which
  can corrupt large tarballs on some hosts). See
  [`../per-backend-notes/incus.md`](../per-backend-notes/incus.md).

## Lima (macOS or Linux host, Linux guest)

- **Host needs:** `limactl` (dev shell provides `lima`; otherwise
  `brew install lima` / `nix profile install nixpkgs#lima`).
- **Reset:** delete + recreate + start (targets ≤ 30 s). `provisionBaseline`
  also reaps stale `repro-vm-lima-*` instances from aborted prior runs.
- **Constructor:** `newLimaBackend(cpus, memoryGiB, diskGiB, bootTimeoutSec)`;
  boot timeout is tunable (the tests read `VMH_LIMA_BOOT_TIMEOUT` for slow CI
  disks).
- **Note:** the library gates Lima to macOS in the integration test, but the
  backend is offered on Linux hosts too.

## Tart (Apple-Silicon macOS host)

- **Host needs:** Tart installed out-of-band — it lives outside nixpkgs on
  macOS (`brew install cirruslabs/cli/tart`). The dev shell provides `qemu` and
  `lima` but not Tart/UTM.
- **Guests:** macOS (`tart-macos`) and Linux-ARM (`tart-linux-arm`).
- **Reset:** `tart clone` from a local OCI image cache (≤ 30 s).
- **Constructor defaults:** cirruslabs image credentials `admin` / `admin`;
  `sshPort = 22`. Override `goldenImage`, `sshUser`, `sshPassword`, timeouts,
  and `ephemeralPrefix` as needed.
- **Caveat:** Apple's macOS licensing restricts the number of concurrent macOS
  guests; macOS guests are impossible on non-Apple hosts.

## UTM (Apple-Silicon macOS host, Windows-on-ARM guest)

- **Host needs:** UTM installed out-of-band (provides `utmctl`).
- **Guests:** Windows on ARM (`utm-windows-arm`). Partial support (M3).
- **Reset:** `utmctl clone` from a local bundle (≤ 20 s).
- **Recipe:** built from `guest-recipes/windows-arm-base` (autounattend ISO
  assembly, with an offline Win32-OpenSSH ARM64 fallback).

## qemu-windows-arm (Apple-Silicon macOS host, Windows-on-ARM guest)

- An alternative Windows-on-ARM path driven directly through `qemu-system-aarch64`
  + `qemu-img` + `swtpm`, with SSH into the guest. Heavily env-tunable — see the
  `VMH_QEMU_WINDOWS_ARM_*` and `VMH_QEMU_EFI_*` variables in the [Parameters
  catalog](./parameters.md). Has a dedicated `prune` scope for its per-job state
  directory.

## Hyper-V (Windows host)

- **Host needs:** Hyper-V enabled; PowerShell available. Uses PowerShell Direct
  over VMBus (no in-guest network required for control).
- **Guests:** Linux and Windows.
- **Reset:** `Restore-VMCheckpoint` (≤ 10 s); supports running-state
  (memory) checkpoints for the fastest reverts, plus snapshot export/import for
  cross-host baseline caching.
- **Constructor:** `newHyperVBackend(vmName, ...)`; a PowerShell launcher and a
  default gate timeout are configurable.

## WSL (Windows host, Linux guest)

- **Host needs:** WSL2.
- **Reset:** `wsl --import` of a cached rootfs tarball into a fresh distro
  (≤ 20 s); exec via `wsl --exec`.
- **Constructor:** `newWslBackend(distroPrefix, rootfsTarballPath,
  installRootDir, defaultUser = "root", ...)`.

---

## Cleaning up leaked instances

If a launcher is hard-killed, ephemeral clones can leak. The `prune` subcommand
reclaims them, scoped to a project's `--ephemeral-prefix`, and never removes an
instance whose owner is still alive. It supports the `tart` and
`qemu-windows-arm` backends (or `all`). See the [CLI reference](./cli-reference.md#prune).
