## Backend auto-selection per design doc §6.
##
## Two responsibilities:
##
## 1. Map ``(HostPlatform, GuestOs)`` → ``BackendId`` via the table in
##    ``types.selectBackendId``.
## 2. Construct the chosen backend. Real backends will be added by M1-M5;
##    until then ``newBackend`` raises ``BackendUnavailableError`` for
##    anything besides ``biNoop``. The CLI passes a ``noopFallback=true``
##    flag in tests to let the auto-selection logic be exercised without
##    requiring a real hypervisor on the runner.

import std/[strformat, strutils]
import ./types
import ./backends/noop

type
  BackendFactory* = proc(): VmBackend {.gcsafe.}

var
  factoryRegistry*: array[BackendId, BackendFactory]
    ## Public so the CLI's ``backends`` listing can show which backends
    ## are registered without re-implementing the iteration logic.

proc registerBackend*(id: BackendId, factory: BackendFactory) =
  ## Backends register their constructors here. The library's bootstrap
  ## registers ``biNoop`` unconditionally; the per-backend modules (M1-M5)
  ## register themselves when imported. Re-registering overwrites.
  factoryRegistry[id] = factory

proc registeredBackends*(): seq[BackendId] =
  for id in BackendId:
    if factoryRegistry[id] != nil:
      result.add(id)

proc parseBackendId*(s: string): BackendId =
  ## Parse a backend ID from a CLI string. Raises ``ValueError`` for an
  ## unknown name. The string ``"auto"`` is *not* a backend ID — callers
  ## should branch on it before calling this.
  for id in BackendId:
    if $id == s:
      return id
  raise newException(ValueError, &"Unknown backend: '{s}'. Known: " &
                     ([$biNoop, $biHyperv, $biWsl, $biTartMacos,
                       $biTartLinuxArm, $biUtmWindowsArm, $biQemuWindowsArm,
                       $biQemuBoot, $biLibvirt, $biLima,
                       $biIncus]).join(", "))

proc autoSelectBackendId*(host: HostPlatform, guest: GuestOs): BackendId =
  ## Thin pass-through to ``types.selectBackendId``. Centralized here so
  ## the CLI can swap in a test-time override.
  selectBackendId(host, guest)

proc newBackend*(id: BackendId, noopFallback: bool = false): VmBackend =
  ## Construct a backend instance by ID.
  ##
  ## When ``noopFallback`` is true *and* the requested backend isn't
  ## registered (typical in tests run on a host without that hypervisor),
  ## a ``NoopBackend`` masquerading as the requested ID is returned. The
  ## masquerade tags the noop backend's ``id`` field with the requested
  ## ID so tests that check ``backend.id`` see the auto-selected value.
  ##
  ## The noop fallback exists specifically so ``e2e_vm_harness_auto_
  ## backend_selection`` can exercise the dispatch table on any host
  ## without needing the real hypervisor installed; production callers
  ## never pass ``noopFallback=true``.
  if factoryRegistry[id] != nil:
    return factoryRegistry[id]()
  if noopFallback:
    let n = newNoopBackend()
    n.id = id
    return n
  raise newException(BackendUnavailableError,
    &"Backend '{id}' is not registered on this host. " &
    "If a real implementation should be available, ensure the backend " &
    "module is imported before calling newBackend.")

proc newBackendForGuest*(host: HostPlatform, guest: GuestOs,
                        noopFallback: bool = false): tuple[id: BackendId, backend: VmBackend] =
  ## Convenience: pick the right backend ID for a (host, guest) pair and
  ## construct it. Returns both the picked ID and the live backend so the
  ## caller can log which auto-selection won.
  let id = autoSelectBackendId(host, guest)
  result = (id: id, backend: newBackend(id, noopFallback))

# Bootstrap: NoopBackend is always available.
registerBackend(biNoop, proc(): VmBackend =
  newNoopBackend())
