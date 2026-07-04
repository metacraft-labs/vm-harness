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

## Golden completeness — HONEST caveat (sysprep)

This golden is **NOT sysprepped `/generalize`d**. It shares the base golden's
SID + hostname across clones (both the M3 clones and the running
`windows-runner-001` report hostname `REPRO-N226DFJUD`). For the M3 MECHANISM
proof this is fine — each ephemeral clone is a fresh CoW overlay, cloudbase-init
keys "have I run" on the per-job config-drive instance-id (unique per job) so it
runs fresh on every clone, and the runner is `--ephemeral` (one job, then
destroyed).

A **production** golden should additionally:

- run **`sysprep /generalize /oobe`** (with a cloudbase-init
  `SetupComplete`/unattend that re-arms cloudbase-init) so each clone gets a
  fresh machine SID + hostname — required for correctness at fleet scale and to
  avoid AD/telemetry collisions;
- pin the cloudbase-init + runner versions and re-capture on updates;
- optionally pre-install the runner as a service shell so the JIT path only has
  to drop the `.runner`/`.credentials` and `Start-Service`.

Sysprep `/generalize` was deliberately deferred from M3 (a full sysprep cycle is
slow to iterate and would need its own unattend to re-arm cloudbase-init +
OpenSSH + auto-logon; doing it wrong bricks the golden). The first-boot
config-drive path proven here is the correct injection MECHANISM regardless of
whether the golden is sysprepped; sysprep is an orthogonal generalization step
for M4/production.
