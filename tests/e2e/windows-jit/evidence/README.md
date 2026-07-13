# M3 gate evidence (t_windows_golden_jit_boot)

Captured from live runs of the cloudbase-init golden clone against the mock
GARM metadata+actions endpoint. These are REFERENCE artifacts (the gate
regenerates equivalent evidence on every run); they document the mechanism.

- `bootstrap.log` — the GARM-style Windows JIT bootstrap running in the guest:
  fetches cert-bundle + .runner/.credentials/.credentials_rsaparams +
  service-name from the mock metadata endpoint (each JWT-authorized), then
  launches Runner.Listener with the injected JIT config.
- `runner_diag.txt` — Runner.Listener's own _diag log: reads the JIT
  .runner/.credentials, builds a VssConnection to the mock as its Actions
  server (Location.GetConnectionData), and calls MessageListener.
  CreateSessionAsync (i.e. reaches the "configured / listening for one job"
  phase). The only thing that stops a literal "Listening for Jobs" line is the
  mock not fully reimplementing GitHub's proprietary Azure-DevOps location
  service — NOT any deficiency in the golden / config-drive / JIT delivery.
- `mock-audit.json` — the mock's request audit: which routes the guest pulled,
  which were JWT-authorized (200) vs unauthorized (401).
