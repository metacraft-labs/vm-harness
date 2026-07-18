## Native reprobuild resource providers authored IN vm-harness
## (`Composable-Resource-Types.md` slice 3, re-authored via the RP4
## `resourceType` macro for RP5c1).
##
## This module proves that an EXTERNAL repo can define resource TYPES on
## reprobuild's generic external-provider lane (slice 2,
## `repro_resources`) without any edit to reprobuild's own source. It
## declares three native providers — `vm_harness.container`,
## `vm_harness.exec`, `vm_harness.snapshot` — each via one `resourceType`
## block that lowers to the provider registration + attribute marshaller +
## typed wrapper + `InterfaceResource` contract + the
## `<typeId>.observe/plan/apply` protocol entry points (RP4). Each type
## carries its own typed attribute record and a `{.nimcall.}`
## `ResourceProviderDriver` whose `apply` drives vm-harness's incus
## backend.
##
## RP5c1: the SAME module, compiled into a provider binary with
## `-d:reproProviderMode` (see `provider_main.nim`), serves the driver ops
## over the runtime protocol (RP5b) — the engine reconciles a
## `vm_harness.container` in a SEPARATE process that drives incus.
##
## Deliberately OUT of vm-harness's core build path: this module imports
## `repro_resources` (a reprobuild lib) and is NOT imported by
## `src/vm_harness/cli.nim` or anything `just build` compiles, so the core
## build stays reprobuild-free. It is compiled only with the reprobuild
## `--path` set + full harness env (see the RP5c1 test / campaign notes).
##
## Determinism classes (per `Composable-Resource-Types.md` §Determinism +
## `Edge-Determinism-And-Soft-Rebuild.md` §7):
##   * container — `rdVolatile`: a launched container is a state-transaction
##     output, never a cacheable artifact; re-realized whenever a dependency
##     changed regardless of its own digest.
##   * exec — `rdVolatile`: an in-guest command against a volatile container.
##   * snapshot — `rdHostBound`: reusable ON the realizing host; cross-machine
##     reuse is an explicit opt-in, not the default.

import std/[options, tables, strutils]

import repro_resources
import repro_project_dsl            # registerExtension[T]

import ../backends/incus
import ../types                     # VmHandle, ExecResult

export ResourceRef                  # re-export so wrappers' return type is usable

# ---------------------------------------------------------------------------
# Stable typeIds.

const
  TypeContainer* = "vm_harness.container"
  TypeExec*      = "vm_harness.exec"
  TypeSnapshot*  = "vm_harness.snapshot"

# ---------------------------------------------------------------------------
# Typed attribute records. The resource's ADDRESS (== its identity) is the
# instance address, so it is NOT duplicated as an attribute field; the attrs
# carry only the type-specific configuration.

type
  ContainerAttrs* = object
    ## Attributes of a `vm_harness.container` resource. The container name is
    ## the instance address.
    baseImage*: string       ## base image alias/fingerprint to launch from
    profiles*: seq[string]   ## optional incus profiles

  ExecAttrs* = object
    ## Attributes of a `vm_harness.exec` resource. The exec's logical name is
    ## the instance address.
    container*: string       ## target container's resource address (== name)
    run*: seq[string]        ## argv passed verbatim to `incus exec -- ...`

  SnapshotAttrs* = object
    ## Attributes of a `vm_harness.snapshot` resource. The snapshot name is
    ## the instance address.
    container*: string       ## container to snapshot (its address == name)
    publishAlias*: string    ## when non-empty, publish the snapshot as this
                             ## local image alias

# ---------------------------------------------------------------------------
# Backend construction. Every driver builds a fresh backend so it honours
# ``VMH_INCUS_CMD`` (via ``newIncusBackend`` -> ``resolveIncusCmd``) on
# whatever process runs the reconcile — including the provider process.

proc backend(): IncusBackend =
  newIncusBackend()

proc handleFor(name: string): VmHandle =
  ## A minimal ``VmHandle`` naming an existing container, for the backend
  ## methods (``execInGuest``) that take a handle rather than a bare name.
  VmHandle(name: name, extra: initTable[string, string]())

# ---------------------------------------------------------------------------
# Attribute helpers: unbox ``inst.attrs`` (a ``TypedExtensionBox[T]``).

proc containerAttrs(inst: ResourceInstance): ContainerAttrs =
  TypedExtensionBox[ContainerAttrs](inst.attrs).val

proc execAttrs(inst: ResourceInstance): ExecAttrs =
  TypedExtensionBox[ExecAttrs](inst.attrs).val

proc snapshotAttrs(inst: ResourceInstance): SnapshotAttrs =
  TypedExtensionBox[SnapshotAttrs](inst.attrs).val

# ===========================================================================
# vm_harness.container — rdVolatile
#
# Driver ops are ``{.nimcall.}`` (the vtable + protocol-dispatch contract).
# ===========================================================================

proc containerIdentity(inst: ResourceInstance): string {.nimcall.} =
  inst.address

