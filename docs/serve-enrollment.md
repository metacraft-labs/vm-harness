# vm-harness serve — enrollment, signed identity, capability manifest (RA6)

RA6 turns the `/v1/info` backend seed into a **signed capability manifest** plus
a lightweight **enrollment/identity model**. Each serve host presents (a) a
signed identity and (b) a machine-checkable manifest describing its real
hardware; a controller reads it over `GET /v1/manifest`, verifies the signature
against its trust store, and **rejects an unenrolled, expired, or revoked
identity**. This manifest is the **source** for the Phase-C runner labels —
labels are DERIVED from proven hardware, not hand-maintained in a class name.

Gate: `t_vmharness_serve_enrollment` (hermetic on Linux, `--backend noop`).

## What is served

`GET /v1/manifest` (bearer-auth like every `/v1` route) returns:

```jsonc
{
  "identity": {
    "keyId": "vmh1-3f9a2c1b7e0d4a56",     // stable, non-secret host id
    "host": "high-mem-server",
    "issuedAt": 1757440000,
    "notAfter": 1757443600,                // short-lived (TTL, default 1h)
    "alg": "hmac-sha256",
    "manifest": {
      "manifestVersion": "1",
      "os": "linux",                        // linux | windows | macos
      "arch": "x86_64",                     // x86_64 | arm64 | …
      "archLevel": "x86-64-v3",             // "" for non-x86
      "cpuCount": 32,
      "memTotalMb": 128000,
      "gpu": true,
      "nestedVirt": true,
      "docker": true,
      "podman": false,
      "rrHwCounters": true,
      "hypervisors": [
        {"id": "incus",   "available": true,  "guests": ["linux"]},
        {"id": "libvirt", "available": true,  "guests": ["windows","linux"]}
      ]
    }
  },
  "sig": "<hex HMAC-SHA256 over canonical(identity)>"
}
```

`GET /v1/info` is unchanged (RA1 back-compat): protocol version + the backend
seed. `/v1/manifest` is the new, versioned, signed surface.

`vm-harness manifest` prints THIS host's **unsigned** manifest locally (no
daemon, no secret) — handy for debugging and for the RC1 label-derivation
source. `vm-harness --remote <addr> manifest` fetches the remote **signed**
identity over `/v1/manifest`.

## Capability detection — how each field is proven

Every capability is a **pure function** over an injected input
(`src/vm_harness/serve/capability.nim`), so it is asserted against fixtures with
no hardware present (`tests/unit/t_serve_enrollment.nim`). The impure
`detectHostCapabilities` only gathers the inputs from the live host.

| Field           | Source                                             | Rule |
|-----------------|----------------------------------------------------|------|
| `os` / `arch`   | compile-time `defined()` + `hostCPU`               | direct |
| `archLevel`     | `/proc/cpuinfo` `flags` line                        | psABI `x86-64-v{2,3,4}` feature groups; `x86-64-v1` baseline; `""` for arm64 |
| `cpuCount`      | `/proc/cpuinfo` `processor` lines / `countProcessors` | max of the two |
| `memTotalMb`    | `/proc/meminfo` `MemTotal`                          | kB → MiB |
| `gpu`           | `nvidia-smi -L` exit + `lspci`                      | `nvidia-smi` ok OR an lspci VGA/3D/Display line from a known vendor |
| `nestedVirt`    | `/sys/module/kvm_{intel,amd}/parameters/nested`    | either reports `Y`/`1` |
| `docker`/`podman` | `findExe`                                        | binary present on PATH |
| `rrHwCounters`  | `/proc/sys/kernel/perf_event_paranoid` + arch      | x86-64 AND paranoid ≤ 1 (the necessary, machine-checkable precondition; rr does further CPU-model checks at runtime) |
| `hypervisors`   | the daemon's backend registry (`probeAvailability`) | same probe as `/v1/info` |

**Stubbing when a probe binary is absent.** A missing `nvidia-smi`/`lspci`,
absent `/sys/module/kvm_*`, or unreadable `perf_event_paranoid` yields the safe
default `false` ("not proven present") — never a guess. This is the correct
default for label derivation: a host advertises only what its manifest proves.
Off-Linux, the `/proc`-based fields are best-effort; the Phase-A fleet only
enrolls Linux/macOS/Windows serve hosts and the controller keys on `os`/`arch`
there. Extending Windows/macOS-native detection (CIM/`system_profiler`) is a
documented follow-up.

## Enrollment / identity / revocation model

- **Per-host enrollment secret.** A 256-bit secret, resolved (in precedence
  order) from `--enroll-secret` > `--enroll-secret-file` > `$VMH_ENROLL_SECRET`
  > a secret persisted under `--state-dir` (self-bootstrapped on first run for
  dev). Production provisions it via agenix / systemd `LoadCredential`, exactly
  like the bearer token.
