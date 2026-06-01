# windows-arm-base — UTM Windows-on-ARM golden bundle recipe (M3)

This recipe produces a golden UTM bundle named **`repro-windows-arm-base`**
that the M3 `UtmBackend` clones per gate. The Nim backend
(`src/vm_harness/backends/utm.nim`) consumes already-baked bundles; this
directory is the documentation + scripts that produce one.

## What you get

A registered-with-UTM `.utm` bundle containing:

- Windows 11 ARM64 Insider Preview (latest available at recipe-run
  time; URL resolved via UUP Dump per Microsoft's no-login policy for
  Insider builds).
- `admin` user, password `repro-windows-arm`, auto-logon enabled.
- OOBE skipped via autounattend.xml (no first-run dialogs, no
  Microsoft account, no telemetry prompts).
- Windows OpenSSH server (`Server` capability) enabled and set to
  start automatically on boot.
- Firewall rule allowing inbound TCP/22.
- WinRM disabled (we use SSH, not PSRemoting, to mirror the cross-
  backend transport contract).
- UTM guest tools (`spice-guest-tools` for ARM) installed so
  `utmctl ip-address` returns the guest IP without DHCP lease parsing.

## When to (re-)run this recipe

- **First time on a new Mac** — once you've installed UTM
  (`brew install --cask utm`), follow the build steps below to produce
  the golden bundle. Takes 30–60 minutes including ISO download,
  Windows install, OpenSSH config, and SysPrep.
- **Microsoft rotates the Insider Preview ISO URL** — the UUP Dump
  recipe regenerates a fresh ISO; re-running the recipe captures the
  newer build. The harness doesn't care which build is inside, just
  that the SSH contract is honored.
- **You want a customized golden** — pass `--bundle-name <custom>` to
  the recipe and override `goldenBundleName` on `newUtmBackend(...)`
  (or set `VMH_UTM_GOLDEN=<custom>` for the test suite).

## Build steps

The build is *interactive at the moment of UTM bundle creation* — UTM
doesn't have a fully-headless first-boot import path, so the recipe
documents the GUI steps where needed. The ISO assembly and
autounattend prep are fully scripted.

### 1. Prerequisites

```bash
# UTM (Mac app bundle + utmctl on PATH).
brew install --cask utm

# QEMU (for the autounattend ISO assembly via mkisofs and for the
# scripted first-boot install path via qemu-system-aarch64 -accel hvf).
# Already provided by the vm-harness flake's dev shell on macOS.
nix develop  # from the vm-harness repo root, OR:
brew install qemu cdrtools
```

### 2. Download a fresh Windows 11 ARM Insider Preview ISO

Microsoft's official ARM ISO links rotate; UUP Dump is the documented
no-login path. The helper script wraps the standard UUP recipe:

```bash
./fetch-iso.sh
# Writes: ./build/win11-arm-insider.iso
```

If you already have a Windows 11 ARM ISO on disk, set `VMH_WIN11_ARM_ISO`
to its path and the rest of the recipe will use it directly.

### 3. Assemble the autounattend ISO

```bash
./build-autounattend-iso.sh
# Writes: ./build/autounattend.iso
```

This wraps `autounattend.xml` (the SysPrep override file in this
directory) as an ISO that UTM can attach as a second CD-ROM. Windows
Setup looks for `autounattend.xml` on every attached removable media
at first boot and applies it automatically.

The autounattend.xml mirrors the Hyper-V harness's Panther-override
pattern from
[`reprobuild/tools/hyperv-m69-system/provision-base-vm.ps1`][hyperv-script]:
admin user, locale flags, OOBE skip, OpenSSH server install via the
`FirstLogonCommands` hook.

[hyperv-script]: ../../../reprobuild/tools/hyperv-m69-system/provision-base-vm.ps1

### 4. Create the UTM bundle and run first-boot install

```bash
./create-utm-bundle.sh
```

This writes a `.utm` bundle skeleton (`./build/repro-windows-arm-base.utm`)
configured for:

- 4 vCPU, 8 GB RAM, 64 GB disk.
- ARM64 architecture, `virt` machine, `hvf` accelerator.
- Two CD-ROM drives (Windows ISO + autounattend ISO).
- User-mode networking with the UTM guest agent attached.

