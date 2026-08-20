---
title: Parameters catalog
section: reference
order: 2
slug: parameters
---
# Parameters catalog

vm-harness is a toolkit whose value is its parameters. This page documents the
knobs consumers rely on as a stable, public contract: name, type, default,
effect, and security/performance implications. Two surfaces matter most:

- the runner-image recipe seams (`VMH_RUNNER_*` and friends) that shape the
  `vmh-linux-runner` Incus image, and
- the GARM Incus provider options (`incus*`) a fleet operator sets to grant
  per-job containers their capabilities.

Every value below was verified against source; nothing here is invented. If you
change a default, treat it as an API change — downstream repos (e.g. the
`metacraft-labs/infra` runner fleet) build policy against these values.


## 1. Runner-image recipe seams

Read by `guest-recipes/linux-x64-runner/build-runner-image.sh`. All are
environment variables. They are the reference example of a parameterized recipe;
the same conventions apply to the other recipes. Set them in the environment
before invoking the script.

### Image identity and base

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_INCUS_CMD` | command (space-split) | `incus` | The incus invocation the recipe shells to. Set to `sudo -n incus` when the session lacks `incus-admin` group access. |
| `VMH_RUNNER_ALIAS` | string | `vmh-linux-runner` | Output image alias. Point this at a SIDE alias (e.g. `vmh-linux-runner-nested`) for capability bakes so the live image is never overwritten. |
| `VMH_CLOUD_BASE` | string | `im2-debian-cloud` | Local Debian cloud base alias (must ship cloud-init). |
| `VMH_CLOUD_REMOTE` | string | `images:debian/12/cloud` | Remote image copied into `VMH_CLOUD_BASE` if the local alias is absent (needs host network). |
| `VMH_CLOUD_BRIDGE` | string | `incusbr0` | The incus bridge used to derive the build container's static egress IP. |
| `VMH_RUNNER_RECIPE_REVISION` | string | `linux-x64-runner-v1` | Stamped onto the published image as the `vmh.recipe_revision` property. A consumer rebuilds when its expected revision differs — the fleet-refresh lever. |

### GitHub Actions runner staging

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_RUNNER_VERSION` | string | `2.335.1` | actions/runner release version to stage. |
| `VMH_RUNNER_TARBALL` | path | download to `/tmp` | Pre-downloaded runner tarball to use instead of downloading (useful offline). |
| `VMH_RUNNER_USER` | string | `runner` | Unprivileged runner user (created with passwordless sudo; the runner refuses to run as root). |
| `VMH_RUNNER_CACHE` | path | `/home/<user>/actions-runner` | In-image runner directory. Must match GARM's Linux install template's cached path, or the per-job bootstrap re-downloads the ~200 MB runner every job. |

### Nested Docker bake (HR1)

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_RUNNER_DOCKER` | bool (`1` = on) | off | Bake docker/moby + fuse-overlayfs + a `docker.service`/`docker.socket` so an in-guest Docker daemon can run. Off ⇒ the live image is byte-unchanged. Pairs with the provider's `incusSecurityNesting = true` — the image ships the userspace, the provider grants the privilege. |
| `VMH_DOCKER_VERSION` | string | `27.5.1` | Docker static-binary bundle version. |
| `VMH_DOCKER_TARBALL` | path | download on host | Pre-downloaded docker static bundle (streamed in, not `incus file push`ed). |
| `VMH_DOCKER_STORAGE_DRIVER` | string | `fuse-overlayfs` | Docker storage driver written into `daemon.json`. An unprivileged nested container cannot use the kernel `overlay2` driver, so `fuse-overlayfs` is the safe default. |

Security/perf: nested Docker requires the container to run with
`security.nesting` plus the mknod/setxattr syscall intercepts (the provider's
`incusSecurityNesting`). The daemon runs unprivileged inside the ephemeral
one-job guest; the socket is group-owned `docker` so the runner reaches it
without sudo.

### Nested KVM bake (HR2)

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_RUNNER_KVM` | bool (`1` = on) | off | Bake `qemu-system-x86` + a guest kernel so an in-guest `qemu-system-x86_64 -enable-kvm` boots a hardware-accelerated nested VM. Off ⇒ the live image is byte-unchanged. Pairs with the provider's `incusNestedKvm = true`. |

Security/perf: hardware acceleration requires the host to expose `/dev/kvm`
with nested virt enabled (`kvm_intel.nested=Y` / `kvm_amd.nested=Y`) and the
provider to attach `/dev/kvm` into the container. `VMH_RUNNER_DOCKER=1
VMH_RUNNER_KVM=1` bakes both into one image (the prod `incus-nested` class needs
both).