- **keyId** = `"vmh1-" & sha256(secret)[0..15]` — a stable, non-secret host
  identifier, safe to log. The daemon prints it at startup
  (`identity keyId vmh1-… (enroll this keyId on the controller)`).
- **Enrollment** = recording that host's secret in the controller's `TrustStore`
  (`store.enroll(secret)` learns `keyId → secret`). An unenrolled keyId is
  rejected.
- **Signature.** The daemon signs each identity with a detached
  **HMAC-SHA256** over the canonical (sorted-key, compact) JSON of the identity.
  The controller recomputes it with the enrolled secret and compares in
  constant time.
- **Expiry.** Identities are short-lived (`--identity-ttl-sec`, default 3600).
  The controller caches one and re-fetches after `notAfter`; a stale cached
  identity fails verification.
- **Revocation.** `store.revoke(keyId)` — a revoked (or unknown) keyId is
  rejected before the MAC is even checked.

`verify()` decides identity/enrollment status **before** the cryptographic MAC,
and checks expiry **last** (only a signature-valid identity's clock is
trustworthy): `unenrolled` / `revoked` → `bad-payload` (alg/version) →
`bad-signature` → `expired` → `ok`.

### Why symmetric (HMAC), deliberately

The serve endpoint is **already** authenticated + confidential: a bearer token
over a NetBird (WireGuard) overlay, never exposed publicly (campaign
non-negotiable pattern (a)). This identity signature is therefore **not** a
second transport-auth — it is capability/identity **advertisement**: its job is
tamper-evidence, host-identity binding, expiry, and revocation on top of a
transport that already provides confidentiality and endpoint auth.

vm-harness is deliberately dependency-light (`vm_harness.nimble` requires only
`nim`); Nim's stdlib ships no asymmetric primitive, and linking OpenSSL /
vendoring a curve for a capability-advertisement signature is disproportionate.
So the signature is a vendored, fully test-vectored pure-Nim HMAC-SHA256
(`src/vm_harness/serve/hmac.nim`, checked against NIST SHA-256 + RFC 4231
vectors). The wire format carries an `alg` field so an upgrade to **Ed25519**
(asymmetric — the controller then holds only public keys, and a compromised
controller store cannot forge) is a versioned, non-breaking change when an
asymmetric primitive is acceptable in the dependency budget. That upgrade is the
recorded follow-up.

## Phase-C consumption — the label-derivation contract (RC1)

RC1 (metacraft-dev-guidelines `ci-workflow-standards.md`) defines the taxonomy;
the **mechanism** lives in nixos-modules (per the campaign repo-layering). Both
consume THIS manifest. The canonical derivation:

| Manifest field                    | Derived runner label(s) |
|-----------------------------------|-------------------------|
| `os`                              | `linux` / `windows` / `macos` |
| `arch`                            | `x64` (x86_64) / `arm64` |
| `archLevel`                       | `x86-64-v2` / `x86-64-v3` / `x86-64-v4` (a host that proves v3 also satisfies v2) |
| `gpu == true`                     | `gpu` |
| `nestedVirt == true`              | `nested` |
| `docker == true`                  | `docker` |
| `podman == true`                  | `podman` |
| `rrHwCounters == true`            | `rr-hw-counters` |
| `hypervisors[].id` where available| `incus` / `libvirt` / `hyperv` / `tart` |

**Contract for the RC1 linter:** every label a host advertises MUST be a subset
of what its (signed, verified) manifest proves — `advertised ⊆ derived`. The
controller fetches `/v1/manifest`, `verify()`s it, and only then trusts the
manifest to derive labels; an unverifiable manifest yields no labels. Because the
manifest is `manifestVersion`-pinned and signed, the derivation is stable and
tamper-evident.

## Operator / infra follow-up (NOT wired in this milestone)

Deploying the manifest to the controller is Phase-C work. RA6 ships only the
vm-harness mechanism. When the per-host serve deployments (RA2–RA5) and the
central controller (Phase B/C) consume this:

1. **Provision a per-host enrollment secret** alongside the existing serve
   bearer token — an agenix secret, delivered via systemd `LoadCredential`
   (Linux), launchd (macOS), or the reprobuild service profile (win-ci-bare-001)
   — passed as `--enroll-secret-file`. (Mirror `just mint-serve-tokens`; add a
   `just mint-enroll-secrets` sibling that also records each host's keyId.)
2. **Enroll each host's keyId** in the controller's trust store (the keyId is
   printed at daemon startup and is safe to record in infra). Revocation =
   removing/​revoking that keyId.
3. **The controller** (nixos-modules capability-manifest→label mechanism) fetches
   `/v1/manifest`, verifies it, and derives the RC1 labels per the table above.

Until then, `vm-harness manifest` / `--remote <addr> manifest` already expose the
manifest for inspection and for prototyping the derivation.
