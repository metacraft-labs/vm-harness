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

- 4 vCPU, 8 GB RAM, 80 GB qcow2 in `/var/lib/libvirt/images/`
  (override the directory with `--image-pool-dir <dir>` when your
  storage lives elsewhere, e.g. a ZFS pool at `/storage`; the disk
  then lands at `<dir>/<name>.qcow2`).
- q35 board with UEFI + SMM (Win11 requires both).
- virtio-blk system disk, virtio-net adapter on `virbr0` (default
  NAT bridge; overridable via `--network-bridge`).
- `admin` user, password `repro-windows-x64`, auto-logon enabled.
- OOBE skipped via autounattend.xml (no first-run dialogs, no
  Microsoft account, no telemetry prompts).
- Windows OpenSSH server (`Server` capability) enabled and set to
  start automatically on boot.
- Firewall rule allowing inbound TCP/22.
- **Git for Windows** (PortableGit, pinned + checksummed) at
  `C:\PortableGit`, with `C:\PortableGit\bin` on the **machine** PATH.
  This is what supplies `bash.exe`; see
  [§Git for Windows](#git-for-windows-and-why-the-machine-path-matters).
- WinRM disabled (we use SSH, not PSRemoting, to mirror the cross-
  backend transport contract).
- virtio-win guest tools installed (qemu-guest-agent + paravirt
  driver MSI bundle) so `virsh domifaddr` returns the guest IP
  without leaning on the DHCP lease table.

## Git for Windows, and why the machine PATH matters

Clones of this golden run GitHub Actions jobs. Git for Windows is what
supplies `bash.exe` on Windows, so without it:

- every step with `shell: bash` fails with
  `##[error]bash: command not found` — including the **first** step of
  `metacraft-labs/metacraft-github-actions/setup-dev-env`, so jobs die
  before any repo-specific work runs; and
- `actions/checkout` logs *"The repository will be downloaded using the
  GitHub REST API / To create a local Git repository instead, add Git
  2.18 or higher to the PATH"* and leaves no `.git` behind.

Earlier revisions of this recipe installed no Git at any stage, which is
exactly the defect above.

**The PATH scope is the load-bearing part.** The Actions runner runs as a
Windows *service*. `services.exe` builds **one** environment block when
it starts at boot, reading
`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, and
hands a copy of that block to every service it launches. Therefore:

- an installer that edits only the interactive user's PATH
  (`HKCU\Environment`) is invisible to the service, permanently;
- a `setx PATH` in a logon script is likewise invisible;
- even a correct `HKLM` edit does not reach services already running, or
  services started later in the same boot from the SCM's cached block.

That is why the install belongs **in the golden, before capture** rather
than in the per-instance bootstrap: the image ships with the machine PATH
already extended, so on every clone's boot `services.exe` reads it from
the registry and cloudbase-init (a service) plus the actions-runner it
launches both inherit it — no ordering race, no reboot at job time.

Only `C:\PortableGit\bin` goes on the machine PATH. Its three files
(`bash.exe`, `sh.exe`, `git.exe`) are Git for Windows' ~47 KB
`git-wrapper` shim, which prepends `..\usr\bin` and `..\mingw64\bin` to
PATH *inside the spawned process* before exec'ing the real
`usr\bin\bash.exe`. So `shell: bash` steps also get `sha256sum`, `awk`,
`unzip` and `tar`, **without** shadowing the Windows `find.exe` and
`sort.exe` machine-wide (which is what putting `usr\bin` itself on the
machine PATH — the Inno installer's `/o:PathOption=CmdTools` — would do).

MinGit was evaluated and rejected: it ships `sh.exe`/`dash.exe` but **no
`bash.exe`**, and no `sha256sum`/`unzip`/`tar`/`curl`.

The version and both SHA-256 checksums are pinned in
[`../lib/provision-git.ps1`](../lib/provision-git.ps1), which is the
single source of truth; `../lib/fetch-portable-git.sh` parses the pin out
of it rather than repeating it.

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

> **Fail-fast on a BIOS-only ISO.** Before launching `virt-install`,
> `vm-harness provision` validates that the Windows ISO carries a UEFI
> (EFI) El Torito boot record (via `xorriso`). A BIOS-only ISO can't
> boot the UEFI q35 domain — OVMF drops to the UEFI shell and
> `virt-install --wait` would otherwise stall ~90 minutes with no clear
> cause. The CLI rejects it up front with a message telling you to
> supply a UEFI-bootable Win11 ISO (a stock Microsoft ISO works) via
> `--source-image` / `VMH_WIN11_X64_ISO`. The optional `fetch-iso.sh`
> prep performs the identical check, so both paths are protected. When
> `xorriso` is absent the check is skipped with a warning (never a hard
> failure on missing tooling).

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

../lib/fetch-portable-git.sh --arch x64 --output ./build
# Downloads + SHA-256-verifies: ./build/PortableGit-<pinned>-64-bit.7z.exe
```

Fetching PortableGit host-side is optional but recommended: it keeps the
golden build working on a NAT'd or offline builder and puts the download
on the reproducible side of the fence. If you skip it, the guest
downloads the same pinned asset itself and verifies the same checksum.

The Win11 ISO is operator-supplied (Microsoft does not provide a
stable no-login direct URL); the virtio-win driver disk is fetched
from <https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso>.

### 3. Assemble the autounattend ISO

```bash
./build-autounattend-iso.sh --first-boot-script ./bootstrap-windows-runner-001.ps1 \
    --require-portable-git
# Writes: ./build/autounattend.iso
```

`--require-portable-git` makes the build fail loudly if step 2's
PortableGit fetch was skipped, rather than silently producing an ISO
whose guest has to reach github.com at first logon. Drop the flag if you
intend the guest to download it.

This wraps `autounattend.xml` (the SysPrep answer file in this
directory), `../lib/provision-git.ps1`, the pinned PortableGit archive
(under `git/`) and the supplied first-boot.ps1 as an ISO9660+Joliet ISO
that libvirt attaches as a CD. Windows Setup looks for
`autounattend.xml` on every attached removable medium at first
boot and applies it automatically.

The autounattend.xml mirrors `windows-arm-base/autounattend.xml`
with three significant differences:

1. `processorArchitecture="amd64"` everywhere.
2. A `<DriverPaths>` block in the WindowsPE pass that pulls
   virtio-blk + virtio-net drivers from the virtio-win driver disk
   so Setup can see the qcow2-backed system disk on the q35 board.
3. A new FirstLogonCommand (#11/#12) that stages and runs the
   operator-supplied first-boot.ps1.

Both recipes share FirstLogonCommands that stage and run
`provision-git.ps1` (x64 steps #9/#10).

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

### Verify before finalizing — enforced, not just documented

`provision-git.ps1` deliberately exits 0 even when it fails, so that a Git
problem cannot wedge the rest of the FirstLogonCommands chain (including
the shutdown that signals install-complete to `virt-install`).

On its own that would be dangerous: the golden could be captured with no
Git and nothing would notice until every Windows CI job failed at
`bash: command not found` again. So the check is **enforced by
[`../lib/assert-git-provisioned.ps1`](../lib/assert-git-provisioned.ps1)**,
which `build-sysprep-golden.sh` runs as a **hard gate before SysPrep** — a
Git-less image aborts the golden build instead of shipping.

The gate asserts, and exits non-zero on any of:

- `C:\Windows\Temp\vmh-git-provision-failed` exists (dumps the log tail);
- the **raw** machine `PATH` registry value does not contain
  `C:\PortableGit\bin` — the value that survives capture and that
  `services.exe` hands to the runner service on every clone;
- that value is no longer `REG_EXPAND_SZ` (which would stop
  `%SystemRoot%`-style tokens expanding for every process);
- any of `bash git sha256sum awk unzip tar curl` fails to resolve through
  `C:\PortableGit\bin\bash.exe` — checked **individually**, so a missing
  coreutil cannot hide behind a successful `bash`.

To run it by hand against a booted guest (it is also staged at the
autounattend ISO root):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File C:\Windows\Temp\assert-git-provisioned.ps1
# exit 0 = fit to capture; exit 1 = do not capture
```

`VMH_SKIP_GIT_GATE=1` bypasses the gate in `build-sysprep-golden.sh`. It
logs three `WARNING` lines and exists only for bisecting an unrelated
SysPrep failure — never for producing a golden that will be shipped.

Note that a **freshly logged-on interactive SSH session may not show the
new PATH** even when the registry is correct, because the sshd service
itself inherited the pre-install environment block. That is expected and
is not a failure — the registry value is the thing that matters, since
every clone boots a new `services.exe`. To see it end-to-end on the build
VM itself, reboot the guest and re-check `$env:Path`.

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

## Retrofitting Git onto an already-built golden

The goldens in the field (`golden-win11-post-install.qcow2` →
`golden-win11-cloudbase.qcow2` → `golden-win11-cloudbase-sysprepped.qcow2`)
predate this recipe change and have no Git. Rebuilding the base golden from
scratch is 25–50 min plus re-layering cloudbase-init and the sysprep; the
cheaper path is to apply `provision-git.ps1` as one more layer, using the
same boot-a-copy / modify / capture-cold procedure that
[`cloudbase-init-golden.md`](cloudbase-init-golden.md) documents:

1. `qemu-img convert -O qcow2 <golden> /storage/scratch/git-work.qcow2`
   (a full standalone copy — never mutate the live golden).
2. Boot a throwaway UEFI/OVMF domain off the copy (see
   `build-sysprep-golden.sh` for the exact domain XML) and SSH in.
3. `scp ../lib/provision-git.ps1 admin@<ip>:C:/provision-git.ps1`, then
   run it elevated:
   `powershell -NoProfile -ExecutionPolicy Bypass -File C:\provision-git.ps1 -Arch x64`
   (with no staged archive it downloads the pinned asset and verifies the
   pinned checksum).
4. Run the **Verify before finalizing** checks above.
5. `Stop-Computer -Force`, then capture cold:
   `qemu-img convert -O qcow2 /storage/scratch/git-work.qcow2 <new-golden>`.
6. Re-point the GARM image at the new golden and drain/recreate the pool
   so running instances are replaced.

If the target is the **sysprepped** golden, do this on the *pre*-sysprep
golden and re-run `build-sysprep-golden.sh`: booting a generalized image
consumes the generalize.

**Status (2026-08-17):** the retrofit has been applied on `high-mem-server`.
`/storage/iso/golden-win11-cloudbase.qcow2` now carries PortableGit
(`git version 2.55.0.windows.4`, `C:\PortableGit\bin` on the machine PATH,
proved service-visible), and the pre-retrofit image is preserved at
`/storage/iso/golden-win11-cloudbase-pre-git-20260817.qcow2` for a one-move
rollback. Re-running `build-sysprep-golden.sh` against that golden now
inherits Git without any extra step.

### Known defects in the field (not fixed by this recipe)

Two problems were found during that rollout. Neither is caused by the Git
work and neither is fixed here; they are recorded so the next person does
not rediscover them the hard way.

- **The golden's `admin` password expired on 2026-08-03.** Windows refuses
  password authentication for an expired account, so the `ssh admin@<ip>`
  step in the retrofit procedure above — and in
  [`cloudbase-init-golden.md`](cloudbase-init-golden.md) — fails on an
  untouched copy of the golden. Any in-guest work has to go through another
  channel (the QEMU guest agent works) until the account is fixed. The real
  fix belongs in `autounattend.xml`: the `admin` account should be created
  with a non-expiring password so goldens do not acquire an expiry date they
  will eventually cross.
- **A runner suspended itself (S3) mid-job.** The guest's power policy still
  has a sleep idle timer, which no job used to run long enough to reach.
  Jobs that now do reach it lose the machine part-way through. The image
  should disable sleep/hibernate outright
  (`powercfg /x standby-timeout-ac 0` and friends) as part of the recipe.

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
  operator-supplied Win11 ISO exists AND validates it carries a UEFI
  (EFI) El Torito boot record (via `xorriso`, provided by the dev
  shell). A BIOS-only ISO is rejected up front: it boots to nothing on
  the UEFI q35 domain (OVMF drops to the UEFI shell and virt-install
  stalls ~90 min). Supply a stock Microsoft ISO, which is UEFI-bootable.
- `build-autounattend-iso.sh` — wraps autounattend.xml,
  `../lib/provision-git.ps1`, the pinned PortableGit archive and an
  optional first-boot.ps1 as a CD-ROM ISO9660+Joliet image.
- `finalize-golden.sh` — verifies the domain is in the expected
  state, detaches install ISOs, marks autostart.
- `../lib/provision-git.ps1` — shared with `windows-arm-base`. Installs
  Git for Windows (PortableGit) and extends the **machine** PATH. Owns
  the version + SHA-256 pin for both recipes. Also runnable standalone
  over SSH against an already-built golden.
- `../lib/fetch-portable-git.sh` — host-side cache + checksum verify for
  the pinned PortableGit archive (`--arch x64|arm64`).

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
