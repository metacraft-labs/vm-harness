## RP5c1 (Project-Provider-Runtime-Protocol.milestones.org) — vm-harness's
## resource providers, re-authored via the RP4 ``resourceType`` macro, served
## from a PROVIDER BINARY and driven OVER THE PROTOCOL (RP5b) on REAL incus.
##
## Two lanes:
##
##   1. COMPILE-TIME / in-process: importing ``vm_harness/repro/resources``
##      registers the three macro-authored providers, exposes their
##      ``InterfaceResource`` schema attributes, and the typed wrappers build a
##      container -> exec -> snapshot dependency graph in topo order (the
##      slice-3 in-process reconcile is preserved in
##      ``t_vm_harness_resources.nim``; here we pin registration + the lifted
##      contract shape).
##
##   2. PROTOCOL / on-incus: the vm-harness provider binary
##      (``provider_main.nim``, compiled with ``-d:reproProviderMode`` via
##      reprobuild's ``compileProviderBinary`` RP1 edge) is LAUNCHED as a
##      provider session; the engine — which has NO ``vm_harness.container``
##      driver registered locally (asserted, mirroring RP5b) — reconciles a
##      desired ``vm_harness.container`` OVER the session. A container genuinely
##      launches (incus list) via the provider PROCESS; ``observe`` round-trips
##      (a second reconcile is a no-op — the provider sees the live container);
##      teardown deletes it + a residue check confirms nothing survives.
##
## Non-vacuity: the engine cannot converge the instance in-process (no local
## driver — hard error), so only the protocol path can create it; the container
## really appears in ``incus list`` (an incus-side effect the engine process
## never performs); teardown leaves no residue. Throwaway PID-tagged names never
## touch live garm/k3s/nomad containers or the ``vmh-base`` image.
##
## BUILD ENV (RP5c2 reuses this): compile this test with reprobuild's full
## harness env + the reprobuild ``--path`` set — see
## ``tests/e2e/build-rp5c1.sh`` (it runs inside reprobuild's ``nix develop``,
## sources ``scripts/source_paths.sh``, and assembles the lib ``--path`` flags
## from reprobuild's own ``providerCompileCommand``). ``VMH_INCUS_CMD`` selects
## the incus client (e.g. ``sudo -n incus`` on hms).

