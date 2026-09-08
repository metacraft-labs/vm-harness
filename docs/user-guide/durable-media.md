# Durable Media Instances

Linux/libvirt can retain an installed Linux QCOW2 guest under a logical name.
This is distinct from transient `boot --keep` and from Incus containers.
Other durable backends, hosts, guest OSes and media kinds are explicitly rejected.

## Commands

```console
vm-harness boot --keep --name dev --state-dir /var/tmp/my-vms \
  --backend libvirt --guest linux --source-image /data/installed.qcow2 \
  --ssh-forward-port auto --ssh-user guest --ssh-private-key /data/id_ed25519 \
  --ssh-known-hosts /data/known_hosts --ssh-host-key-alias dev \
  --log-format json

vm-harness instance status dev --state-dir /var/tmp/my-vms --log-format json
vm-harness instance start dev --state-dir /var/tmp/my-vms --log-format json
vm-harness instance ssh dev --state-dir /var/tmp/my-vms
vm-harness instance exec dev --state-dir /var/tmp/my-vms -- printf '%s\n' 'two words'
vm-harness instance logs dev --state-dir /var/tmp/my-vms --follow
vm-harness instance screenshot dev --state-dir /var/tmp/my-vms \
  --screenshot /tmp/dev.png --screenshot-delay-sec 2
vm-harness instance stop dev --state-dir /var/tmp/my-vms
vm-harness instance destroy dev --state-dir /var/tmp/my-vms
vm-harness instance start dev --state-dir /var/tmp/my-vms
vm-harness instance destroy dev --state-dir /var/tmp/my-vms \
  --instance-id ACTUAL-UUID-FROM-STATUS --purge
```

Boot accepts the existing graphics, firmware, TPM, CPU, memory, acceleration,
secondary ISO and optional serial `--expect` flags. It always waits for SSH
readiness before transferring ownership to the caller. Select graphics at boot
(e.g. `--graphics vnc`) when screenshots are needed. Screenshot operates on the
retained domain, not on a separate boot. It holds the operation lock through the
delay (0..300 seconds) and capture.

A name is 1..64 ASCII letters, digits, underscores, dots or hyphens, starting
with a letter or digit. Every operation accepts optional `--instance-id UUID`.
This checks the receipt's actual lowercase libvirt UUID; mutations also verify
the registered domain's UUID and issue commands by UUID. New boot may accept a
caller-generated UUID, but refuses an existing name, receipt directory or UUID.

`start` is idempotent for running instances and returns status after SSH is ready.
Bare `ssh` inherits the terminal and supplies no remote command. `exec` requires
argv after `--`, quotes each argument for the guest's POSIX login shell, supports
`--env KEY=VALUE`, and returns the SSH/guest exit code with separate stdout/stderr.
It does not automatically retry commands or stream local stdin; use interactive
SSH for terminal input. Process timeout returns 124; disconnecting SSH does not
guarantee that a guest-side background process has stopped.

`stop` requests graceful shutdown. `--timeout-sec` bounds readiness, exec and
stop waits; stop/destroy default to 60 seconds. An explicit `--force` selects
hard poweroff. There is no silent fallback from graceful to forced shutdown.

## Data Ownership

The caller's installed source remains a read-only backing file. Guest writes
land in one owned overlay, retained across stop/start and default destroy/start.
Do not replace or remove the source, its backing chain, supplied keys, trust file,
firmware templates or attached ISO while the instance is retained.

Receipts live at `ROOT/instances/NAME/instance.json`. The same directory holds
the writable overlay, `domain.xml`, `serial.log`, and optionally `known_hosts`.
Libvirt owns per-UUID NVRAM and TPM storage. Default destroy undefines the domain
with `--keep-nvram --keep-tpm`, retains all these files, and marks the receipt
destroyed. Start redefines saved XML with the same UUID and disk; it never creates
a new overlay. Externally lost definitions are also reported as destroyed.

Explicit `destroy --purge` requires `--instance-id`. It checks references from
other registered libvirt domains and receipts in the same ROOT, then removes
the owned runtime, NVRAM/TPM, overlay, saved XML, serial log, internally-created
known_hosts and receipt. It never deletes caller-supplied source disks, ISOs,
keys or known_hosts. It does not recursively delete unexpected directory contents.
A default-destroyed instance is temporarily redefined, without booting, so libvirt
can remove its owned firmware/TPM. Purge failure keeps a failed receipt for retry.
The name can be booted again only after successful purge.

These checks are not a host-wide dependency index: unrelated state roots and
unregistered external disk users remain the caller's responsibility. Do not
mutate libvirt definitions or receipt files behind vm-harness. The state root
is trusted, host-local storage; do not share it across hosts or relocate it.
The host/libvirt account must have access to its disks and logs.

The existing overlay sweeper and layer deletion refuse files next to a durable
receipt, even a malformed one. The ephemeral prune command does not own this
lifecycle. Lease duration, renewal and scheduling belong to the caller's resource
engine; vm-harness adds no lifetime daemon.

## Receipt And Status Schema

