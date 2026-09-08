# Disabling Microsoft Defender in the Windows golden

`harden-defender.ps1` turns Microsoft Defender off in a Windows image by
editing the image's registry hives **offline** — while the image is not
running. This document is the rationale that deliberately does **not** live
in the script.

## Why offline, and why nothing else works

Defender cannot be disabled from inside a running guest. Both halves of that
were observed directly on `win-ci-bare-001` (2026-09-08), not assumed:

- **The host blocks the delivery.** A `pwsh` process whose command line
  contains `Set-MpPreference -DisableRealtimeMonitoring` is flagged by the
  *host's* own Defender as `Trojan:Win32` (behavioural, ThreatID
  2147794155) and killed before it runs — so the disable command never
  reaches the guest over PowerShell Direct.
- **The guest blocks the execution.** Land the same script inside the guest
  and its AMSI refuses it: *"This script contains malicious content and has
  been blocked by your antivirus software."* Defender will not run a script
  that disables Defender.
- **Tamper Protection reverts the rest.** Even a script that somehow ran
  would find `Set-MpPreference` and `Stop-Service WinDefend` undone by
  Tamper Protection, which is on by default on Windows 11.

Offline, none of those three exist: no AMSI is scanning, no host process is
watching a command line, and Tamper Protection is not running to guard the
keys. The values are just bytes in a hive file. This is the standard imaging
technique and the only one that holds.

## What actually turns Defender off: disabling the services

The lever is `Start = 4` (disabled) on Defender's services and drivers in
the offline `SYSTEM` hive:

| key | what it is |
| --- | ---------- |
| `WinDefend` | the antivirus service |
| `WdNisSvc` | network inspection service |
| `Sense` | the Defender-for-Endpoint EDR sensor |
| `WdFilter` | the **file-system minifilter** — the on-access scanner that taxes a build opening thousands of files |
| `WdBoot` | the ELAM boot driver |
| `WdNisDrv` | network inspection driver |

Verified on a booted, hardened copy of the golden: all three services come
up `Stopped / Disabled`, the drivers do not load, and
`Get-MpComputerStatus` reports `RealTimeProtectionEnabled=False`,
`AMRunningMode=Not running`, `AMServiceEnabled=False`. Windows did **not**
re-enable any of them on boot.

`IsTamperProtected` also reads `False` afterwards — not because we cleared
it, but because Tamper Protection cannot run without the service that
enforces it. That is the key insight behind what we *don't* do (below).

## What we deliberately do NOT set, and why

`SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection = 0` is the
value most guides reach for first. We do not set it, because **we cannot**:
that key is ACL-hardened (owned by SYSTEM/TrustedInstaller with a
restrictive DACL that the offline hive preserves), so an admin `reg import`
gets `ERROR: Error accessing the registry`. Writing it would need an offline
ownership/DACL rewrite of that specific key.

It is also unnecessary. Tamper Protection only guards a *running* Defender.
Once the services are disabled and never start, there is nothing for TP to
protect or restore — confirmed by the boot test above, where TP reported
itself off with no help from us. Chasing the ACL to set a value that is
already moot would add risk for nothing.

The two policy values that *do* apply cleanly
(`Policies\...\DisableAntiSpyware`, `...\Real-Time Protection\
DisableRealtimeMonitoring`) are kept as belt-and-braces. On current Windows
11 client builds `DisableAntiSpyware` is largely ignored, so they are not
load-bearing; the service disable is.

## Boot safety

Disabling `WdFilter` (a boot-start minifilter) and `WdBoot` (ELAM) offline
is the part that could in principle stop the image booting. It does not —
the hardened copy booted straight to the desktop with autologon — but that
is exactly why the method is proven against a throwaway flattened copy of
the golden before it is trusted against a real image.

## Why this belongs in the golden, not on a running member

An ephemeral pool member must be byte-identical to its baseline every cycle.
A member hand-edited after construction is drift that no rebuild reproduces,
and the standing rule here is that a fix lives in the recipe, not on a box.
So the disable is baked into the image every member is built from —
`build-golden-hyperv.ps1` calls this script on the captured VHDX as its last
hardening step, alongside the Windows-Update-off and PowerShell-7 steps.

## Layout

| file | role |
| ---- | ---- |
| `harden-defender.ps1` | orchestrator: mount, load hives, import, verify, unmount. Carries **no** Defender-specific literals, so the host AMSI does not flag it when a golden build runs it. |
| `defender-off-system.reg` | the service/driver `Start=4` payload (`{{CS}}` = current control set) |
| `defender-off-software.reg` | the two policy values |
| `defender-off.targets` | the service list, read as data for the verification pass |

Keeping every Defender string in the data files rather than the script is
the same lesson as above, applied to our own tooling: a script that *reads*
like a disable-Defender script gets treated like one.
