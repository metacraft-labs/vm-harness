## RP5c1 — vm-harness reprobuild RESOURCE PROVIDER binary.
##
## Compiled with ``-d:reproProviderMode`` (via reprobuild's
## ``compileProviderBinary`` / the RP1 provider-compile edge), this module
## is a provider binary the engine launches with ``--repro-provider-serve``:
##
##   * importing ``./resources`` registers the three vm-harness resource
##     TYPES (``vm_harness.container`` / ``.exec`` / ``.snapshot``) via the
##     RP4 ``resourceType`` macro — provider + attribute marshaller + typed
##     wrapper + protocol entry points;
##   * ``installResourceOpDispatch`` (RP5b) installs the resource-op
##     dispatch hook into the DSL provider serve loop so a
##     ``<typeId>.observe/plan/apply/identity/digest`` InvokeEntryPoint
##     reaches the registered driver (which drives the incus backend HERE,
##     in the provider process);
##   * the ``package`` block makes the DSL emit the provider serve ``main``
##     (``when defined(reproProviderMode) and isMainModule: quit
##     runPackageProvider(...)``), so ``<binary> --repro-provider-serve``
##     runs the RP2 stdio session loop.
##
## The engine process never links the driver bodies — it reconciles a
## desired ``vm_harness.container`` over the protocol, and the launch /
## exec / snapshot effects happen in THIS binary.
##
## Like ``resources.nim`` this module lives OUTSIDE vm-harness's core build
## (``just build`` never compiles it), so the core stays reprobuild-free.

import repro_project_dsl
import repro_resources

# Registers vm_harness.container / .exec / .snapshot at module init.
import ./resources

# RP5b: wire the resource-driver dispatch into the provider serve loop. This
# is also auto-installed at ``repro_resources/protocol`` module init under
# ``reproProviderMode``; calling it explicitly is idempotent and documents the
# provider contract.
when defined(reproProviderMode):
  installResourceOpDispatch()

package `vm_harness_provider`:
  build:
    discard
