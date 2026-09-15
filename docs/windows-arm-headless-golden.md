# Headless Windows ARM64 golden build

## Overview

`qemu-windows-arm` can *consume* a Windows ARM64 golden — a directory
containing `windows.qcow2` — but nothing in this repository can *produce*
one. `provisionBaseline` only validates that the directory exists and holds
that file ([`qemu_windows_arm.nim:497`](../src/vm_harness/backends/qemu_windows_arm.nim)),
and the recipe under
[`guest-recipes/windows-arm-base/`](../guest-recipes/windows-arm-base/)
builds a **UTM bundle** through a GUI step, not a qcow2. The golden that the
`eph-win-arm64` CI lane ran on was therefore promoted by hand, exists in no
build graph, and had no backup.

That artifact was lost between 2026-07-20 and 2026-08-24. The lane has been
down since, and cannot be restored by any automated path. This document
specifies the missing one: drive the Windows ARM64 unattended install through
QEMU with no GUI and no UTM, so the golden is reproducible from the ISO plus
the checked-in answer files.

## Implementation Status

| Component | Status | Notes |
|---|---|---|
| `provisionBaseline` (validate existing golden) | ✓ | Already shipped; unchanged by this work. |
| Headless install boot — argument vector | ✓ | `buildQemuWindowsArmInstallArgs`. |
| Headless install boot — orchestration | ✓ | `buildWindowsArmGolden`; UEFI staged by `stageGoldenFirmware`. |
| Install-completion detection | ✓ | `waitForInstallSentinel` over the `repro-install-done` sentinel. |
| Rebuild safety guard (never build in place) | ✓ | `prepareGoldenBuildDir`. |
| Overlay backing-path symlink resolution | ✓ | Prerequisite for a safe flip; landed early with the guard. |
| Golden disk allocation | ✓ | `createGoldenDisk`. |
| Free-space precondition | ✓ | `checkGoldenBuildSpace`; floor refuses, comfort band warns. |
| Sysprep + generalize | ✓ | `runGuestSysprep` + `waitForGuestPowerOff` on the monitor socket. |
| Golden finalize | ✓ | `finalizeGoldenDir`: drops build leftovers, refuses a golden whose per-job boot would still reference the install media, then `validateWindowsArmVmDir`. |
| Golden promote (pointer flip) | ☐ | Phase 3; belongs with the nix-side wiring so the flip is a declared, not a hand, operation. |
| Previous-golden retention + reclaim | ☐ | Phase 3. Gated on the per-instance advisory lock. |
| Build manifest | ✓ | `writeGoldenManifest`: ISO SHA-256, recipe commit + dirty flag, answer-file digests, timestamp, vm-harness version. |
| `vm-harness provision --backend qemu-windows-arm` entrypoint | ☐ | Phase 3. |
| Nix-side golden provisioning on m3 | ☐ | Phase 3; `metacraft-labs/infra`. |
| Retire the UTM recipe path | ☐ | Phase 4, once Phase 3 has produced a golden twice. |

## Why this is tractable now

The per-job run path is *already* fully headless. `qemuBaseArgs`
([`qemu_windows_arm.nim:336`](../src/vm_harness/backends/qemu_windows_arm.nim))
launches with `-accel hvf`, `-display none`, UEFI pflash firmware, an
`swtpm` TPM 2.0 device, `-serial file:`, a QMP/monitor socket, and user-mode
networking with `hostfwd` for SSH. Every primitive the install needs is in
place and proven — the golden build reuses that argument vector with three
changes:

1. a freshly created empty `windows.qcow2` instead of a CoW copy;
2. the Windows ISO and the autounattend ISO attached as CD-ROMs;
3. `-no-reboot` dropped, because a Windows install reboots several times.

The recipe inputs are likewise already checked in and independent of UTM:
`autounattend.xml`, `repro-sysprep.xml`, `provision-openssh.ps1`, and the
`build-autounattend-iso.sh` that packages them together with the staged
OpenSSH and VirtIO NetKVM payloads. Only the *driver* is missing.

