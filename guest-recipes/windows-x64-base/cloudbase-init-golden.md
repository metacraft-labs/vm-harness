# Cloudbase-init golden for ephemeral GARM runners (M3)

This recipe extends the `windows-x64-base` golden
(`/storage/iso/golden-win11-post-install.qcow2`) into a
**cloudbase-init-enabled** golden
(`/storage/iso/golden-win11-cloudbase.qcow2`) that ephemeral GARM runners
clone per job. On first boot a fresh clone consumes an INJECTED config-drive
(cloudbase-init ConfigDrive datasource) carrying GARM's Windows JIT bootstrap,
fetches the JIT/registration material from GARM's metadata endpoint
(per-instance JWT), and launches the actions runner via `Runner.Listener`
(the `run.cmd --jitconfig` path).

This is the golden the M3 gate `t_windows_golden_jit_boot` boots (and the M1
provider clones once `services.garm.providers.vmharness` is enabled with a
real `poolDir`).

## What's in the golden

Built incrementally from the base golden (a CoW overlay off a COPY — the base
golden is NEVER mutated in place; it is the live backing file of the running
`windows-runner-001`):

1. **cloudbase-init** (v1.1.6, `CloudbaseInitSetup_x64.msi`) installed silently
   with `RUN_SERVICE_AS_LOCAL_SYSTEM=1`, configured for:
   - the **ConfigDrive** metadata service
     (`cloudbaseinit.metadata.services.configdrive.ConfigDriveService`), and
   - the **UserData** plugin
     (`cloudbaseinit.plugins.common.userdata.UserDataPlugin`),
   so a `config-2`-labelled config-drive (`openstack/latest/user_data`) is
   consumed + run on first boot. Service startup type = Automatic.
2. **The actions runner** staged at `C:\actions-runner`
   (`actions-runner-win-x64-<ver>.zip` extracted; `config.cmd`, `run.cmd`,
   `bin\Runner.Listener.exe` present) so no per-job download is needed.
3. The runner's transient state (`.runner`/`.credentials`/`.service`/`_diag`)
   is REMOVED so the golden ships a clean runner dir.

## Build steps (what produced the current golden)

On the runner host (has `/dev/kvm`, `qemu-img`, `virsh`, the base golden):

```bash
# 1. CoW copy of the base golden (does NOT touch the original).
qemu-img create -f qcow2 -b /storage/iso/golden-win11-post-install.qcow2 \
  -F qcow2 /storage/scratch/inspect.overlay.qcow2

# 2. Boot the copy as a throwaway domain (UEFI/OVMF, virtio, virbr0),
#    distinct from windows-runner-001. SSH in (admin / repro-windows-x64).

# 3. In the guest:
#    - download + silently install cloudbase-init (RUN_SERVICE_AS_LOCAL_SYSTEM=1)
#    - write conf/cloudbase-init.conf (ConfigDrive datasource + UserData plugin,
#      see cloudbase-init.conf in this dir)
#    - download + extract the actions runner to C:\actions-runner
#    - remove any .runner/.credentials/_diag; set cloudbase-init Automatic

# 4. Shut the guest down cleanly (Stop-Computer -Force).

# 5. Flatten the overlay + base into a STANDALONE golden (reads both
#    read-only; produces an independent qcow2 with no backing chain):
qemu-img convert -O qcow2 -c /storage/scratch/inspect.overlay.qcow2 \
  /storage/iso/golden-win11-cloudbase.qcow2

# 6. Discard the scratch overlay.
```

The companion `cloudbase-init.conf` in this directory is the exact config
written into the golden.

## Sysprep `/generalize` — the production golden

The **non-generalized** golden (`golden-win11-cloudbase.qcow2`) shares the base
golden's machine SID + hostname across clones (both the M3 clones and the
running `windows-runner-001` report hostname `REPRO-N226DFJUD`). For the M3
MECHANISM proof that is fine — cloudbase-init keys "have I run" on the per-job
config-drive instance-id, so it runs fresh on every clone, and the runner is
`--ephemeral`. But at fleet scale, duplicate machine SIDs risk AD / telemetry /
WSUS collisions, so a **production** golden must be `sysprep /generalize`d so
each clone gets a fresh SID + hostname.

The distinct-identity gate
(`tests/e2e/windows-sysprep/run-sysprep-identity-gate.sh`) boots two clones of
the generalized golden and asserts their machine SIDs and hostnames differ
while cloudbase-init still consumes the injected config-drive.