### `repro` CLI bake (HR-REPRO)

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_RUNNER_REPRO` | bool (`0` = off) | on | Bake the pinned `repro` CLI onto PATH (as the portable self-extractor) and pre-warm its extraction at bake time so per-job first-run is fast (~4 s warm vs ~50 s cold). Set `0` to reproduce the pre-repro image byte-for-byte. |
| `VMH_REPRO_PIN` | git rev | resolved from nixos-modules `flake.lock` | reprobuild rev to build `repro-portable` from. Overrides the single-source-of-truth pin (e.g. to test an unlanded rev). |
| `VMH_REPRO_BUNDLE` | path | nix-built on host | Pre-built `repro-portable` self-extractor to install, skipping the nix build. |
| `VMH_NIXOS_MODULES_LOCK` | path | `../../../nixos-modules/flake.lock` (relative to the script) | The `flake.lock` whose `reprobuild` node rev pins `repro`. This is the single source of truth so the runner image and the nix fleet install byte-identical `repro`. |

Note for out-of-tree consumers: the default `VMH_NIXOS_MODULES_LOCK` path
assumes the sibling-checkout workspace layout. When the recipe is invoked from a
context without that sibling (e.g. an isolated Nix-store source), either set
`VMH_NIXOS_MODULES_LOCK` to a real path, set `VMH_REPRO_PIN` explicitly, or set
`VMH_RUNNER_REPRO=0` to skip the bake — otherwise the build aborts.

### Build-egress overrides (host-dependent)

Used only when `incusbr0` DHCP does not lease and the build container needs a
static egress IP for its apt steps. Auto-derived from the bridge; override only
on unusual host networking.

| Variable | Type | Default | Effect |
| --- | --- | --- | --- |
| `VMH_BUILD_EGRESS_IP` | IPv4 | host `.249` of the bridge /24 | Static build-container egress IP. |
| `VMH_BUILD_EGRESS_GW` | IPv4 | the `incusbr0` host address | Default route for the build container. |
| `VMH_BUILD_EGRESS_DNS` | IPv4 | `1.1.1.1` | Resolver written into the build container. |

The static address is torn down before publish, so the image carries no stray
address (the provider injects the real per-job IP via cloud-init).


## 2. GARM Incus provider options

These options shape the per-job Incus container that the GARM vm-harness
provider launches. They are the run-time complement to the recipe seams above:
the recipe bakes a capability into the image, the provider grants the matching
privilege to the container.

:::note
Where these are defined. These options are the NixOS `services.garm`
provider surface, defined in the shared `metacraft-labs/nixos-modules` GARM
module (`modules/garm/default.nix`), and set by a consumer such as
`infra/services/garm-incus-runners.nix`. They are documented here because they
are the run-time half of vm-harness's runner-image feature contract — the two
only work as a pair. Set them in the consumer's NixOS config, not in
vm-harness. All are ignored by non-incus providers.
:::

### Capability options (the recipe pairings)

| Option | Type | Default | Effect + security posture |
| --- | --- | --- | --- |
| `incusSecurityNesting` | bool | `false` | Enables `security.nesting = true` + `security.syscalls.intercept.mknod` + `.setxattr` on each container before start, so an in-guest Docker/Podman daemon can run on the fuse-overlayfs driver. Requires the image to ship Docker (`VMH_RUNNER_DOCKER=1`). The daemon is unprivileged; the intercepts are what let an unprivileged nested container build overlay image layers. |
| `incusNestedKvm` | bool | `false` | Exposes host `/dev/kvm` into the container (`incus config device add <c> kvm unix-char source=/dev/kvm mode=0666`) and ensures `security.nesting=true`, so an in-guest `qemu-system-* -enable-kvm` gets hardware-accelerated nested virt. Requires the host to expose `/dev/kvm` with nested virt enabled and the image to ship qemu/kvm (`VMH_RUNNER_KVM=1`). The permissive device mode is confined to the dedicated ephemeral one-job guest. |
| `incusGpuPassthrough` | bool | `false` | Attaches an NVIDIA GPU to each container (`incus config device add <c> gpu gpu` + `nvidia.runtime=true`). Requires `hardware.nvidia-container-toolkit.enable = true` on the host. Backs a GPU runner class. |

### Shared-store options

| Option | Type | Default | Effect + security posture |
| --- | --- | --- | --- |
| `incusShareHostNixStore` | bool | `false` | Mounts the host `/nix/store` read-only into each container plus the nix-daemon socket dir, so guest builds go through the host daemon (`NIX_REMOTE=daemon`) — a build-once/cache-hit-everywhere farm. Safe by design: incus's idmap makes the guest an untrusted nix client (`Trusted: 0`), so it can add content-addressed paths but cannot set substituters/trusted-keys or import unsigned NARs as trusted, and cannot poison the cache (a malicious path content-addresses to a different hash). Residual risk is disk-DoS, contained by ephemeral one-job guests + store quotas. |
| `incusReprobuildStore` | path (host) | `""` | HOST path of the reprobuild BLAKE3 content-addressed store, mounted read-write into each container. Writes are self-verifying (a tampered blob hashes to a different digest, so an existing entry cannot be corrupted); a job resolves prebuilt artifacts locally with no HTTP round-trip. Empty ⇒ no share. |
| `incusReprobuildStoreGuestPath` | path (guest) | `""` | In-guest mount point for `incusReprobuildStore`. Empty ⇒ mirrors the host path. Only consulted when `incusReprobuildStore` is set. |

### Networking options

`incusbr0` DHCP does not lease on the reference host, so the provider injects a
static IPv4 per container via cloud-init. These options describe that pool.

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `incusPath` | path | `${pkgs.incus}/bin/incus` | Path to the `incus` client the provider shells to. |
| `incusBridge` | string | `incusbr0` | Managed bridge the containers attach to; also the interface trusted for the GARM callback/metadata port when `openIncusBridgeFirewall` is set. |
| `incusIPv4CIDR` | string `a.b.c.d/nn` | `""` | Bridge subnet. Required when backend = incus. |
| `incusIPv4Gateway` | string (IPv4) | `""` | Default route for containers (the bridge host IP) and the host IP the guest reaches GARM's metadata/callback on. Required when backend = incus. |
| `incusIPv4RangeStart` | string (IPv4) | `""` → provider uses `.200` | Lower bound (inclusive) of the static-IPv4 pool. |
| `incusIPv4RangeEnd` | string (IPv4) | `""` → provider uses `.250` | Upper bound (inclusive) of the static-IPv4 pool. |
| `incusNameservers` | list of string | `["1.1.1.1" "8.8.8.8"]` | Resolvers written into each container's netplan. |

Related provider options that are not incus-specific but commonly set alongside:
`sourceImage` (the golden alias per pool), `guestMetadataURL` / `guestCallbackURL`
(provider-local overrides of the GARM URLs rendered into guest bootstrap), and,
for the libvirt backend, `libvirtURI`, `network`, and `poolDir`.


## 3. Other backend / recipe environment variables

Several backends read `VMH_*` variables for tool paths, credentials, timeouts,
and image locations. These are operator escape hatches — the constructor
defaults are the supported values (documented in [Driving a VM from code](/guides/driving-a-vm)
and each backend source under `src/vm_harness/backends/`). Notable ones:

- Incus backend: `VMH_INCUS_CMD` (invocation vector).
- Recipe resolution: `VMH_RECIPES_DIR` (override where `--recipe <id>` resolves).
- Tart: `VMH_TART_CMD` (also honored by `prune`), plus `VMH_UTM_SSH_USER` /
  `VMH_UTM_SSH_PASSWORD` on the UTM path.
- qemu-windows-arm: a large tunable surface —
  `VMH_QEMU_WINDOWS_ARM_{QEMU_CMD,QEMU_IMG_CMD,SSH_CMD,SCP_CMD,SSHPASS_CMD,SWTPM_CMD,SSH_USER,SSH_PORT,SSH_PASSWORD,SSH_TIMEOUT,BOOT_TIMEOUT,PROBE_TIMEOUT,DISK_MODE,EPHEMERAL_PREFIX}`,
  and the firmware pair `VMH_QEMU_EFI_CODE` / `VMH_QEMU_EFI_VARS`.
- Windows golden recipes: `VMH_WIN11_X64_ISO`, `VMH_WIN11_ARM_ISO`,
  `VMH_OVMF_CODE` / `VMH_OVMF_VARS`, `VMH_GUEST_PASSWORD`,
  `VMH_SYSPREP_TIMEOUT` / `VMH_SYSPREP_DRY_RUN`, `VMH_DISM_TIMEOUT`, and the
  ARM OpenSSH/virtio fetch overrides (`VMH_OPENSSH_ARM64_*`,
  `VMH_VIRTIO_NETKVM_ARM64_*`).

Only the `VMH_RUNNER_*` recipe seams and the `incus*` provider options in
sections 1–2 are treated as the primary stable consumer contract; the rest are
escape hatches whose supported form is the backend constructor default.