There is also a working precedent in this repo. The Linux libvirt backend
performs the equivalent install headlessly through `virt-install` (see
[`m4-libvirt.md`](m4-libvirt.md), Phase A). This work is that same shape for
the macOS/ARM host, minus libvirt, which does not exist on Darwin.

## Goals

- A golden is reproducible from three inputs: the Windows ARM64 ISO, the
  checked-in answer files, and a pinned VirtIO/OpenSSH payload set.
- The build runs unattended on a macOS ARM host with no GUI, no `utmctl`,
  and no console session — so CI and a remote operator over SSH can both
  run it.
- Failure is loud and diagnosable: every phase has a bounded timeout and
  leaves the serial log and QEMU log behind.
- The produced golden is byte-identical in *shape* to what
  `validateWindowsArmVmDir` already expects, so the consuming path needs no
  change.

## Non-goals

- Building the Windows ISO itself. It stays an operator-supplied input;
  Microsoft's download is manual and unversioned in any usable way.
- Reproducible-to-the-bit output. A Windows install is not deterministic.
  The goal is *reproducible procedure*, not a fixed hash.
- Replacing the x64 libvirt path on `high-mem-server`, which already works.
- UTM parity. The UTM recipe is retired by Phase 4, not preserved.

## Golden lifecycle: a read-only base under live overlays

The golden is not a template that gets copied. In the default disk mode
(`overlay`, see `qwaDiskMode`) `createEphemeralOverlay` creates a thin
`overlay.qcow2` whose **qcow2 backing file is the golden's
`windows.qcow2`**. The golden is never copied; it is shared read-only by
every concurrent instance, and only the overlay records guest writes. Clone
mode — a full per-instance copy — is a fallback behind
`VMH_QEMU_WINDOWS_ARM_DISK_MODE=clone`.

That makes one thing a hard constraint on this work:

> **A golden must never be rebuilt in place.** qcow2 does not validate that a
> backing file still holds the content an overlay was created against. Writing
> a new `windows.qcow2` at a path some overlay still references does not fail
> — the guest silently reads a different disk underneath its own writes.
> Every live instance, and every orphaned instance directory, is exposed.

So a rebuild is an *addition*, not a replacement:

1. Build into a **new versioned directory**, `golden/win-arm-runner-<build-id>/`,
   which is inert until anything points at it.
2. Flip `golden/win-arm-runner` — a symlink — to the new build. This selects
   what *subsequent* instances get; it must not disturb existing overlays.
3. Retain the previous golden until no overlay references it. The existing
   per-instance advisory lock (`qwaInstanceLockPath`, which `prune` already
   uses to distinguish a live instance from an orphan) is the signal for
   when that is true.

Two consequences worth stating plainly:

- **Overlays must record the resolved versioned path, not the symlink.**
  `validateWindowsArmVmDir` returns `absolutePath(dir)`, which does not
  resolve symlinks, so an overlay created through the pointer would record
  the pointer — and flipping it would corrupt exactly the instances this
  scheme exists to protect. Instance creation has to resolve the symlink
  before handing a backing path to `qemu-img create`.
- **This supplies the rollback the "no fallback" risk asked for.** Retaining
  the previous golden for the lifetime of its overlays means the
  last-known-good build is already on disk. Reverting a bad recipe change is
  a symlink flip, not a rebuild.

Periodic refreshes — Windows updates, a newer runner toolchain — are the
normal case for this path, not an exceptional one.

## Design

A new `buildBaseline` capability on the `qemu-windows-arm` backend, driven by
a new `vm-harness provision --backend qemu-windows-arm` subcommand.

### Phase 1 — headless install

```
vm-harness provision --backend qemu-windows-arm \
  --baseline win-arm-runner \
  --output-dir <golden-dir> \
  --windows-iso <path> \
  --autounattend-iso <path>
```

1. `qemu-img create -f qcow2 <golden-dir>/windows.qcow2 <size>`, where
   `<golden-dir>` is a fresh versioned directory — never an existing golden
   (see the lifecycle constraint above).
