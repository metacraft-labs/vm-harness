# NetBird enrollment on Windows, under reprobuild (reusable recipe)

This is the **general, company-agnostic** recipe for enrolling a
**reprobuild-managed** Windows host (a box whose system scope is realised by
`repro infra apply` against a `*.nim` profile, *not* by NixOS / nix-darwin) as
a **NetBird** peer, so services on it can bind the WireGuard overlay IP and be
firewalled to the overlay range.

It is the reprobuild counterpart of the NixOS `services.netbird` /
`netbird-with-agenix` enrollment (systemd `netbird up --setup-key-file …`) and
the nix-darwin `launchd` login daemon. The three express the same shape — a
peer enrolled from a **reusable setup key** delivered as host secret material —
through the deployment system each host actually uses.

It exists as the network-layer companion to
[serve-windows-reprobuild.md](serve-windows-reprobuild.md): that recipe runs
`vm-harness serve` **NetBird-only** (single-address bind + overlay-scoped
firewall), which is only reachable once the host is a NetBird peer. This recipe
is how a reprobuild-managed Windows host becomes one. The concrete Metacraft
instantiation is
`infra/machines/server/_win-ci-bare-001/system_windows_runner.nim` (§18), which
restores that box's overlay-only posture after an interim LAN step.

## What the recipe does

Enrolls the host with the NetBird control plane using a **reusable** setup key,
running the NetBird Windows CLI as a system service. The steady state is a
`NetBird` Windows service holding a WireGuard tunnel and a stable overlay IP
out of the tenancy's CGNAT range (`100.64.0.0/10`).

## The three reprobuild resources

Declared inside the host profile's `resources:` block. Names are illustrative;
substitute your own constants.

1. **Content-addressed download** (`inlineExecCall`, elevated) — fetch the
   NetBird Windows CLI tarball
   (`netbird_<ver>_windows_amd64.tar.gz` from the upstream GitHub release) into
   a cache directory, verify its SHA-256 against a pin, and abort on mismatch.
   Use the same `$want` + early-`exit 0` content guard the other tool fetches
   use so a byte-correct cache entry is left untouched. The tarball's members
   sit **flat at the archive root** — `netbird.exe`, `LICENSE`, `README.md`,
   `LICENSES/` — there is no top-level directory.

2. **Extract** (`inlineExecCall`, elevated) — unpack with the Windows-bundled
   `tar.exe` (`$env:WINDIR\System32\tar.exe`, Win10 22H2+ reads `.tar.gz`
   natively) into a staging dir, lift the single `netbird.exe` out into a
   **stable, unversioned install dir** (e.g. `C:\netbird\netbird.exe`), and
   stamp a **version-marked** sentinel file (`.reprobuild-netbird-<ver>`) so a
   version-pin bump re-fires the edge — a bare `netbird.exe` would still exist
   after a bump and the edge would no-op, leaving the old client while the
   profile claimed the new one.

3. **Enroll** (`inlineExecCall`, elevated, `cacheable = false`) — in one
   elevated PowerShell so the steps share state:
   1. `netbird service install` **if the service is absent** (gate on
      `Get-Service`), then `Start-Service`.
   2. Poll `netbird status` until the daemon reports `Connected` or
      `NeedsLogin` (bounded, ~30 s), the same readiness wait the darwin login
      daemon uses.
   3. Run `netbird up --setup-key-file <PATH> --hostname <NAME>` **only if not
      already Connected** — `up` is the step that consumes the setup key, and
      is the one action you do not want to repeat needlessly.
   4. Record the allocated overlay IP (`netbird status --json`'s `netbirdIp`,
      with a human-`status` regex fallback) into a non-secret marker file, so
      an operator can read the IP back **without logging into the box** and
      drive any cutover that depends on it.

   `cacheable = false` makes "runs on every apply" a **declared** guarantee, so
   a host that lost its NetBird service or whose peer dropped **heals** rather
   than reporting success while unreachable. It is nonetheless idempotent: the
   `up` step self-skips when already Connected.

The NetBird service's binPath and arguments are owned by `netbird service
install`, so — unlike the serve daemon — this recipe does **not** re-declare
the service through a `windowsService` reconciler; doing so would be a second
source of truth for a service the CLI already manages.

## Auth & secret posture (NON-NEGOTIABLE)

- The **setup key is a secret**, delivered like every other host secret. On a
  NixOS host that is agenix + a systemd unit; on a reprobuild **pull-model** box
  it rides the deploy manifest's **sealed section**, which `repro deploy-agent
  --secrets-dir` materialises **before** the apply, so the key file is present
  when the enroll edge runs. `netbird up --setup-key-file` reads it.
- The enroll edge passes `--setup-key-file <constant path>` — **the path is on
  the plan surface, never the value.** The setup-key file is therefore **not**
  listed in the edge's `inputs` (an `inputs` entry would fingerprint the
  credential into the action cache) nor its `outputs` (an `outputs` entry would
  copy it into the local CAS in plaintext). Same posture the runner-token
  registration edge uses.
- Prefer a **reusable** setup key so recreating/re-imaging the host re-enrolls
  it from the same sealed material with no fresh mint. A reusable key is a
  durable credential: it must be **revoked** in the control-plane dashboard
  when the host is decommissioned, not merely deleted from the producer.
- The key should **auto-assign the group** that grants the reachability the
  host needs (see your control plane's policies). The group is a property of
  the key at mint time, not of this recipe.

## Prerequisites on the host

- A pinned NetBird version. Keep it in lockstep with the rest of the fleet's
  NetBird pin so peers move together.
- The sealed setup-key file present under the deploy agent's `--secrets-dir`
  (the producer seals it into the manifest; see your deploy-manifest producer).

## Verifying it

Off-host, the emitted PowerShell is what a unit test asserts on (the fetch
guard, the flat-root extract, the install/start/up/record sequence). On-host,
after an apply: `netbird status` reports `Connected`, `Get-Service NetBird`
is `Running`, and the overlay-IP marker file holds a `100.x` address. A service
bound to that overlay IP (e.g. `vm-harness serve`, per
[serve-windows-reprobuild.md](serve-windows-reprobuild.md)) then becomes
reachable from peers the control-plane policy permits.