> **STATUS (2026-07-10, FU5): RESOLVED — the generalized golden is
> gate-passing.** The blocker below is fixed by the component-store repair
> (`DISM /ResetBase`) and the whole procedure is now captured as a reproducible
> script, [`build-sysprep-golden.sh`](build-sysprep-golden.sh), which produces
> the side artifact `/storage/iso/golden-win11-cloudbase-sysprepped.qcow2`
> (NEVER overwriting the live golden). Two CoW clones of that artifact complete
> OOBE and report **distinct machine SIDs + hostnames** via the distinct-SID
> gate (`tests/e2e/windows-sysprep/run-sysprep-identity-gate.sh`, wired into
> infra as `just test-windows-sysprep-golden`).
>
> ORIGINAL BLOCKER (2026-07-04): the first `/generalize` succeeded and captured
> cold, but every CoW clone failed Windows mini-setup at the **specialize** pass
> with the modal *"Windows could not finish configuring the system. To attempt
> to resume configuration, restart the computer."* (deterministic — a reboot
> showed the same dialog), so the clone never completed OOBE / networks. Root
> cause, from the clone's `C:\Windows\Panther\setupact.log`: during specialize
> CBS tried to finalize the removal of Feature-on-Demand packages that
> generalize deprovisioned (`Microsoft-Windows-Kernel-LA57-FoD`,
> `Microsoft-OneCore-DirectX-Database-FOD`) but hit
> `ERROR_NOT_FOUND` / `CbsExecuteStateFailed` / *"Failed to commit CSI
> transaction … Component reboot required, package changes need to be pended"*.
> This was a **pre-existing component-store inconsistency in the base golden**
> (an orphaned incomplete CBS session `SessionsPending\…_3389271126` that also
> caused the reserved-storage sysprep-validation lock in step 3), which
> generalize turned into un-committable pending FoD-removal transactions.
>
> THE FIX (load-bearing, now in the script): on a fresh copy, **repair the
> component store BEFORE generalize** — `DISM /Online /Cleanup-Image
> /StartComponentCleanup /ResetBase` (the `/ResetBase` is the load-bearing flag:
> it finalizes the pending session and drops superseded FoD payloads; plain
> `StartComponentCleanup` did NOT clear it), then clear the reserved-storage
> servicing scenario, then `sysprep /generalize /oobe /shutdown /quiet` with the
> re-arm unattend. With the store repaired, generalize no longer creates
> un-committable transactions and the clones specialize cleanly through OOBE.

### Procedure (what produced the sysprepped golden)

Run on the KVM host against a **COPY** of the golden — never mutate the golden
in place, and (critically) **capture while the guest is shut down, right after
`sysprep … /shutdown`, BEFORE any boot**. Booting a generalized image runs OOBE
and CONSUMES the generalize (the result is a re-specialized, non-reusable
image), so the golden must be captured cold.

```bash
# 1. Full standalone COPY of the golden (do NOT touch the original).
qemu-img convert -O qcow2 /storage/iso/golden-win11-cloudbase.qcow2 \
  /storage/scratch/sysprep2-work.qcow2

# 2. Boot a throwaway domain off the copy (UEFI/OVMF, virtio-net on virbr0,
#    distinct from windows-runner-001). SSH in (admin / repro-windows-x64).
```

3. **Clear the "reserved storage in use" blocker.** Win11 24H2 `sysprep
   /generalize` fails validation with
   `SYSPRP Sysprep_Clean_Validate_Opk: Audit mode cannot be turned on if
   reserved storage is in use … hr = 0x800F0975` whenever reserved storage has
   an active servicing scenario (this golden carried an orphaned incomplete CBS
   session from its build). `ShippedWithReserves=0` alone is **not** enough. In
   the guest:

   ```powershell
   dism /online /Cleanup-Image /StartComponentCleanup   # finalize pending CBS
   shutdown /r /t 3 /f                                   # reboot to settle
   # after reboot, reset the ReserveManager scenario then disable reserves:
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v ActiveScenario /t REG_DWORD /d 0 /f
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager" /v DisableDeletes /t REG_DWORD /d 0 /f
   dism /online /Set-ReservedStorageState /State:Disabled   # must report success
   ```

4. **Bake the re-arm unattend** (see `rearm-unattend.xml` alongside this recipe,
   the exact file used). It is minimal on purpose — the persisted `admin`
   account, its `authorized_keys`, Automatic OpenSSH, and Automatic
   cloudbase-init all SURVIVE `/generalize`, so it does NOT re-create the
   account or re-install anything (and must NOT shut the clone down):
   - `generalize`: `PersistAllDeviceInstalls=true` (keep virtio drivers);
   - `specialize`: `<ComputerName>*</ComputerName>` → random DISTINCT hostname
     per clone, `TimeZone=UTC`;
   - `oobeSystem`: full Win11 OOBE skip (`SkipMachineOOBE`/`SkipUserOOBE`/
     `HideOnlineAccountScreens`/…) so clones boot straight to the logon screen
     unattended.

5. **Run sysprep — with `/quiet`:**

   ```
   C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet ^
       /unattend:C:\sysprep2-unattend.xml
   ```

   `/quiet` is MANDATORY: without it, a validation failure pops a modal error
   MessageBox, and in the non-interactive Session-0 (SSH/service) context there
   is no one to dismiss it — `sysprep.exe` then hangs forever holding the
   sysprep mutex (a second attempt blocks behind it). With `/quiet`, a failure
   writes `Panther\setuperr.log` and exits.

   Keep the `wuauserv` (Windows Update) service startable during the run: the
   generalize provider `GeneralizeForImaging` (wuaueng.dll) drives WU client
   generalization and stalls badly if the service can't start. The guest
   `SHUTS DOWN` on success.

6. **Capture the instant it powers off (do NOT boot the work image again):**

   ```bash
   qemu-img convert -O qcow2 /storage/scratch/sysprep2-work.qcow2 \
     /storage/iso/golden-win11-cloudbase-sysprep.qcow2
   ```

7. Destroy + undefine the throwaway domain (`virsh undefine … --nvram`) and
   delete the work overlay/nvram.

Because cloudbase-init is left Automatic, on each clone's first boot the service
auto-starts, sees the injected config-drive's fresh instance-id, and runs the
userdata — the M3 injection mechanism is unchanged by sysprep.
