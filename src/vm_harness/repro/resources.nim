## Native reprobuild resource providers authored IN vm-harness
## (`Composable-Resource-Types.md` slice 3).
##
## This module proves that an EXTERNAL repo can define resource TYPES on
## reprobuild's generic external-provider lane (slice 2,
## `repro_resources`) without any edit to reprobuild's own source: it
## registers three native providers — `vm_harness.container`,
## `vm_harness.exec`, `vm_harness.snapshot` — each carrying its own typed
## attribute record, a `ResourceProviderDriver` whose `apply` drives
## vm-harness's incus backend, and a thin typed wrapper proc a consumer
## (infra, slice 4) calls to build a resource graph.
##
## Deliberately OUT of vm-harness's core build path: this module imports
## `repro_resources` (a reprobuild lib) and is NOT imported by
## `src/vm_harness/cli.nim` or anything `just build` compiles, so the core
## build stays reprobuild-free. It is compiled only with the reprobuild
## `--path` set (see the slice-3 test / campaign notes).
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
# Typed attribute records.

type
  ContainerAttrs* = object
    ## Attributes of a `vm_harness.container` resource.
    name*: string            ## container name == real-world identity
    baseImage*: string       ## base image alias/fingerprint to launch from
    profiles*: seq[string]   ## optional incus profiles

  ExecAttrs* = object
    ## Attributes of a `vm_harness.exec` resource.
    name*: string            ## logical name of this exec step
    container*: string       ## target container's resource address (== name)
    run*: seq[string]        ## argv passed verbatim to `incus exec -- ...`

  SnapshotAttrs* = object
    ## Attributes of a `vm_harness.snapshot` resource.
    name*: string            ## snapshot name
    container*: string       ## container to snapshot (its address == name)
    publishAlias*: string    ## when non-empty, publish the snapshot as this
                             ## local image alias

# ---------------------------------------------------------------------------
# Backend construction. Every driver builds a fresh backend so it honours
# ``VMH_INCUS_CMD`` (via ``newIncusBackend`` -> ``resolveIncusCmd``) on
# whatever process runs the reconcile.

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
# ===========================================================================

proc containerIdentity(inst: ResourceInstance): string =
  containerAttrs(inst).name

proc containerDigest(inst: ResourceInstance): Digest256 =
  ## Digest of (baseImage, profiles). Determinism is rdVolatile, so a
  ## container is re-realized whenever a dependency changed regardless of
  ## this digest; the digest still gives a same-graph cache-hit no-op when
  ## the live container already matches.
  let a = containerAttrs(inst)
  digestString(inst.typeId & "\x00" & a.baseImage & "\x00" & a.profiles.join("\x00"))

proc containerObserve(inst: ResourceInstance;
                      recorded: Option[ResourceBinding]): ObservedState =
  let a = containerAttrs(inst)
  let b = backend()
  if b.containerExists(a.name):
    result.present = true
    result.digest = containerDigest(inst)   # live == desired once it exists
  else:
    result.present = false

proc containerApply(inst: ResourceInstance; action: ResourceActionKind;
                    observed: ObservedState): ResourceBinding =
  let a = containerAttrs(inst)
  let b = backend()
  case action
  of rakDestroy:
    discard b.deleteContainer(a.name)
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: a.name, postWriteDigest: containerDigest(inst),
      present: false)
  else:
    # create / update / replace all converge to a fresh launched container.
    let vm = b.provisionEphemeralClone(EphemeralIncusSpec(
      name: a.name, baseImage: a.baseImage, profiles: a.profiles))
    b.startAndAwaitReady(vm)
    result = ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: a.name, postWriteDigest: containerDigest(inst),
      present: true)

proc container*(name: string; baseImage: string;
                profiles: seq[string] = @[]): ResourceRef =
  ## Typed wrapper: a launched incus container. Its `.address` (== name)
  ## seeds a dependent `exec`/`snapshot`'s `dependsOn`.
  resource(TypeContainer, name,
           ContainerAttrs(name: name, baseImage: baseImage, profiles: profiles))

# ===========================================================================
# vm_harness.exec — rdVolatile
# ===========================================================================

proc execIdentity(inst: ResourceInstance): string =
  let a = execAttrs(inst)
  a.container & "!" & a.name