Then opens UTM via `open -a UTM ./build/repro-windows-arm-base.utm`. The
first boot runs Windows Setup unattended (5–20 minutes); the
autounattend.xml drives the install through to OpenSSH-server enabled
and the admin user auto-logging in. **You can watch the install
through the UTM console window or simply wait** — the recipe is
complete when the guest reaches the desktop and the `repro-install-
done` marker file appears at `C:\Windows\Temp\repro-install-done`.

### 5. SysPrep and capture

Once Windows is installed and OpenSSH is up, log in as `admin` (the
auto-logon should already have you there) and run:

```powershell
# Inside the guest (use the UTM console; SSH also works).
& C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown /mode:vm /unattend:C:\repro-sysprep.xml
```

`repro-sysprep.xml` is shipped on the autounattend ISO and was copied
to `C:\` by the FirstLogonCommands hook. The guest shuts down once
SysPrep finishes (10–20 minutes).

### 6. Mark the bundle as the golden

```bash
# From the host.
./finalize-golden.sh
```

This:

- Removes the CD-ROM ISOs from the UTM bundle (so per-gate clones boot
  straight into Windows with no Setup-disk reference).
- Renames the registered VM to `repro-windows-arm-base` so
  `utmctl status repro-windows-arm-base` succeeds.
- Sets the UTM bundle's auto-snapshot config so first-boot of any
  clone uses the post-SysPrep `oobeSystem` pass (admin user is
  recreated at first boot of every clone, but the OpenSSH service +
  firewall rule survive — they were configured via the autounattend's
  `specialize` pass which runs before generalize, so it sticks).

Verify:

```bash
utmctl list   # repro-windows-arm-base should appear with status 'stopped'
utmctl status repro-windows-arm-base
```

### 7. Run a smoke test

```bash
# From the vm-harness repo root.
nimble test
```

The M3 verification tests (`tests/e2e/t_vm_harness_utm_windows_arm_smoke.nim`
and `tests/e2e/t_vm_harness_utm_windows_dism_works_under_prism.nim`)
should now run end-to-end against the golden — clone, boot, SSH in,
exec hostname / DISM, PASS, delete the ephemeral.

## Total wall-clock

Rough budget on Apple M2 Pro / 16 GB RAM:

| Step | Time |
|---|---|
| Download Windows 11 ARM ISO | 5–15 min (depends on UUP Dump backend + network) |
| Assemble autounattend ISO | <1 min |
| Create UTM bundle | <1 min |
| Windows install (autounattend) | 15–30 min |
| OpenSSH install (FirstLogonCommands) | 1–3 min |
| SysPrep generalize | 10–20 min |
| Finalize | <1 min |
| **Total** | **30–60 min** |

The good news: this is a one-time cost per Mac. After the golden is
built, every per-gate revert is the harness's ≤20s clone budget.

## Files in this directory

- `README.md` — this document.
- `autounattend.xml` — the SysPrep answer file. Single source of truth
  for admin credentials, locale, OOBE skip flags, FirstLogonCommands
  (OpenSSH install, firewall rule, repro-install-done marker).
- `repro-sysprep.xml` — the shutdown-after-generalize unattend.xml
  that's copied onto `C:\` by autounattend's FirstLogonCommands and
  used by the step-5 SysPrep invocation.
- `fetch-iso.sh` — downloads a fresh Windows 11 ARM ISO via UUP Dump.
- `build-autounattend-iso.sh` — wraps `autounattend.xml` +
  `repro-sysprep.xml` as a CD-ROM ISO.
- `create-utm-bundle.sh` — assembles the UTM bundle skeleton and opens
  UTM so the install can proceed.
- `finalize-golden.sh` — strips ISOs, renames to `repro-windows-arm-base`.

All scripts are POSIX `sh` (`#!/usr/bin/env bash` for the bash-isms)
and self-contained; they accept `--help` for usage.

## Why no fully-automated end-to-end build?

UTM's CLI doesn't expose `import .utm bundle from JSON config`; bundle
creation is a GUI operation. The recipe scripts do everything they
can outside of UTM (ISO download, autounattend assembly, post-install
finalize) and document the GUI step (open the bundle) explicitly.

A future enhancement would be to drive QEMU directly (skipping UTM for
the install phase) and only import the finished `.qcow2` into a UTM
bundle at the end. That's tracked under the M3 "Outstanding Tasks"
section of the campaign milestone file.
