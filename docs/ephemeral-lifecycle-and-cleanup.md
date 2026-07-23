# Ephemeral instance lifecycle & cleanup

**Status**: Implemented.
**Audience**: vm-harness contributors and operators of long-running fleets
(e.g. the GARM `garm-provider-vmharness` runner provider).

This document specifies how vm-harness provisions the per-instance disk for
ephemeral guests, how it makes a leaked instance cheap and reclaimable, and the
`prune` contract callers use to reclaim resources left behind by launchers that
were hard-killed before their own teardown could run.

## 1. Problem

Every ephemeral guest normally cleans itself up: `stopAndCleanup` terminates
the VM, removes the per-instance directory / clone, and deletes the transient
SSH-password file (`defer removeFile`). That teardown runs on normal return and
on exceptions — but **not** when the launcher process is `SIGKILL`ed (host
crash, OOM, service restart). Hard kills are routine in CI, so residue
accumulates:

- **qemu-windows-arm**: a per-instance directory under the backend state dir,
  historically holding a full copy of the multi-GB `windows.qcow2`.
- **tart**: a registered ephemeral clone (`tart list`) that a later run never
  reaps, because each instance uses a unique per-instance prefix.
- **Both**: transient scratch files in the system temp dir — SSH-password files
  (`vm-harness-<backend>-pwd-*`) and Tart mount-share scripts.

## 2. Cheap ephemeral disks: qcow2 backing overlay

`qemu-windows-arm` provisions the instance disk in one of two modes, selected
by `VMH_QEMU_WINDOWS_ARM_DISK_MODE`:

- **`overlay` (default)** — `createEphemeralOverlay` runs
  `qemu-img create -f qcow2 -F qcow2 -b <golden>/windows.qcow2 <inst>/overlay.qcow2`.
  The golden `windows.qcow2` is **never copied**; it is an immutable, read-only
  backing file shared by every concurrent instance. The overlay records only
  the guest's writes, so a leaked instance costs its write-delta (KB–MB), not a
  full disk. This is the same CoW-overlay pattern the libvirt backend already
  uses, and unlike an APFS `cp -c` clonefile it is portable to every filesystem
  and OS (Linux included, where the old clone path fell back to a full byte
  copy).
- **`clone`** — `createEphemeralCopy` makes a full independent `windows.qcow2`
  per instance (APFS clonefile on macOS, byte copy elsewhere). Retained as a
  fallback / escape hatch.

The small per-instance firmware bits — UEFI vars (`.fd`), option ROMs, and a
seeded TPM state directory — cannot use a qcow2 backing chain, so they are
always clonefile/copied. They are only a few MB.

QEMU boots from `qwaDiskImagePath(vmDir)`, which prefers `overlay.qcow2` when
present and otherwise falls back to `windows.qcow2` (clone mode and legacy
instances).

### Invariants

- The golden `windows.qcow2` MUST remain immutable and path-stable for the
  lifetime of any overlay that backs onto it. Do not `qemu-img commit`, move,
  or rewrite it while instances are live.
- Backing paths are stored absolute (the baseline dir is `absolutePath`'d), so
  an overlay is independent of the working directory.
- Teardown removes only the instance directory (overlay + firmware + TPM); the
  golden is never touched.

## 3. Liveness: the per-instance advisory lock

On start, `qemu-windows-arm` takes a `flock` on `<vmDir>/.instance.lock` and
holds the fd for the instance's lifetime (`acquireInstanceLock`). A `flock` is
owned by the open file description, so the OS drops it automatically when the
launcher exits or crashes — and a probe from any other process (or another fd
in the same process) sees the conflict. This makes liveness race-free and
immune to PID recycling:

`instanceDirOwnerAlive(vmDir)`:
1. If `.instance.lock` exists: a non-blocking `flock` that **succeeds** means
   nobody holds it ⇒ owner dead; **fails** ⇒ owner alive.
2. Legacy instances predate the lock file: fall back to the creator PID
   embedded in the directory name (`<prefix>-<epochMs>-<pid>`), paired with an
   age guard so a recycled PID cannot mask a genuine orphan.

Tart clones have no lock; their liveness uses the embedded creator PID plus the
age guard.

## 4. The `prune` contract

```
vm-harness prune --ephemeral-prefix <p> [--backend all|tart|qemu-windows-arm]
      [--state-dir <dir>] [--older-than <sec>] [--sweep-tmp] [--dry-run]
      [--log-format human|json]
```

- **Always scoped.** `--ephemeral-prefix` is required. vm-harness is a general
  tool shared by many projects; a prune only ever inspects names starting with
  the given prefix (the same per-project tag used to name ephemeral VMs) inside
  the given state dir. Nothing outside that scope is touched. The tart path
  refuses to run without a prefix (it would otherwise match every VM on the
  host).
- **Never removes a live instance.** A held lock, or a live creator PID, always
  protects an instance.
- **`--older-than`** (default 3600s; `0` disables) guards the PID-fallback and
  tmp-file paths so a fresh-but-orphaned entry is retained briefly rather than
  raced. Lock-held liveness needs no age guard, but the guard adds a safety
  margin for the legacy/no-lock case.
- **`--sweep-tmp`** additionally age-removes transient scratch files
  (`vm-harness-*-pwd-*`, Tart mount-share scripts) matching the in-scope
  backend(s). These are aged by mtime only — their name field order differs
  from instance names — so an in-use password file (seconds old) is never
  swept.
- **`--dry-run`** reports what would be reclaimed and deletes nothing.
- Best-effort: individual failures are skipped, never raised.

## 5. Fleet integration (GARM provider)

`garm-provider-vmharness` calls `vm-harness prune` opportunistically after each
successful `DeleteInstance` (`VMHarnessRunBackend.Sweep`), scoped to the
backend's shared prefix stem (`repro-vm-tart-macos`, `repro-vm-tart-linux`,
`repro-vm-qemu-windows-arm`) with `--sweep-tmp`. Delete is per-instance and
self-cleaning; the sweep mops up orphans from prior runs that crashed before
their own Delete could fire, so leaks do not accumulate across the fleet
without a separate daemon. Because prune is lock-guarded, running it while
other instances are live is safe.

## 6. Follow-ups

- The transient SSH-password and socket files still live in the global system
  temp dir rather than under the project state dir. Relocating them under the
  per-instance directory (so they are removed with it and are project-scoped by
  construction) would let `--sweep-tmp` be retired. Tracked as a follow-up
  because it touches several call sites and the tart backend has no state-dir
  concept today.
- Boot verification of overlay mode against a real Windows-on-ARM golden is
  covered by the host-level gates in `metacraft-labs/infra`, not the
  deterministic unit catalog.
