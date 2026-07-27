# Incus backend — implementation notes

Linux host, Linux **system container** guests via the `incus` CLI. This is
the container-based analog of the libvirt backend: ephemeral per-job
containers instead of per-job KVM VMs. Containers launch in well under a
second and need no `/dev/kvm`, so the per-job loop (fresh container → run
one job → destroy) is far cheaper than the VM path.

Source: `src/vm_harness/backends/incus.nim`.
Gate: `tests/e2e/t_vmharness_incus_ephemeral_run.nim`.

## Host prerequisites (IM0) — reproducible daemon init

The Incus daemon is initialized **declaratively** on the host via NixOS
(`virtualisation.incus`). On `solunska-server` this lives in
`~/dotfiles/nixos-configuration.nix`:

```nix
virtualisation.incus = {
  enable = true;
  preseed = {
    networks = [{
      name = "incusbr0";
      type = "bridge";
      config = { "ipv4.address" = "auto"; "ipv4.nat" = "true";
                 "ipv6.address" = "none"; };
    }];
    profiles = [{
      name = "default";
      devices = {
        eth0 = { name = "eth0"; network = "incusbr0"; type = "nic"; };
        root = { path = "/"; pool = "default"; type = "disk"; };
      };
    }];
    storage_pools = [{
      name = "default"; driver = "dir";
      config.source = "/var/lib/incus/storage-pools/default";
    }];
  };
};
```

This creates the `default` (dir) storage pool and the `incusbr0` NAT
network — the equivalent of `incus admin init --minimal`, but captured as
host state that rebuilds reproducibly. (On a non-NixOS host, run
`incus admin init --minimal` once instead.)

### Socket access

The daemon socket `/var/lib/incus/unix.socket` is group `incus-admin`. The
runner/service user must be in that group. On the host this is declared in
the same NixOS config:

```nix
users.users.<user>.extraGroups = [ ... "incus" "incus-admin" ];
```

If a login session pre-dates the group grant (or you are in a sandbox
without the group active), the CLI can be prefixed with `sudo`:

```sh
export VMH_INCUS_CMD="sudo -n incus"   # -n: fail fast, never block on a prompt
```

The `IncusBackend` reads `VMH_INCUS_CMD` (space-split) as the command
vector; production leaves it unset and uses a plain `incus` (group access).

### Base image (pinned locally)

```sh
incus image copy images:debian/12 local: --alias vmh-base
```

Debian 12 is used (not a minimal NixOS lxc image) because it ships a normal
FHS + `cloud-init`, so `incus exec -- true` and the IM2 cloud-init injection
seam both work out of the box. The alias defaults to `vmh-base`
(overridable via `VMH_INCUS_BASE` in the gate, or `--base-image` on the
CLI / `spec.baseImage` in code).

### IM0 round-trip gate (`t_incus_host_ready`)

```sh
incus launch vmh-base t-im0 && incus exec t-im0 -- true && incus delete -f t-im0
```

## CLI command map (one verb per VmBackend method)

| Method                   | incus command                                            |
|--------------------------|----------------------------------------------------------|
| `probeAvailability`      | `incus info`                                             |
| `provisionBaseline`      | `incus image list <alias>` (ensure present)              |
| `provisionEphemeralClone`| `incus launch <base> <name> [--ephemeral] [--profile p]` + optional `incus config set <name> cloud-init.user-data <...>` |
| `startAndAwaitReady`     | poll `incus exec <name> -- true` until Running + exec-ready |
| `execInGuest`            | `incus exec <name> [--env K=V] [--user U] -- <cmd...>`   |
| `copyToGuest`            | `incus file push [-r] <host> <name><guest>`              |
| `copyFromGuest`          | `incus file pull -r <name><guest> <host>`                |
| `stopAndCleanup(delete)` | `incus delete --force <name>`                            |
| `snapshot`               | `incus snapshot <vm> <name>`                             |
| `restoreSnapshot`        | `incus restore <vm> <name>`                              |
| `listSnapshots`          | `incus snapshot list <vm> --format csv`                  |
| `removeSnapshot`         | `incus delete <vm>/<snap>`                               |

## Ephemeral per-job lifecycle

`provisionEphemeralClone(EphemeralIncusSpec)` launches a FRESH container
from the base image. The returned `VmHandle` is tagged `ephemeral=true`;
`stopAndCleanup(deleteVm=true)` runs `incus delete --force`, which stops the
container and removes its per-container storage volume in one shot — no
residual container and no residual `container/<name>` volume on the pool.
The base image is never touched, so consecutive runs are independent (a
marker file written into run 1's guest is absent in run 2's fresh
container).

### cloud-init injection seam (for IM2 JIT)