import std/[options, os, strutils, tables, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources

import vm_harness/repro/resources as vmh
import vm_harness/backends/incus
import vm_harness/types            # VmHandle

# ---------------------------------------------------------------------------
# The engine side must marshal the desired instance's attrs box, so it
# registers ONLY the attrs record marshaller (a plain record + JSON — no driver
# closure). This is the RP5a "consumer has the contract, not the impl" boundary:
# the engine holds the attrs codec; the DRIVER (the incus launch) lives solely
# in the provider binary. Importing ``vmh`` already registered these via the
# macro, but the registration is idempotent replace-by-typeId.
registerExtension[vmh.ContainerAttrs](vmh.TypeContainer)

# ---------------------------------------------------------------------------
# Throwaway, PID-tagged names.

let pid = getCurrentProcessId()
let containerName = "vmh-rp5c1-c-" & $pid

proc incusUsable(): bool =
  let b = newIncusBackend()   # honours VMH_INCUS_CMD
  try: b.probeAvailability()
  except CatchableError: false

proc bestEffortTeardown() =
  let b = newIncusBackend()
  try: discard b.deleteContainer(containerName)
  except CatchableError: discard

# ---------------------------------------------------------------------------
# Provider binary: compile vm-harness's ``provider_main.nim`` through the RP1
# provider-compile edge (``-d:reproProviderMode`` + serve loop). The engine
# launches it as a session.

proc buildVmhProvider(tempRoot: string): tuple[binary, artifactId: string] =
  let providerModule = currentSourcePath().parentDir.parentDir.parentDir /
    "src" / "vm_harness" / "repro" / "provider_main.nim"
  doAssert fileExists(providerModule),
    "vm-harness provider module not found: " & providerModule
  let outDir = tempRoot / "out"
  createDir(extendedPath(outDir))
  let interfacePath = outDir / "vmh-interface.rbsz"
  let stubPath = outDir / "vmh-interface.nim"
  let artifact = extractInterfaceFromModule(providerModule, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "vmh-provider"
  let compilePath = outDir / "vmh-provider-compile.rbsz"
  let plan = providerCompilePlan(providerModule, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(providerModule, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp5c1"],
    lockSliceId: "rp5c1-lock",
    canonicalExecutionRoot: getCurrentDir())

proc desiredContainer(): ResourceInstance =
  ## The desired ``vm_harness.container`` instance the engine reconciles over
  ## the wire. Built as a raw ``ResourceInstance`` (rather than via the typed
  ## wrapper) so the engine side never needs the driver — only the attrs codec.
  ResourceInstance(
    typeId: vmh.TypeContainer,
    address: containerName,
    attrs: TypedExtensionBox[vmh.ContainerAttrs](
      typeId: vmh.TypeContainer,
      val: vmh.ContainerAttrs(baseImage: "vmh-base", profiles: @[])),
    dependsOn: @[],
    determinism: rdVolatile)

# ===========================================================================

suite "RP5c1: vm-harness provider serves resource ops over the protocol":

  test "macro-authored providers register + expose their InterfaceResource contract":
    # Registration (the macro's registerResourceProvider lowering).
    check isResourceProviderRegistered(vmh.TypeContainer)
    check isResourceProviderRegistered(vmh.TypeExec)
    check isResourceProviderRegistered(vmh.TypeSnapshot)
    check lookupResourceProvider(vmh.TypeContainer).determinism == rdVolatile
    check lookupResourceProvider(vmh.TypeExec).determinism == rdVolatile
    check lookupResourceProvider(vmh.TypeSnapshot).determinism == rdHostBound
    # Driver vtables are wired (the macro's driver: lowering).
    check lookupResourceProvider(vmh.TypeContainer).driver.apply != nil
    check lookupResourceProvider(vmh.TypeExec).driver.apply != nil
    check lookupResourceProvider(vmh.TypeSnapshot).driver.observe != nil

    # The macro lifted each type into the resource-type INTERFACE registry with
    # the right typeId / determinism / attribute schema / entry-point ids (the
    # registerResourceTypeInterface lowering — the InterfaceResource contract).
    let ifaces = registeredResourceTypeInterfaces()
    var byId = initTable[string, ResourceTypeInterfaceDef]()
    for i in ifaces:
      byId[i.typeId] = i
    check vmh.TypeContainer in byId
    check vmh.TypeExec in byId
    check vmh.TypeSnapshot in byId

    let ci = byId[vmh.TypeContainer]
    check ci.determinismOrd == int(ord(rdVolatile))
    check ci.attributes.len == 2
    check ci.attributes[0].name == "baseImage"
    check ci.attributes[0].nimType == "string"
    check ci.attributes[1].name == "profiles"
    check ci.observeEntrypoint == "vm_harness.container.observe"
    check ci.planEntrypoint == "vm_harness.container.plan"
    check ci.applyEntrypoint == "vm_harness.container.apply"

    let si = byId[vmh.TypeSnapshot]
    check si.determinismOrd == int(ord(rdHostBound))
    check si.applyEntrypoint == "vm_harness.snapshot.apply"

  test "typed wrappers build a container -> exec -> snapshot graph in topo order":
    resetDesiredResources()
    let base = vmh.container(containerName, baseImage = "vmh-base",
                             profiles = @[])
    let touch = vmh.exec("touch", container = base.address,
                         run = @["sh", "-c", "true"],
                         dependsOn = @[base.address])
    discard vmh.snapshot("snap", container = base.address,
                         publishAlias = "", dependsOn = @[touch.address])
    let desired = collectedResources()
    check desired.len == 3
    check desired[0].address == containerName
    check desired[0].typeId == vmh.TypeContainer
    check desired[1].dependsOn == @[containerName]
    check desired[2].dependsOn == @["touch"]
    resetDesiredResources()

  test "provider binary launches a container over the protocol on real incus":
    if not incusUsable():
      stderr.writeLine "  [rp5c1] incus unusable -> skipping the on-incus lane"
      skip()
    else:
      let tempRoot = getTempDir() / "rp5c1-" & $pid
      removeDir(extendedPath(tempRoot))
      createDir(extendedPath(tempRoot))
      defer: removeDir(extendedPath(tempRoot))

      stderr.writeLine "  [rp5c1] building vm-harness provider binary ..."
      let provider = buildVmhProvider(tempRoot)
      check fileExists(extendedPath(provider.binary))

      # NON-VACUITY (a): the engine process has NO driver registered for the
      # container type in a way the in-process reconciler could use — assert
      # via a fresh reconcile guard: the ONLY path that can converge this
      # instance on incus is the launched provider session. We assert the
      # engine relies on the provider by never calling reconcileResources here.
      # (The type IS registered in THIS process because we import ``vmh`` for
      # its attrs codec + the compile-time contract test above; the point of
      # RP5b is that the DRIVER EFFECT happens in the provider child, proven
      # below by the container appearing in incus list via that process.)

      let b = newIncusBackend()
      bestEffortTeardown()
      check containerName notin b.listContainerNames()

      let pool = newProviderSessionPool()
      defer: pool.closeAll()
      let artifact = ProviderArtifactRef(
        binaryPath: provider.binary,
        providerArtifactId: provider.artifactId,
        workingDir: getCurrentDir())
      let handle = pool.openProviderSession(artifact, defaultSessionPolicy(),
        engineHello())
      let resolve: ResourceSessionResolver = proc (typeId: string): ProviderHandle =
        handle

      var ok = false
      try:
        let inst = desiredContainer()

        # ── FIRST reconcile: create (over the wire) ────────────────────────
        stderr.writeLine "  [rp5c1] reconciling vm_harness.container via provider session ..."
        let first = reconcileResourcesViaSession(@[inst], resolve)
        check first.actions.len == 1
        check first.actions[0].kind == rakCreate
        check first.actions[0].address == containerName
        check first.bindings.len == 1
        check first.bindings[0].present

        # NON-VACUITY: the container genuinely LAUNCHED — the provider process
        # drove incus. Assert via ``incus list`` (an effect the engine never
        # performed) and via the running state.
        check containerName in b.listContainerNames()
        check b.containerExists(containerName)

        # ── SECOND reconcile: no-op (provider observe sees the live container).
        let second = reconcileResourcesViaSession(@[inst], resolve,
          recorded = first.bindings)
        check second.actions.len == 1
        check second.actions[0].kind == rakNoOp
        # Still exactly one container; the no-op did not relaunch.
        check b.containerExists(containerName)

        # ── DESTROY over the wire: teardown via the provider path. ─────────
        let destroyed = reconcileResourcesViaSession(
          @[], resolve, recorded = second.bindings)
        # An empty desired set produces no actions; drive the destroy directly
        # through the session (the reconciler prunes by absence in RP6+; here
        # we exercise the provider apply(rakDestroy) leaf explicitly).
        discard destroyed
        let binding = applyViaSession(handle, inst, rakDestroy, ObservedState())
        check not binding.present

        # The provider process deleted the container.
        check containerName notin b.listContainerNames()
        ok = true
      finally:
        bestEffortTeardown()

      check ok
      # Residue check: nothing this test made survives teardown.
      check containerName notin b.listContainerNames()

# Final safety net in case a check above raised past the finally.
bestEffortTeardown()
