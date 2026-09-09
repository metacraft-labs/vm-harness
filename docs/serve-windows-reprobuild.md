# vm-harness serve on Windows, under reprobuild (reusable recipe)

This is the **general, company-agnostic** recipe for running `vm-harness serve`
(the RA1 remoting daemon — see [serve.md](serve.md)) as a Windows service on a
**reprobuild-managed** host (i.e. a box whose system scope is realised by
`repro infra apply` against a `*.nim` profile, *not* by NixOS / nix-darwin).

It is the reprobuild counterpart of the NixOS `services.vm-harness-serve`
module that Linux/darwin hosts get. The two express the same shape — a
hardened, NetBird-only serve daemon with agent-provisioned auth material —
through the deployment system each host actually uses. The CI Runner Fleet
campaign's repo-layering rule keeps this recipe **reusable** (any company can
adopt it) while the concrete Metacraft instantiation lives in
`infra/machines/server/_win-ci-bare-001/system_windows_runner.nim` (the RA4
profile). If you are standing up your own reprobuild-managed Windows VM host,
copy the shape below and fill in your own paths, golden, switch, and NetBird IP.

## What the daemon does on a Windows host

`vm-harness serve --backend hyperv` front-ends this host's **Hyper-V**
lifecycle over an authenticated HTTP/JSON endpoint. The per-job ephemeral
model it drives (`run --ephemeral --backend hyperv`) is:

```
New-VHD (CoW diff / ReFS block-clone of a golden VHDX)
  → New-VM → Start-VM → in-guest JIT probe (PowerShell Direct)
  → Remove-VM + delete the per-job disk        (no residue; golden untouched)
```

These are **host-lifecycle** PowerShell ops running locally on the host (as
distinct from PowerShell-Direct *guest* comms). The golden is a fixed-size
Gen-2 VHDX; on a ReFS Dev Drive the clone is a near-instant block-clone.

## The four reprobuild resources

Declared inside the host profile's `resources:` block. Names are illustrative;
substitute your own constants.

1. **Machine environment** (`windowsRegistryValueHKLM`, `kind = string`, under
   `…\Session Manager\Environment`) — the per-job Hyper-V knobs the serve
   *workers* inherit from the service's process environment:
   `VMH_HYPERV_SWITCH` (the vSwitch the per-job NIC connects to so
   cloudbase-init / the JIT bootstrap reaches the runner-manager metadata
   endpoint) and `VMH_HYPERV_CRED_CACHE` (the PowerShell-Direct credential
   cache used for the in-guest probe). The golden itself is supplied per-job by
   the client as `--golden-image`, so it need not be ambient.

2. **Service installer** (`inlineExecCall`, elevated) — `New-Service` the
   daemon **if absent**, running as **LocalSystem** (Hyper-V host ops need
   admin). `applyWindowsService` reconciles an existing service but refuses to
   *install* one, so a create-if-absent action edge is required first. Phase-G
   ordering runs all action edges before all live-state items, so this precedes
   resource 3 on a cold box. `dependsOn` the Hyper-V role features.

   The service **binPath** is the quoted exe followed by serve arguments —
   `sc.exe` accepts arguments appended to binPath:

   ```
   "C:\dev-deps\vm-harness\bin\vm-harness.exe" serve \
     --listen <BIND>:<PORT> --auth-token-file "<TOKEN_PATH>" --backend hyperv
   ```

3. **Service reconciler** (`windowsService`) — declaratively reconcile
   `startType = Automatic`, `state = Running`, `displayName`, `binPath`, and a
   restart-on-failure recovery policy (60 s backoff × 3, `reset = 3600`), the
   same recovery shape the runner service uses. Keeps the remoting endpoint
   available for the central runner-manager whose provider RPCs to it.

4. **Inbound firewall rule** (`inlineExecCall`, elevated) — allow TCP to the
   serve port **only** from the NetBird overlay (CGNAT range `100.64.0.0/10`),
   as defense-in-depth over the single-address bind. Idempotent (remove +
   recreate). The native `windowsFirewallRule` resource is intentionally *not*
   used here because it cannot scope a rule to a remote address range, and
   NetBird-only scoping is the security-relevant property.

## Auth & network posture (NON-NEGOTIABLE)

- **NetBird-only** (campaign non-negotiable pattern (a)): the daemon binds a
  **single host address** — the NetBird overlay IP — **never `0.0.0.0`**. Until
  the host is NetBird-enrolled, bind **loopback** (`127.0.0.1`) as the fail-safe
  default rather than an empty host that would bind every interface. Flip the
  bind-host constant to the overlay IP at enrollment.
- **Bearer token**, provisioned like every other host secret. On a NixOS host
  that is agenix + systemd `LoadCredential`; on a reprobuild **pull-model** box
  it rides the deploy manifest's **sealed section**, which
  `repro deploy-agent --secrets-dir` materialises **before** the apply, so the
  token file is present when the service starts. `serve --auth-token-file`
  reads it. Over NetBird (WireGuard) the token travels encrypted at the network
  layer.

## Prerequisites on the host

- The Hyper-V role features enabled (`Microsoft-Hyper-V-Hypervisor`,
  `-Services`, `-Management-PowerShell`). A reboot is required before the
  hypervisor is live.
- A `vm-harness` binary in the managed dev-deps tree. Like the `repro` binary
  on such a box, its provisioning (and the golden VHDX + credential-cache
  pipeline) is a bootstrap concern; pin/declare it as your management model
  matures.

## Verifying it

The end-to-end gate is `t_vmharness_serve_win_hyperv`
(`tests/e2e/t_vmharness_serve_win_hyperv.nim`): a remote client drives the
full New-VM-from-golden → boot → JIT-probe → Remove-VM cycle through the
daemon and asserts no residue + 401 on bad credentials. It self-skips off
Windows / without Hyper-V / without `$VMH_HYPERV_GOLDEN`, and runs under
`just test-host`. The host-lifecycle clone/PowerShell logic is unit-tested
off-host by `t_hyperv_ephemeral_clone` (asserts on the emitted PowerShell).
