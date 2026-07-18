## Slice 3 (Composable-Resource-Types.md): vm-harness authors three native
## reprobuild resource providers on slice 2's generic external-provider lane.
##
## Pins:
##   (a) importing `vm_harness/repro/resources` registers the three providers
##       + their attribute marshallers, and the marshallers round-trip attrs
##       by typeId;
##   (b) the typed wrappers build a small dependency graph
##       container -> exec -> snapshot with the right topological order;
##   (c) against REAL incus (when usable) `reconcileResources` launches the
##       container, runs the exec (a marker file appears), and takes the
##       snapshot in dependsOn order — then everything is torn down with a
##       residue check. When incus is unusable the on-incus half is skipped
##       but registration + graph construction + topo order are still pinned.
##
## Throwaway container/snapshot/image names embed the PID so a stray run can
## never collide with live garm/k3s/nomad containers or the `vmh-base` image.

import std/[os, options, tables, strutils, unittest, osproc]

import repro_resources
import repro_project_dsl

import vm_harness/repro/resources as vmh
import vm_harness/backends/incus
import vm_harness/types            # VmHandle

# ---------------------------------------------------------------------------
# Throwaway, PID-tagged names.

let pid = getCurrentProcessId()
let containerName = "vmh-s3-c-" & $pid
let snapName = "s3snap-" & $pid
let publishAlias = "vmh-s3-img-" & $pid
let markerPath = "/opt/vmh-s3-mark-" & $pid

proc incusUsable(): bool =
  ## The real-incus half runs only when the backend can reach the daemon.
  let b = newIncusBackend()   # honours VMH_INCUS_CMD
  try: b.probeAvailability()
  except CatchableError: false

proc bestEffortTeardown() =
  ## Remove any residue this test could have created, regardless of where a
  ## failure landed. Never raises.
  let b = newIncusBackend()
  try: b.removeSnapshot(containerName, snapName)
  except CatchableError: discard
  try: discard b.deleteContainer(containerName)
  except CatchableError: discard
  try: discard b.runIncus(@["image", "delete", publishAlias], timeoutSec = 60)
  except CatchableError: discard

suite "slice 3: vm-harness native resource providers":

  test "importing the module registers all three providers":
    check isResourceProviderRegistered(vmh.TypeContainer)
    check isResourceProviderRegistered(vmh.TypeExec)
    check isResourceProviderRegistered(vmh.TypeSnapshot)
    # Determinism classes per the spec.
    check lookupResourceProvider(vmh.TypeContainer).determinism == rdVolatile
    check lookupResourceProvider(vmh.TypeExec).determinism == rdVolatile
    check lookupResourceProvider(vmh.TypeSnapshot).determinism == rdHostBound
    # Drivers are non-nil vtables.
    check lookupResourceProvider(vmh.TypeContainer).driver.apply != nil
    check lookupResourceProvider(vmh.TypeSnapshot).driver.observe != nil

  test "attribute marshallers round-trip by typeId":
    resetDesiredResources()
    let c = vmh.container("rt", baseImage = "vmh-base", profiles = @["p1"])
    discard vmh.exec("rt-exec", container = c.address,
                     run = @["sh", "-c", "true"], dependsOn = @[c.address])
    discard vmh.snapshot("rt-snap", container = c.address,
                         publishAlias = "img", dependsOn = @[c.address])
    for inst in collectedResources():
      let wire = marshalAttrs(inst.attrs)
      let back = unmarshalAttrs(inst.typeId, wire)
      check back.typeId == inst.typeId
    # Concretely check the container attrs survive the round-trip.
    let cInst = collectedResources()[0]
    let orig = TypedExtensionBox[vmh.ContainerAttrs](cInst.attrs).val
    let got = TypedExtensionBox[vmh.ContainerAttrs](
      unmarshalAttrs(cInst.typeId, marshalAttrs(cInst.attrs))).val
    check got == orig
    check got.baseImage == "vmh-base"
    check got.profiles == @["p1"]

  test "wrappers build a container -> exec -> snapshot graph in topo order":
    resetDesiredResources()
    let base = vmh.container(containerName, baseImage = "vmh-base",
                             profiles = @[])
    let touch = vmh.exec("touch", container = base.address,
                         run = @["sh", "-c", "touch " & markerPath],
                         dependsOn = @[base.address])
    discard vmh.snapshot(snapName, container = base.address,
                         publishAlias = "", dependsOn = @[touch.address])
    let desired = collectedResources()
    check desired.len == 3

    if not incusUsable():
      stderr.writeLine "  [slice3] incus unusable -> asserting graph/topo only"
      # No incus: a real reconcile can't run (drivers hit incus), so assert
      # the collected graph shape + edges here.
      check desired[0].address == containerName
      check desired[1].dependsOn == @[containerName]
      check desired[2].dependsOn == @["touch"]
      skip()
    else:
      stderr.writeLine "  [slice3] incus usable -> running real reconcile on " &
        containerName
      bestEffortTeardown()   # start from a clean slate
      let b = newIncusBackend()
      var ok = false
      try:
        let r = reconcileResources(desired)
        # Three creates, applied in dependency order.
        check r.actions.len == 3
        check r.actions[0].address == containerName   # container first
        check r.actions[1].address == "touch"          # then the exec
        check r.actions[2].address == snapName          # then the snapshot
        for act in r.actions:
          check act.kind == rakCreate

        # The container is live.
        check b.containerExists(containerName)
        # The exec ran: the marker file exists in the guest.
        let mark = b.execInGuest(
          VmHandle(name: containerName, extra: initTable[string, string]()),
          initTable[string, string](),
          @["test", "-f", markerPath])
        check mark.exitCode == 0
        # The snapshot was taken.
        check snapName in b.listSnapshots(containerName)
        ok = true
      finally:
        bestEffortTeardown()

      check ok
      # Residue check: nothing this test made survives teardown.
      check not b.containerExists(containerName)
      check snapName notin b.listSnapshots(containerName)
      let imgs = b.runIncus(@["image", "list", publishAlias,
                              "--format", "csv", "-c", "l"], timeoutSec = 30)
      check imgs.stdout.strip().len == 0

# Final safety net in case a check above raised past the finally.
bestEffortTeardown()
