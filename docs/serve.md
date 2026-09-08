# vm-harness serve — remoting daemon (RA1)

`vm-harness serve` is an authenticated network front-end that exposes this
host's VM/container lifecycle operations to a remote controller. It is the
**uniform network access point** for every backend (incus, libvirt, Hyper-V,
tart, …) so any host's VMs can be driven from a central controller — the
foundation the CI Runner Fleet campaign (central GARM, capability pools)
builds on.

It is a *thin front-end, not a reimplementation*: every operation is executed
by the **same `vm-harness` binary** the CLI runs. The daemon adds only the
network endpoint, the auth check, and output streaming.

## Why HTTP/JSON (not gRPC)

- vm-harness is dependency-light (`vm_harness.nimble` requires only `nim`).
  HTTP/1.1 + JSON needs only `std/net` + `std/json`, already used across the
  CLI and backends. gRPC would add protobuf tooling + a Nim gRPC library to
  every build.
- The Go `garm-provider-vmharness` (campaign milestone RB1) speaks HTTP/JSON
  trivially with the Go stdlib.
- Study of Agent Harbor's `ah-remote-exec` informed two choices we adopted:
  an **auth-method** abstraction (AH's key-file / password / agent) — we take
  the bearer-token shape — and **capability tags** on a host — we expose a
  backend/capability list on `/v1/info` (the seed of the RA6 capability
  manifest). AH drives hosts over **system SSH**; vm-harness deliberately
  ships its own daemon so one protocol front-ends every backend uniformly
  (the operator directive that supersedes the design doc's
  "cloud-fleet management out of scope — use AH's orchestrator" line).

## Protocol v1

Versioned under the `/v1` URL prefix; every message also carries a `v` field;
`/v1/info` reports `protocol`. Bump `ProtocolVersion` on any breaking change.

All routes require `Authorization: Bearer <token>`; a missing/wrong token is
rejected with **401 before any work runs** (constant-time token comparison).

| Method + path      | Body                              | Response                          |
| ------------------ | --------------------------------- | --------------------------------- |
| `GET  /v1/info`    | —                                 | JSON: protocol, host, backends[]  |
| `POST /v1/exec`    | `{v, argv[], stdin?, timeoutSec?}`| chunked NDJSON event stream       |
| `POST /v1/shutdown`| `{}`                              | `{ok:true}`                       |

`argv` is a full vm-harness CLI invocation *without* the program name, e.g.
`["run","--backend","incus","--baseline","job-42","--ephemeral", ...]`. The
daemon prepends its configured worker executable and runs it, so the executed
backend code is byte-for-byte the local `vm-harness` path.

### `/v1/exec` event stream (NDJSON, one JSON object per chunk)

```
{"v":"1","type":"log","line":"…one merged stdout/stderr line…"}
{"v":"1","type":"log","line":"…"}
{"v":"1","type":"exit","code":0}          ← terminal
```

`{"type":"error","message":"…"}` is emitted if the daemon cannot start the
worker. The worker's stdout and stderr are **merged** in RA1 (follow-up:
framed stdout/stderr separation).

## Auth & network posture

- **Bearer token** (mTLS is the documented alternative; the spec asks for
  "mTLS client-cert OR bearer token"). The token is provisioned via
  `--auth-token-file` (agenix / systemd `LoadCredential` friendly),
  `--auth-token`, or `$VMH_SERVE_TOKEN`.
- **Bind to a NetBird overlay IP only, never a public interface.** Over
  NetBird (WireGuard) the bearer token travels encrypted at the network
  layer — the sanctioned deployment model (campaign non-negotiable pattern
  (a): the control channel is authenticated and NEVER exposed publicly).
- **Optional TLS**: compile with `-d:ssl` and pass `--tls-cert` / `--tls-key`
  to wrap the socket for deployments without an overlay. Default builds omit
  TLS to keep the dependency surface minimal.

## Running the daemon

```sh
vm-harness serve --listen 100.72.0.5:8873 --auth-token-file /run/creds/vmh
# readiness / health: the bound port is written to --port-file when listening.
```

The daemon handles one connection at a time: it drives long-running,
host-mutating VM ops, and serial handling avoids interleaved host mutations
(coordinated *placement* across hosts is the central GARM's job, not this
daemon's).

## Driving a remote host

Any operational subcommand gains a `--remote <host:port>` flag that forwards
it to a daemon and relays the streamed output + exit code:

```sh
export VMH_SERVE_TOKEN=$(cat /run/creds/vmh)
vm-harness --remote 100.72.0.5:8873 probe
vm-harness --remote 100.72.0.5:8873 run --ephemeral --backend incus \
  --baseline job-42 --base-image vmh-base -- true
```

Library consumers (e.g. the future `garm-provider-vmharness` remote mode) use
`ServeClient` directly:

```nim
import vm_harness
let c = newServeClient("100.72.0.5:8873", token)
let info = c.info()                          # capability report
let code = c.execStream(@["run", "--ephemeral", "--backend", "incus",
                          "--baseline", "job-42", "--base-image", "vmh-base",
                          "--", "true"],
                        proc(ev: ExecEvent) =
                          if ev.kind == ekLog: echo ev.line)
```

## Tests

- `tests/unit/t_serve_protocol.nim` — pure wire-contract checks (universal
  layer; in `just test` and the `repro test` catalog).
- `tests/e2e/t_vmharness_serve_roundtrip.nim` — **the RA1 gate.** A remote
  client drives provision → run(exec probe) → destroy against a real daemon
  over the authenticated endpoint using the sanctioned **noop** backend;
  asserts no residue, byte-equivalence to the local `run` path, and that an
  unauthenticated / wrong-credential client is rejected (401). Hermetic via a
  no-threads self-exec topology (the test binary re-execs itself as daemon and
  as CLI worker). In `just test`.
- `tests/e2e/t_vmharness_serve_roundtrip_incus.nim` — the same remote path
  against a **real** incus ephemeral container. Host-gated (`just test-host`),
  self-skips without a usable incus.

## Follow-ups (later milestones / deferred)

- Framed stdout/stderr separation in the exec stream (RA1 merges them).
- Per-op daemon-side timeout enforcement (RA1 relies on the CLI's own
  `--timeout-sec`; the `timeoutSec` field is carried but advisory).
- mTLS client-cert auth + the enrollment/identity model + a richer capability
  manifest (campaign RA6).
- Per-OS deployment of the daemon (systemd / launchd / reprobuild-Windows) is
  campaign RA2–RA5.