`EphemeralIncusSpec.userData` (or the CLI `--user-data <file>`) is injected
via `incus config set <name> cloud-init.user-data <...>` before the
container is considered ready. This is the GARM JIT bootstrap seam — the
Incus analog of the libvirt config-drive ISO, but simpler (a config key).
`spec.config` carries any additional raw `incus config set` keys.

## IM2 — Linux runner image + cloud-init JIT injection

The Linux/container analog of the Windows M3 golden. Deliverables:

- **Runner image `vmh-linux-runner`** — built by
  `guest-recipes/linux-x64-runner/build-runner-image.sh`. A Debian *cloud*
  container image (`im2-debian-cloud` = `images:debian/12/cloud`, which
  ships cloud-init) with the GitHub Actions runner staged under
  `/opt/actions-runner`, an unprivileged `runner` user (passwordless sudo;
  the runner refuses to run as root), and the .NET runtime deps
  (`libicu72/libssl3/zlib1g/libkrb5-3` — already in the cloud base, so no
  apt is needed). Build (idempotent; a per-alias `vmh-bld-<alias>` throwaway
  container + the `vmh-linux-runner` alias only — override the build container
  with `VMH_BUILD_CONTAINER`):

  ```sh
  export VMH_INCUS_CMD="sudo -n incus"
  guest-recipes/linux-x64-runner/build-runner-image.sh
  ```

  The runner tarball is downloaded **on the host** and `incus file push`ed
  in — see the networking caveat below.

- **Cloud-init JIT injection** — the gate injects a GARM-derived Linux
  bootstrap (`tests/e2e/linux-jit/user_data.sh.tmpl`, derived from
  garm-provider-common's `CloudConfigTemplate` UseJITConfig path) as
  `cloud-init.user-data` through the IM1 seam above. On first boot
  cloud-init runs it autonomously: it pulls the JIT config from the mock
  GARM metadata endpoint (JWT-authorized; no-JWT → 401) and launches the
  runner via `run.sh --jitconfig <blob>`.

- **Mock GARM metadata + Actions endpoint** —
  `tests/e2e/linux-jit/mock_garm.py`, stdlib-only (HS256 verified with
  `hmac`, RSA/JIT material pre-generated on the host by `gen_jitconfig.py`
  and served static) so it runs inside a plain cloud container. It serves
  the JWT-authorized `/credentials/*` + `/system/*` routes and a minimal
  Azure-DevOps Actions surface (connectiondata with the DistributedTask
  location GUIDs, oauth/token, session-create, message long-poll).

- **Gate `t_incus_linux_jit_boot`** (`tests/e2e/`, driver
  `tests/e2e/linux-jit/run-linux-jit-gate.sh`) — launches a container from
  `vmh-linux-runner` with the injected bootstrap and asserts: cloud-init
  ran it autonomously; the JIT pull was JWT-authorized (no-JWT → 401);
  `run.sh --jitconfig` launched `Runner.Listener`, which connected to the
  mock, **POSTed a real runner session (SESSION-CREATED)** and reached
  **"Listening for Jobs"**; then both containers tear down with no residue.
  Uses only `im2-*` names.

  ```sh
  export VMH_INCUS_CMD="sudo -n incus"
  nim r --hints:off tests/e2e/t_incus_linux_jit_boot.nim
  ```

### Networking caveat (this host)

On `solunska-server` the host firewall (`nixos-fw`, default-drop input)
does **not** trust `incusbr0`, and Docker's `FORWARD` policy is DROP. So a
container has **no external egress** and **cannot reach a service bound on
the host** (and DHCPv4 does not lease — only IPv6 SLAAC comes up). Two
consequences the IM2 tooling works around:

- **Image build** downloads the runner tarball on the host and pushes it in
  (no in-guest `curl`/`apt`).
- **The gate** runs the mock in a **sibling container** (`im2-mock`) — two
  containers on `incusbr0` talk L2, bypassing the host firewall — and gives
  both containers a **static IPv4** via injected `cloud-init.network-config`
  (the runner) / `incus exec ip addr add` (the mock). In a normal host with
  a trusted bridge + working DHCP the mock could run on the host and DHCP
  would suffice; the static-IP + sibling-container shape is purely to
  sidestep this host's firewall.

## Gotchas

- `incus exec -- true` can fail transiently for a second or two after
  `incus launch` while the container init comes up; `startAndAwaitReady`
  polls for it. A raw NixOS lxc image may lack `true` on the default exec
  PATH — Debian does not have this problem.
- `incus list` lists ALL containers on the host. The gate asserts only on
  its OWN job names (`vmh-incus-*`) and never touches unrelated production
  containers (e.g. `k3s-*`, `nomad-*`).
- `incus file push`/`pull` as root make host-side files root-owned; that is
  expected when the backend runs under `sudo incus`.