proc execDigest(inst: ResourceInstance): Digest256 =
  let a = execAttrs(inst)
  digestString(inst.typeId & "\x00" & a.container & "\x00" & a.run.join("\x00"))

proc execObserve(inst: ResourceInstance;
                 recorded: Option[ResourceBinding]): ObservedState =
  ## An exec is a VOLATILE edge with no durable observable of its own — we
  ## do NOT record a completion marker in the guest. It therefore reports
  ## `present = false`, i.e. always-needs-apply: the reconciler creates it
  ## once per reconcile of a fresh graph (and re-runs it whenever the graph
  ## is re-reconciled without a matching recorded binding). This is the
  ## intended rdVolatile semantics — an exec's effect is a state
  ## transaction, not a cacheable artifact.
  result.present = false

proc execApply(inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState): ResourceBinding =
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

proc exec*(name: string; container: string; run: seq[string];
           dependsOn: seq[string] = @[]): ResourceRef =
  ## Typed wrapper: run `run` (argv) inside `container`. The container it
  ## runs in is expressed as a `dependsOn` edge so the reconciler launches
  ## the container first.
  resource(TypeExec, name,
           ExecAttrs(name: name, container: container, run: run), dependsOn)

# ===========================================================================
# vm_harness.snapshot — rdHostBound
# ===========================================================================

proc snapshotIdentity(inst: ResourceInstance): string =
  let a = snapshotAttrs(inst)
  a.container & "/" & a.name

proc snapshotDigest(inst: ResourceInstance): Digest256 =
  let a = snapshotAttrs(inst)
  digestString(inst.typeId & "\x00" & a.container & "\x00" & a.name & "\x00" &
    a.publishAlias)

proc snapshotObserve(inst: ResourceInstance;
                     recorded: Option[ResourceBinding]): ObservedState =
  let a = snapshotAttrs(inst)
  let b = backend()
  if a.name in b.listSnapshots(a.container):
    result.present = true
    result.digest = snapshotDigest(inst)
  else:
    result.present = false

proc snapshotApply(inst: ResourceInstance; action: ResourceActionKind;
                   observed: ObservedState): ResourceBinding =
  let a = snapshotAttrs(inst)
  let b = backend()
  if action == rakDestroy:
    b.removeSnapshot(a.container, a.name)
    return ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: snapshotIdentity(inst), postWriteDigest: snapshotDigest(inst),
      present: false)
  discard b.snapshot(a.container, a.name)
  if a.publishAlias.len > 0:
    discard b.publishAsImage(a.container & "/" & a.name, a.publishAlias)
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: snapshotIdentity(inst), postWriteDigest: snapshotDigest(inst),
    present: true)

proc snapshot*(name: string; container: string; publishAlias: string = "";
               dependsOn: seq[string] = @[]): ResourceRef =
  ## Typed wrapper: an incus snapshot of `container` (host-bound), optionally
  ## published as a reusable local image alias.
  resource(TypeSnapshot, name,
           SnapshotAttrs(name: name, container: container,
                         publishAlias: publishAlias), dependsOn)

# ===========================================================================
# Registration.
# ===========================================================================

proc registerVmHarnessResourceProviders*() =
  ## Register all three providers + their attribute marshallers. Called at
  ## module init below, so importing this module is enough to make the
  ## types available to the reconciler (mirror of slice 2's pattern). Safe
  ## to call again (e.g. from a test setup): registration is idempotent
  ## replace-by-typeId, and `registerExtension` is required per-thread
  ## because the extension registry is a threadvar.
  registerResourceProvider(ResourceProviderDef(
    typeId: TypeContainer,
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: containerIdentity,
      digest: containerDigest,
      observe: containerObserve,
      apply: containerApply)))
  registerExtension[ContainerAttrs](TypeContainer)

  registerResourceProvider(ResourceProviderDef(
    typeId: TypeExec,
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: execIdentity,
      digest: execDigest,
      observe: execObserve,
      apply: execApply)))
  registerExtension[ExecAttrs](TypeExec)

  registerResourceProvider(ResourceProviderDef(
    typeId: TypeSnapshot,
    determinism: rdHostBound,
    driver: ResourceProviderDriver(
      identity: snapshotIdentity,
      digest: snapshotDigest,
      observe: snapshotObserve,
      apply: snapshotApply)))
  registerExtension[SnapshotAttrs](TypeSnapshot)

registerVmHarnessResourceProviders()
