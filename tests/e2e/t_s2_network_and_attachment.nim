## S2 (network-primitive) gate — Incus managed networks + container network
## attachment expressed as reprobuild resources, verified on REAL incus.
##
## Offline-Production-Topology-Simulation.milestones.org §S2.
##
## Model: network attachment is a SIBLING `vm_harness.nic` resource (a NIC
## device that attaches a container to a managed network), NOT a container
## attribute. This keeps `vm_harness.container` byte-for-byte unchanged (an
## existing container declaration compiles + behaves identically — the S2
## non-regression contract) and expresses attachment as first-class graph
## edges: a nic `dependsOn` BOTH its container and its network.
##
## What this pins:
##
##   1. REGISTRATION: importing `vm_harness/repro/resources` registers the new
##      `vm_harness.network` (rdHostBound) + `vm_harness.nic` (rdVolatile)
##      providers, and their attrs marshallers round-trip.
##
##   2. GRAPH: the typed `network(...)`, `container(...)`, `nic(...)` wrappers
##      build a graph `network + container -> nic` where the nic dependsOn both.
##
##   3. ON-INCUS (when usable): the graph is reconciled on real incus via
##      `reconcileResources` (real drivers drive incus). Then, ON REAL INCUS,
##      assert NON-VACUOUSLY:
##        * the network exists with the expected CIDR
##          (`incus network get <net> ipv4.address`);
##        * the container is attached — the NIC device is present
##          (`incus config device list <c>` shows it), and the guest actually
##          SEES the interface (`ip link show <dev>` succeeds in-guest).
##      Teardown destroys the resources; a residue check confirms the throwaway
##      network + container are gone.
##
## SAFETY: every throwaway name embeds the PID (`s2net-<pid>`, `s2c-<pid>`), is
## checked to NOT already exist before creation, and teardown only ever touches
## those names — NEVER the live bridges (incusbr0 / lxdbr0) or any pre-existing
## network/container. The test asserts the live bridges are untouched.

import std/[os, options, tables, strutils, unittest]

import repro_resources
import repro_project_dsl

import vm_harness/repro/resources as vmh
import vm_harness/backends/incus
import vm_harness/types            # VmHandle

# ---------------------------------------------------------------------------
# Throwaway, PID-tagged names + the CIDR under test.

let pid = getCurrentProcessId()
let netName = "s2net-" & $pid
let containerName = "s2c-" & $pid
let nicDevice = "eth1"            # an ADDITIONAL NIC device (eth0 = default profile)
# A high, unusual /24 unlikely to collide with the topology's 10.81.x scheme or
# the live GARM bridges; passed verbatim as ipv4.address (gateway + subnet).
let cidr = "10.211." & $(pid mod 250) & ".1/24"

# Live bridges we must never touch — asserted present + untouched at the end.
const LiveBridges = ["incusbr0", "lxdbr0"]

proc incusUsable(): bool =
  let b = newIncusBackend()   # honours VMH_INCUS_CMD
  try: b.probeAvailability()
  except CatchableError: false

proc bestEffortTeardown() =
  ## Remove any residue this test could have created, regardless of where a
  ## failure landed. ONLY the throwaway names. Never raises. Deleting the
  ## container drops its NIC device too; then the network is free to delete.
  let b = newIncusBackend()
  try: discard b.deleteContainer(containerName)
  except CatchableError: discard
  try: discard b.deleteNetwork(netName)
  except CatchableError: discard