2. Stage UEFI vars from the firmware template, as `revertToBaseline`
   already does.
3. Start `swtpm`, then QEMU with `qemuBaseArgs` plus both ISOs as
   `-drive if=none,media=cdrom` + `-device usb-storage`/`scsi-cd`, with
   `bootindex` ordering the install ISO ahead of the NVMe disk, and
   without `-no-reboot`. *(Incomplete as written — a fourth change is
   needed: a `usb-kbd`, plus a bounded keypress injected on the monitor.
   See "As implemented", departure six.)*
4. Poll for install completion by SSHing to the forwarded port and testing
   for `C:\Windows\Temp\repro-install-done` — the sentinel
   `autounattend.xml` already writes from `FirstLogonCommands` after
   OpenSSH and NetKVM are confirmed up. ~~This reuses `waitForSshReady`.~~
   *(Superseded — see "As implemented" below. It deliberately does not:
   OpenSSH comes up partway through the chain, so a guest that answers SSH
   may still be installing Git, PowerShell 7 and NetKVM.)*
5. Bounded by a single overall deadline (default 90 min; the README budgets
   15–30 min for install plus 1–3 for OpenSSH, so this is generous).

The install boot is where the answer file does all the real work, so Phase 1
carries almost no new Windows-side logic.

### Phase 2 — sysprep and finalize

