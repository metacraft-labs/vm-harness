## vm-harness — cross-platform VM lifecycle orchestration for test
## harnesses and dev workflows.
##
## Public surface re-exported from this top-level module:
##
## - Types: ``VmBackend``, ``VmHandle``, ``BaselineSpec``, ``ExecResult``,
##   ``ArgvTraceShim``, the exception hierarchy.
## - Auto-selection: ``autoSelectBackendId``, ``newBackend``,
##   ``newBackendForGuest``, ``registerBackend``.
## - Output envelope: ``OutputEnvelope``, ``Verdict``, ``StepStatus``.
## - Orchestrator: ``GateSpec``, ``GateResult``, ``runGate``.
## - Guest scripts (embedded): ``PosixRunner``, ``WindowsRunner``,
##   ``writeGuestRunner``, ``renderShimScript``.
## - NoopBackend (test fixture): re-exported from ``backends/noop``.
##
## See ``docs/design.md`` for the canonical design reference and the
## per-backend implementation notes.

import ./vm_harness/types
import ./vm_harness/output
import ./vm_harness/auto
import ./vm_harness/orchestrator
import ./vm_harness/guest_scripts
import ./vm_harness/serial
import ./vm_harness/cloud_init_seed
import ./vm_harness/backends/noop
import ./vm_harness/backends/process_helpers
import ./vm_harness/backends/hyperv
import ./vm_harness/backends/wsl
import ./vm_harness/backends/tart
import ./vm_harness/backends/utm
import ./vm_harness/backends/lima

export types
export output
export auto
export orchestrator
export guest_scripts
export serial
export cloud_init_seed
export noop
export process_helpers
export hyperv
export wsl
export tart
export utm
export lima