suite "S2: network + NIC attachment as reprobuild resources":

  test "importing the module registers the network + nic providers":
    check isResourceProviderRegistered(vmh.TypeNetwork)
    check isResourceProviderRegistered(vmh.TypeNic)
    check lookupResourceProvider(vmh.TypeNetwork).determinism == rdHostBound
    check lookupResourceProvider(vmh.TypeNic).determinism == rdVolatile
    check lookupResourceProvider(vmh.TypeNetwork).driver.apply != nil
    check lookupResourceProvider(vmh.TypeNic).driver.apply != nil

  test "network + nic attrs round-trip; nic dependsOn container + network":
    resetDesiredResources()
    let net = vmh.network(netName, cidr = cidr, config = @["ipv4.dhcp=false"])
    let c = vmh.container(containerName, baseImage = "vmh-base", profiles = @[])
    discard vmh.nic("nic0", container = c.address, network = net.address,
                    device = nicDevice,
                    dependsOn = @[c.address, net.address])
    let g = collectedResources()
    check g.len == 3
    # network round-trips.
    let nInst = g[0]
    check nInst.typeId == vmh.TypeNetwork
    let nBack = TypedExtensionBox[vmh.NetworkAttrs](
      unmarshalAttrs(nInst.typeId, marshalAttrs(nInst.attrs))).val
    check nBack.cidr == cidr
    check nBack.config == @["ipv4.dhcp=false"]
    # nic round-trips + depends on both container and network.
    let nicInst = g[2]
    check nicInst.typeId == vmh.TypeNic
    let nicBack = TypedExtensionBox[vmh.NicAttrs](
      unmarshalAttrs(nicInst.typeId, marshalAttrs(nicInst.attrs))).val
    check nicBack.container == containerName
    check nicBack.network == netName
    check nicBack.device == nicDevice
    check containerName in nicInst.dependsOn
    check netName in nicInst.dependsOn
    resetDesiredResources()

  test "reconcile creates the network + attaches the container on real incus":
    resetDesiredResources()
    let net = vmh.network(netName, cidr = cidr, config = @[])
    let c = vmh.container(containerName, baseImage = "vmh-base", profiles = @[])
    discard vmh.nic("nic0", container = c.address, network = net.address,
                    device = nicDevice, dependsOn = @[c.address, net.address])
    let desired = collectedResources()
    check desired.len == 3

    if not incusUsable():
      stderr.writeLine "  [s2] incus unusable -> asserting graph/topo only"
      check desired[0].typeId == vmh.TypeNetwork
      check desired[2].typeId == vmh.TypeNic
      check containerName in desired[2].dependsOn
      check netName in desired[2].dependsOn
      skip()
    else:
      let b = newIncusBackend()

      # Pre-flight: the live bridges must exist (so "untouched" is meaningful)
      # and our throwaway names must NOT collide with anything already present.
      let netsBefore = b.listNetworks()
      for br in LiveBridges:
        check br in netsBefore
      check netName notin netsBefore
      check containerName notin b.listContainerNames()

      bestEffortTeardown()   # belt + braces from a stray prior run
      var ok = false
      try:
        let r = reconcileResources(desired)
        # Three creates, applied in dependency order: network + container (in
        # either order — both roots), then the nic that dependsOn both.
        check r.actions.len == 3
        for act in r.actions:
          check act.kind == rakCreate
        check r.actions[2].address == "nic0"   # nic reconciled LAST

        # NON-VACUITY (network + CIDR): the managed network exists AND carries
        # the CIDR we asked for.
        check b.networkExists(netName)
        check b.networkConfigGet(netName, "ipv4.address") == cidr

        # NON-VACUITY (attachment): the container is live and the NIC device is
        # attached on our network.
        check b.containerExists(containerName)
        check nicDevice in b.listDevices(containerName)
        # The NIC's network is genuinely ours (the device's network= key).
        let devShow = b.runIncus(@["config", "device", "get", containerName,
                                   nicDevice, "network"], timeoutSec = 30)
        check devShow.stdout.strip() == netName
        # The guest actually SEES the interface (non-vacuous: the NIC took
        # effect inside the container, not just in incus config).
        let linkR = b.execInGuest(
          VmHandle(name: containerName, extra: initTable[string, string]()),
          initTable[string, string](), @["ip", "link", "show", nicDevice])
        check linkR.exitCode == 0

        ok = true
      finally:
        bestEffortTeardown()

      check ok
      # Residue check: nothing this test made survives teardown.
      check not b.containerExists(containerName)
      check not b.networkExists(netName)
      check containerName notin b.listContainerNames()
      check netName notin b.listNetworks()

      # Live bridges untouched: still present after our full create/teardown.
      let netsAfter = b.listNetworks()
      for br in LiveBridges:
        check br in netsAfter

# Final safety net.
bestEffortTeardown()