6. ~~Copy `repro-sysprep.xml` to `C:\`~~ *(superseded — `autounattend.xml`
   already copies it there from the answer-file ISO; see "As implemented")*
   and invoke
   `sysprep /generalize /oobe /shutdown /unattend:C:\repro-sysprep.xml`
   over SSH.
7. Wait for the guest to power off, observed through the QMP socket rather
   than SSH, since SSH dies with the guest.
8. Kill `swtpm`, drop the CD-ROM drives, and leave `windows.qcow2` plus the
   firmware vars in `<golden-dir>`.
9. Validate the result through the existing `validateWindowsArmVmDir` so the
   build cannot produce something the consuming path rejects.

Sysprep `/generalize` is load-bearing and must not be skipped: without it
every ephemeral clone shares one machine SID. That is the same property the
x64 lane gates on in `metacraft-labs/infra`'s
`checks/t_windows_sysprep_golden.sh`, and the ARM lane should gain the
equivalent check.

### Phase 3 — make it callable

- Expose the subcommand in `cli.nim` alongside the existing `provision`.
- In `metacraft-labs/infra`, add a golden-provisioning path so
  `/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner` is
  populated by a documented command rather than by hand. The activation
  script currently `install -d`s that directory and nothing fills it
  ([`services/ephemeral-runner-host/darwin.nix:699`](https://github.com/metacraft-labs/infra)).

## Verification

| Gate | Layer | Runs where |
|---|---|---|
| Argument-vector unit test: install boot attaches both ISOs, orders bootindex, and omits `-no-reboot` | unit | anywhere |
| `qemu-img`/`swtpm` invocation shape | unit | anywhere |
| Golden shape accepted by `validateWindowsArmVmDir` | unit | anywhere |
| Full install → sysprep → golden | host e2e, opt-in | macOS ARM host with the ISO |
| Two clones of the golden have distinct machine SIDs | host e2e, opt-in | macOS ARM host with a golden |

The unit layer must not claim coverage of the e2e layer. Following this
repo's existing convention, a missing ISO or a non-macOS host **skips with an
explicit message** rather than passing quietly.

### As implemented

Both tiers carry the same greppable gate name, `t_qemu_windows_arm_golden_build`:

| Tier | File | Wired into |
|---|---|---|
| unit (runs anywhere) | `tests/unit/t_qemu_windows_arm_golden_build.nim` | `scripts/run-tests.sh`, `repro.nim` |
| host (opt-in) | `tests/e2e/t_qemu_windows_arm_golden_build_host.nim` | `scripts/run-host-tests.sh` |

The unit tier drives the *whole* orchestration — install wait, sysprep,
power-off, finalize, manifest — against a fake QEMU that binds the real
forwarded SSH port and serves a real unix monitor socket, so the port-claim
handshake and the monitor conversation under test are genuine and only the
guest is absent. It deliberately does not claim the host tier's coverage: no
unit test can say that Windows Setup accepted the answer file, that HVF
tolerated the reboot sequence, or that `/generalize` re-minted the SID.

The host tier requires `VMH_WINDOWS_ARM_GOLDEN_HOST_TEST=1`,
`VMH_WINDOWS_ARM_ISO` and `VMH_WINDOWS_ARM_AUTOUNATTEND_ISO`, and names each
missing one in the skip message.

Six points where the implementation departs from the text above, all
deliberate:

- **It is the monitor socket, not QMP.** `qwaMachineArgs` publishes
  `-monitor unix:…` (the human monitor), not `-qmp`. Power-off is therefore
  read from an `info status` reply rather than a QMP event. Adding a QMP
  socket would change the per-job argument vector that is already deployed,
  for no gain: the property that matters — *observed off-band from SSH,
  because SSH dies with the guest* — is the same either way. The fallback arm
  is also part of the contract: QEMU's default action on a guest power-off is
  to **exit**, so a vanished socket plus a gone process is the same event seen
  from outside, and `guestPoweredOff` treats it as such.
- **Sysprep is launched so as to outlive the SSH session, and carries
  `/mode:vm`.** `/shutdown` powers the guest off underneath the SSH session
  that issued it, and a generalize runs 10–20 minutes, so a session-bound
  invocation is one hangup away from a half-generalized disk that still looks
  like a golden. `buildSysprepRemoteCommand` creates it through
  `Win32_Process.Create` and lets go — *not* `Start-Process`, which does not
  escape Windows OpenSSH's per-session job object; see "What the first real
  host run found", item 3.
  `/mode:vm` matches the invocation the recipe README documents as the one
  that produced a working golden; it is sound here precisely because every
  instance boots the identical machine shape this backend builds.
- **UEFI firmware is staged, not assumed.** A fresh golden directory has no
  firmware, and `qemuFirmwareArgs` resolves it from the VM directory, so
  `stageGoldenFirmware` copies a code/vars pair in — giving the build its own
  writable variable store, since Windows Setup writes its boot entry there.
  `VMH_QEMU_FIRMWARE_DIR` *replaces* the well-known search list rather than
  being prepended to it.
- **Step 4 does not reuse `waitForSshReady`.** OpenSSH comes up *partway
  through* the `FirstLogonCommands` chain, so a guest that answers SSH may
  still be installing Git, PowerShell 7 and the NetKVM driver. Waiting on SSH
  would therefore declare an unfinished install finished, and sysprep would
  generalize a half-provisioned disk. `waitForInstallSentinel` waits for the
  sentinel the *last* FirstLogonCommand writes, and only once `sshd` is
  confirmed running — the one signal that means "finished".
- **The install boot needs a keyboard, and a keypress.** Found by MA4's
  first real host run on m3, 2026-09-15, and the reason this document's
  "three changes" was wrong. `\EFI\BOOT\BOOTAA64.EFI` on a Windows install
  ISO is `cdboot.efi`, which prints *"Press any key to boot from CD or
  DVD"*, waits about five seconds and returns `EFI_TIMEOUT` if no key
  arrives. The machine shape here has **no input device at all** —
  `-display none`, and `-serial file:` is output-only — so the prompt could
  never be answered. Measured symptom, with nothing else wrong anywhere:

  ```
  BdsDxe: starting Boot0001 "UEFI QEMU QEMU USB HARDDRIVE 1-…"
  Error: Image at 0023C314000 start failed: Time out
  BdsDxe: failed to start Boot0001 …: Time out
  BdsDxe: loading Boot0004 "EFI Internal Shell"
  Shell>
  ```

  Windows Setup never ran; the build then sat out its whole deadline and
  blamed the answer file. `buildQemuWindowsArmInstallArgs` now attaches a
  `usb-kbd` to the xHCI controller it already creates, and
  `answerInstallMediaKeyPrompt` injects `sendkey ret` on the **monitor
  socket** — the same socket power-off is read from.

  Stopping is as load-bearing as starting. That same prompt timing out is
  what makes Setup's *own* reboots fall past the still-first install media
  and onto the disk it is installing to (measured: the media is still ahead
  of the disk in `BootOrder` after Setup's first reboot). A keyer that never
  stopped would trade "the install never starts" for "Setup restarts from
  the ISO forever". So the window ends at the first of: the target qcow2
  growing past `QwaInstallProgressBytes` (Setup is writing, so the prompt is
  answered), `GoldenBuildSpec.keyPressWindowSec` (180 s by default; the
  prompt appears 20–25 s in), and the overall build deadline.

  The per-job argument vector is deliberately untouched — it is already
  deployed on m3, it boots an installed disk with no prompt to answer, and
  the unit gate asserts it gains neither the keyboard nor the xHCI.

- **Step 6 does not copy `repro-sysprep.xml` to `C:\`.** `autounattend.xml`
  already does it from the answer-file ISO (`FirstLogonCommands`, Order 6),
  so the harness copying it again would be a second source of truth for a
  path that must match `/unattend:`. The gate asserts instead that the two
  sides agree: the constant the harness names is the destination the recipe
  copies to.

### Promotion is not implemented here, and that is on purpose

`buildWindowsArmGolden` returns the path of a **validated, inert, versioned
directory**. It never writes `golden/win-arm-runner`, and there is no
"promote" verb in this repository.

That is the shape Phase 3 needs. Promotion is a pointer flip plus a retention
decision about the previous golden, and both are configuration, not a host
action: the build takes `--output-dir` (today `GoldenBuildSpec.buildDir`,
which the host gate reads from `VMH_WINDOWS_ARM_GOLDEN_OUT`), so a nix module
can point it at
`/private/var/lib/vm-harness/qemu-windows-arm/golden/win-arm-runner-<build-id>`
and own the symlink declaratively. Nothing in the build path requires an
operator to copy, rename or `install -d` anything.

The one step that cannot be declared away is the **ISO**: it stays an
operator-supplied input, pinned by hash in the manifest, because Microsoft's
download is manual and unversioned.

## What the first real host run found (m3, 2026-09-15)

Three defects, none of which any unit tier could have caught, and a fourth
correction to this document. Recorded here because every one of them reads
from the outside exactly like "the answer file is wrong", and each cost a
deadline to diagnose the first time. They surfaced strictly in sequence —
each one had to be fixed before the next became visible — which is the honest
shape of a first host run and worth expecting on the next platform.

1. **`cdboot.efi` waits for a keypress, and the machine had no keyboard.**
   Covered in full under "As implemented", departure six. Symptom:
   `failed to start Boot0001 …: Time out` and an EFI shell prompt, with
   Windows Setup never running at all.

2. **The OpenSSH firewall rule is `Private`-profile only.** With the
   keypress fixed, the install ran to completion: Windows installed, NetKVM
   came up on 10.0.2.15, `Add-WindowsCapability OpenSSH.Server` succeeded,
   Git and PowerShell 7 provisioned, and `C:\Windows\Temp\repro-install-done`
   — the sentinel this harness polls for — was written. The harness still
   could not reach the guest, and waited out its deadline against a finished
   install.

   The cause: the capability's own inbound rule (`OpenSSH-Server-In-TCP`) is
   scoped to the **Private** profile. QEMU's user-mode network is
   unidentified, so Windows classifies it **Public**, whose policy is
   `BlockInbound`. `sshd` was Running, `netstat` showed `0.0.0.0:22
   LISTENING`, and every SYN forwarded by `hostfwd` was dropped inside the
   guest. `provision-openssh.ps1` only created a rule *when none existed*, so
   on exactly this path it was a no-op. It now widens whatever rule is there
   to `Profile Any`, owns a rule of its own (`vmh-sshd-in-tcp22`), and
   **asserts** the result — an unreachable sshd must fail the provisioning
   step loudly rather than produce a golden nothing can log into.

3. **`Start-Process` does not detach sysprep from the SSH session.** With
   the firewall fixed, the install ran through, the harness logged in and
   launched `sysprep /generalize /oobe /shutdown /mode:vm`, and sysprep wrote
   four lines to `C:\Windows\System32\Sysprep\Panther\setupact.log` —
   `Sysprep mode [vm]`, then *"Beginning action execution from
   Cleanup.xml"* — and **died one second later**, generalizing nothing. The
   build then waited 20 minutes for a power-off from a process that no longer
   existed, with a perfectly installed guest sitting at its desktop.

   Windows OpenSSH puts every process of a session into a **job object** and
   terminates that job when the session ends. A `Start-Process` child stays
   inside the job, so "launched detached" was never true. Measured directly
   on the same guest, with a harmless long-running process instead of a
   20-minute generalize:

   | launch | survivors 2 s after the session closed |
   |---|---|
   | `Start-Process` | **0** |
   | `Invoke-CimMethod Win32_Process Create` | 1, still running 25 s later |

   `Win32_Process.Create` works because the WMI provider host creates the
   process, so it is in no session job at all. `buildSysprepRemoteCommand`
   now uses it and exits non-zero on a refused creation.

   The second half of the fix matters as much: a launch reporting success and
   a sysprep actually running are different facts, and only the first was
   ever checked. `sysprepTookHold` now confirms sysprep is still there
   (`QwaSysprepTakeHoldSec`, default 180 s) or that the guest has already
   powered off, so this failure costs ten seconds and names itself instead of
   consuming the whole deadline in silence.

4. **The framebuffer was not actually captured.** The Risks section below
   claimed it was. It could not have been: `-display none` renders nowhere,
   and nothing dumped it. A Windows guest writes nothing to the serial port
   once the firmware hands over, so on both failures above the serial log
   simply stopped and said nothing more. `captureGuestScreen` now dumps it
   through the monitor's `screendump` on every failure, into
   `<golden-dir>/screen.ppm`, and the failure message names it as the thing
   to read first. It is what turned the second diagnosis from a blind
   90-minute wait into a ten-second look at a desktop.

### Still open: a DXE spin on the boot after Setup's first reboot

Not fixed, and the reason MA4 has not yet produced an artifact. Two of five
runs hung on the firmware boot that follows Windows Setup's first reboot,
on inputs identical to the two runs that sailed past it. The firmware prints
its banner, does TPM init, prints `UsbBootExecCmd: Success to Exec 0x0 Cmd`
twice, and never reaches a boot option; the serial log then froze for 23
minutes and the target qcow2 for 30.

It is a **spin, not starvation** — the distinction matters because the first
read was "the host is loaded" and that was wrong. `info registers` over the
monitor shows the guest PC parked at one address (`0x23fd5de04`) for 25
seconds, and then cycling inside an **eight-byte window**
(`0x47695fac`/`0x47695fb4`): a polling loop in a DXE driver with no timeout
firing, most likely the USB/xHCI stack re-enumerating the two CD-ROMs now
that the NVMe disk also carries boot entries. `system_reset` on the monitor
does not clear it — the boot after the reset stalls at the same point.

Two things worth trying, in order:

1. Attach the install media over `virtio-scsi` rather than xHCI. EDK2 has
   `VirtioScsiDxe`, so the firmware can boot it, and it takes the suspected
   driver out of the path — but check first that Windows Setup can still see
   the media, since it has no in-box vioscsi driver.
2. A harness-side watchdog: reset a guest whose serial log *and* target disk
   have both been unchanged past a bound. Cheap, bounded, and it fits the
   rest of this design — but it is a workaround, not a fix.

**Measured, for the estimates this document carries.** Install peak on m3:
**16.4 GiB** of build-directory growth, not the estimated 50 GB — see the
free-space Decision below. Phase timings: media boot to first Setup write
~60 s; image applied and first reboot at ~6 min; desktop at ~16 min; NetKVM
installed at ~7.5 min after that reboot; `Add-WindowsCapability
OpenSSH.Server` took **8 minutes** on its own; sentinel written by ~16 min
after boot.

### Two traps the runs left behind, and what now stops them

Neither is a defect in the run; both are ways the *next* build could produce
an artifact that lies about itself. They are the same class as the artifact
this whole campaign exists to replace, so they are closed here rather than
left for the promotion work.

- **A failed build looks exactly like a golden.** MA3's contract
  deliberately retains a failed build's directory and logs for diagnosis, and
  MA4's five runs duly left **six** of them under
  `/private/var/lib/vm-harness/qemu-windows-arm/golden/`, 12–15 GB each
  (~68 GB total). Every one holds a `windows.qcow2`, because the build
  creates that empty as its *first* act — and `validateWindowsArmVmDir`, the
  check the consuming path used, asked for nothing else. All six would have
  been accepted as a baseline to boot CI jobs from.

  The disk is not an identification. `requireWindowsArmGolden` is now the
  admission check, and it additionally requires `golden-manifest.json`, which
  the build writes *last* and which is therefore a genuine completion marker.
  `provisionBaseline`, `revertToBaseline` and `buildWindowsArmGolden`'s own
  return value all go through it. `validateWindowsArmVmDir` survives as the
  purely structural "is there a disk here" question the overlay and clone
  paths ask of a directory something else already admitted.

  The six directories are **left in place** — they are not urgent, the host
  has ample space, and they are the diagnostic record for the open DXE spin.

- **A stale answer-file ISO would have poisoned the manifest.** Found before
  MA4's first run: `guest-recipes/windows-arm-base/build/autounattend.iso`
  was 7.6 MiB dated 2026-07-06, while `autounattend.xml`, `repro-sysprep.xml`
  and `provision-openssh.ps1` were from 2026-09-08 — it predated the
  Git-for-Windows, PowerShell-7 and credential-expiry changes entirely.

  That gap is structural, not a one-off: the manifest digests *both* the ISO
  it consumed and the *recipe files on disk*, and nothing regenerates the ISO
  when a recipe file changes, because `build/` is a gitignored artifact built
  by hand. A build from a stale ISO installs July's recipe and records
  September's. `staleAnswerIsoRecipeFiles` now refuses such a build **before**
  it spends an hour, naming the files and the rebuild command.

  It is a staleness *heuristic* — it compares modification times and cannot
  prove that an ISO rebuilt after an edit actually carries it. Proving that
  means reading the ISO's contents, which needs ISO tooling this path does
  not otherwise want; the durable fix is for the promotion work to build the
  ISO as a declared step of the build rather than leave it in `build/`.

## Risks

- **Windows setup is opaque when it fails.** A wrong answer file leaves a
  guest sitting at an OOBE prompt with no SSH and no console. Mitigation:
  the serial log is captured, the `ramfb` framebuffer is dumped through the
  monitor on failure (see `captureGuestScreen` — this was claimed here
  before it existed), and the overall deadline bounds the failure.
- **The install may need more reboots than HVF+UEFI tolerates.** Untested on
  this exact firmware/machine combination; Phase 1 is where that is found
  out.
- **~8 GB ISO plus a 40–60 GB qcow2** on a host already at 88% disk, shared
  with a live fleet. Addressed by the free-space precondition above, but the
  50 GB install-peak figure it rests on is an estimate until a build
  measures it.
- **A bad recipe change is caught by retention, not by a published copy.**
  Nothing is published, but the previous golden stays on disk until its
  overlays drain, so rollback is a symlink flip. That only holds if
  retention is actually implemented; without it a regressed build is a lane
  outage until the recipe is fixed. The host e2e gate remains the thing that
  should catch it first.
- **Silent corruption if the versioning is got wrong.** Rebuilding over a
  golden that still backs an overlay does not error — it produces guests
  reading a disk that no longer matches their writes. This is the highest
  severity failure mode in this work and the reason the build refuses to
  write into an existing golden directory at all.
- **Long feedback loop.** A full cycle is 30–60 minutes, so Phase 1 should
  land the argument construction behind unit tests before any host run.

## Decisions

**The recipe is the artifact.** ✓ Decided 2026-09-09. A golden is rebuilt by
applying the recipe to a base ISO; the built golden is never published or
pulled. There is no cached copy to fall back on, so the build path is the
*only* path and has to be dependable enough to be run on demand.

Two consequences follow, and they are requirements rather than preferences:

- The build must be **re-runnable**, which the versioned-directory scheme
  gives for free: each run writes a fresh directory and a failed run simply
  leaves one that nothing ever points at. A partially built golden is never
  adopted, because adoption only happens by an explicit pointer flip after
  validation.
- Each golden carries a **manifest** — ISO SHA-256, recipe commit, answer
  file digests, build timestamp, vm-harness version. Not for reproducibility,
  which the recipe provides, but so that a golden of unknown provenance is
  identifiable as one. The artifact that was lost had no way to say what it
  was built from.

The ISO itself remains the one operator-supplied input, pinned by hash.

**The build gates on free space, with two thresholds.** ✓ Decided
2026-09-09. A single threshold would have to choose between blocking builds
that would have succeeded and permitting ones that cannot, so the check
separates the two questions:

| Threshold | Default | Behaviour |
|---|---|---|
| Floor — the build cannot finish | `min(diskGB, 50) + 10` = **60 GB** | Refuse |
| Comfortable — a saturated fleet also fits | floor + **116 GB** = **176 GB** | Warn, proceed |

Derivation, biased pessimistic throughout:

- **50 GB install peak.** A Windows 11 ARM64 install lands around 25 GB, plus
  the component store before `/ResetBase`, a pagefile sized to guest RAM, the
  staged toolchain, and sysprep's working set. This was an *estimate* — the
  golden it would have been measured against was lost.

  **MEASURED on m3, 2026-09-15: 16.4 GiB**, sampled every 20 s over a full
  install through to the sentinel (`du -sk` of the whole build directory, so
  it includes the 128 MiB firmware pair and the TPM state; the qcow2 itself
  peaked at 16.3 GiB and then *shrank* as Setup trimmed). The estimate is
  pessimistic by 3x, which is the safe direction and is why it is left alone:
  the floor it produces (60 GB) still refuses only builds that genuinely
  cannot fit, and a `/ResetBase`-less component store on a future Windows
  release could close the gap. Anyone tempted to lower it should note this
  figure does not yet include `sysprep /generalize`'s own working set.
- **116 GB fleet peak**, from live scale-set limits and measured instance
  footprints: 2 macOS at ~36 GB, 3 Linux at ~8 GB, 2 Windows overlays at
  ~10 GB.
- The floor scales down with a smaller requested image, since a qcow2 cannot
  outgrow its requested size, and stops scaling up past the install peak,
  since the image stays sparse.

`VMH_QEMU_WINDOWS_ARM_MIN_FREE_GB` overrides the floor for an operator who
knows better than the estimate. An undeterminable free figure warns and
proceeds — refusing to build because a `statvfs` call failed would be worse
than the risk it guards.

For calibration: m3 measured 231 GB free with an idle fleet and 156 GB an
hour later with five instances running, which lands in the warn band. Free
space on that host moves by roughly the fleet peak over a day, which is the
reason the second threshold exists at all.

## Assumptions

- The Windows ARM64 ISO remains operator-supplied and is validated by hash,
  not re-downloaded by the harness.
- `swtpm`, `qemu-system-aarch64`, and `sshpass` stay available through the
  Nix-provided environment, as they are today on m3.
- The existing `autounattend.xml` is correct — it produced a working golden
  before. If Phase 1 disproves that, the answer file becomes part of this
  work rather than an input to it.