Schema version 1 uses snake_case. Status, successful boot/start/stop/destroy and
screenshot emit a single raw JSON object with `--log-format json`. Do not combine
a boot guest command's stdout with JSON-status parsing. Logs and exec output
remain raw output, not JSON envelopes.

Persisted fields:

| Key | Type / Meaning |
| --- | --- |
| `schema_version` | Integer, currently 1 |
| `name` | Logical CLI name |
| `instance_id` | Actual libvirt UUID, not a separate lease ID |
| `backend` | `libvirt` |
| `libvirt_uri` | Recorded connection URI, reused on every operation |
| `domain_name` | `vmh-media-UUID` |
| `phase` | creating, starting, running, stopping, stopped, destroying, destroyed, failed |
| `source_image` | Absolute caller-owned QCOW2 path |
| `active_disk` | Absolute owned writable overlay path |
| `domain_xml`, `serial_log` | Absolute recovery XML and append-only serial paths |
| `nvram_path` | Libvirt-owned firmware path, empty without NVRAM |
| `owns_known_hosts` | Whether the trust file was allocated inside the instance directory |
| `ssh` | Object described below |
| `created_at`, `updated_at` | Integer Unix seconds |
| `last_error` | Failure/recovery diagnostic, empty on success |

The `ssh` object has `host` (127.0.0.1), integer `port`, `user`,
`private_key`, `known_hosts`, `host_key_alias`, and `guest_os` (linux).
Key material is not embedded. TOFU trust uses accept-new and rejects changed
host keys. The default trust file/alias persist; they are not regenerated on start.

Status adds:

| Key | Type / Meaning |
| --- | --- |
| `receipt_path` | Absolute expected receipt path |
| `receipt_exists` | Boolean |
| `present` | Whether the named domain is registered |
| `state` | absent, running, stopped, destroyed, failed, creating |
| `backend_state` | Raw libvirt state (e.g. shut off), empty if not registered |
| `ownership` | absent, matched, mismatch |
| `observed_instance_id` | Observed libvirt UUID, empty if not registered |

No receipt is a successful query: exit 0, state absent, receipt_exists=false,
present=false, empty instance_id, empty paths/URI/SSH fields, port/timestamps 0.
The requested name, receipt_path, schema_version, backend and guest_os remain set.
An existing directory without a receipt, malformed receipt, backend query error
or explicit UUID precondition failure is a nonzero error, never an absent result.
A foreign domain UUID emits status with ownership=mismatch and exits 3.
A retained failed phase reports state=failed even if backend_state is shut off;
creating/starting phases report creating. Unknown backend states report failed.
Use receipt_exists=false to decide to boot; use start for stopped/destroyed
receipts. Inspect last_error before recovering a failed receipt.

Receipts are written before boot side effects, atomically replaced, and fsynced.
Failure preserves a failed receipt and attempts checked owned shutdown.
Bounded flock locks (`--lock-timeout-sec 0..300`, default 10) serialize operations
and remain held through exec/interactive SSH. Another command can fail busy;
it must not destroy an active command's VM. Status and logs read the atomic receipt
without taking the operation lock, so inspection works during interactive SSH.
These are point-in-time observations, not a transaction with libvirt; concurrent
purge or definition changes can return an I/O/backend error. Read-only library
handles reject mutating operations. Lock files survive purge; OS locks do not survive
process exit. They are not lifetime leases.

## Runtime And Verification

Linux builds declare PCRE alongside the host tools. The CLI retains an explicit
ELF PCRE dependency; pcre-config supplies its linker path/RUNPATH at build time.
The Nix package declares PCRE inputs. Runtime does not require inherited
LD_LIBRARY_PATH, which callers may unset before invoking host libvirt.
Native Linux builds need PCRE development files (pcre-config) as well as Nim.
Each Linux compile action selects the canonical pcre-config tool identity and
its uname dependency (pinned coreutils for Nix provisioning);
declaring package-level uses alone does not select it for a narrow build.
Missing or failing pcre-config is a compile error, except during graph-interface
and provider compilation, which declare the tools before they can be selected.
The optional diagnostic `python3 tests/integration/test_pcre_native_graph.py`
runs separate native CLI, benchmark and lifecycle-test builds using pinned Nix
provisioning from a base environment with Python 3 and Nim, but no pcre-config.
It launches the CLI and lifecycle fixtures with LD_LIBRARY_PATH unset, checks
inspection during active SSH/exec, and prints the binary path, hash and evidence
directory. Set REPRO_BIN to the native repro executable being verified, with its
bootstrap environment active. This is not in the default test graph: it tests
graph bootstrapping itself and must not recursively build that graph.
Libvirt must support keep-nvram/keep-tpm and nvram/tpm undefine flags.

The deterministic lifecycle suite uses fresh CLI processes and executable
virsh/virt-install/SSH fixtures, not a live hypervisor. It covers preservation,
failure recovery, UUID mismatch, purge and lock contention. Live validation of
firmware, TPM and graphical guests remains a host acceptance gate. Hyper-V,
macOS and cross-host portability are not implemented by this durable slice.