proc containerDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  ## Digest of (baseImage, profiles). Determinism is rdVolatile, so a
  ## container is re-realized whenever a dependency changed regardless of
  ## this digest; the digest still gives a same-graph cache-hit no-op when
  ## the live container already matches.
  let a = containerAttrs(inst)
  digestString(inst.typeId & "\x00" & a.baseImage & "\x00" & a.profiles.join("\x00"))

proc containerObserve(inst: ResourceInstance;
                      recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = containerAttrs(inst)
  let b = backend()
  if b.containerExists(inst.address):
    result.present = true
    result.digest = containerDigest(inst)   # live == desired once it exists
  else:
    result.present = false

proc containerApply(inst: ResourceInstance; action: ResourceActionKind;
                    observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = containerAttrs(inst)
  let b = backend()
  case action
  of rakDestroy:
    discard b.deleteContainer(inst.address)
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: inst.address, postWriteDigest: containerDigest(inst),
      present: false)
  else:
    # create / update / replace all converge to a fresh launched container.
    let vm = b.provisionEphemeralClone(EphemeralIncusSpec(
      name: inst.address, baseImage: a.baseImage, profiles: a.profiles))
    b.startAndAwaitReady(vm)
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: inst.address, postWriteDigest: containerDigest(inst),
      present: true)

let containerDriver = ResourceProviderDriver(
  identity: containerIdentity,
  digest: containerDigest,
  observe: containerObserve,
  apply: containerApply)

resourceType TypeContainer:
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr baseImage: string
  attr profiles: seq[string]

# ===========================================================================
# vm_harness.exec — rdVolatile
# ===========================================================================

proc execIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = execAttrs(inst)
  a.container & "!" & inst.address

proc execDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = execAttrs(inst)
  digestString(inst.typeId & "\x00" & a.container & "\x00" & a.run.join("\x00"))

proc execObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  ## An exec is a VOLATILE edge with no durable observable of its own — we
  ## do NOT record a completion marker in the guest. It therefore reports
  ## `present = false`, i.e. always-needs-apply: the reconciler creates it
  ## once per reconcile of a fresh graph (and re-runs it whenever the graph
  ## is re-reconciled without a matching recorded binding). This is the
  ## intended rdVolatile semantics — an exec's effect is a state
  ## transaction, not a cacheable artifact.
  result.present = false

proc execApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = execAttrs(inst)
  if action == rakDestroy:
    # Nothing to undo — an exec has no standalone lifecycle to tear down.
    return ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: execIdentity(inst), postWriteDigest: execDigest(inst),
      present: false)
  let b = backend()
  let r = b.execInGuest(handleFor(a.container), initTable[string, string](), a.run)
  if r.exitCode != 0:
    raise newException(CatchableError,
      "vm_harness.exec '" & inst.address & "' in container '" & a.container &
      "' failed (exit " & $r.exitCode & "): " & r.stdout)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: execIdentity(inst), postWriteDigest: execDigest(inst),
    present: true)

let execDriver = ResourceProviderDriver(
  identity: execIdentity,
  digest: execDigest,
  observe: execObserve,
  apply: execApply)

resourceType TypeExec:
  attrs: ExecAttrs
  wrapper: exec
  determinism: rdVolatile
  driver: execDriver
  attr container: string
  attr run: seq[string]

# ===========================================================================
# vm_harness.snapshot — rdHostBound
# ===========================================================================

proc snapshotIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = snapshotAttrs(inst)
  a.container & "/" & inst.address

proc snapshotDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = snapshotAttrs(inst)
  digestString(inst.typeId & "\x00" & a.container & "\x00" & inst.address & "\x00" &
    a.publishAlias)

proc snapshotObserve(inst: ResourceInstance;
                     recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = snapshotAttrs(inst)
  let b = backend()
  if inst.address in b.listSnapshots(a.container):
    result.present = true
    result.digest = snapshotDigest(inst)
  else:
    result.present = false

proc snapshotApply(inst: ResourceInstance; action: ResourceActionKind;
                   observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = snapshotAttrs(inst)
  let b = backend()
  if action == rakDestroy:
    b.removeSnapshot(a.container, inst.address)
    return ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: snapshotIdentity(inst), postWriteDigest: snapshotDigest(inst),
      present: false)
  discard b.snapshot(a.container, inst.address)
  if a.publishAlias.len > 0:
    discard b.publishAsImage(a.container & "/" & inst.address, a.publishAlias)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: snapshotIdentity(inst), postWriteDigest: snapshotDigest(inst),
    present: true)

let snapshotDriver = ResourceProviderDriver(
  identity: snapshotIdentity,
  digest: snapshotDigest,
  observe: snapshotObserve,
  apply: snapshotApply)

resourceType TypeSnapshot:
  attrs: SnapshotAttrs
  wrapper: snapshot
  determinism: rdHostBound
  driver: snapshotDriver
  attr container: string
  attr publishAlias: string
