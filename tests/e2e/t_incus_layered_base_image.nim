## t_incus_layered_base_image (reprobuild-specs §7.4 gate).
##
## Proves the "install-once, reuse-everywhere" layered base-image chain on
## the Incus backend against REAL Incus: a base image is a chain of snapshot
## edges, and an edge's cached output (a snapshot) can be published as a
## reusable local base image, exported to a transferable on-disk bundle,
## re-imported by a fresh consumer, and launched — with the edge's mutation
## composing through the whole snapshot → publish → export → import chain.
##
## The chain proven (each step against a genuinely launched container, NOT a
## mock):
##
##   1. Launch ``c1`` from ``vmh-base`` (the empty base).
##   2. Edge A (stand-in for "+reprobuild"): write a distinctive marker file
##      ``/opt/edge-a`` in c1.
##   3. ``snapshot(c1, "edge-a")`` — the edge's cached output.
##   4. ``publishAsImage(c1, "c1/edge-a")`` — the snapshot becomes a reusable
##      local base image (published WHILE c1 keeps running).
##   5. ``exportBaseline(c1, exportDir, "edge-a")`` — the base image becomes a
##      transferable on-disk bundle (manifest + tarball).
##   6. Simulate a FRESH consumer that lacks the published image: delete the
##      published alias, then ``importBaseline(exportDir)`` re-registers it.
##   7. Launch ``c2`` from the imported base-image alias.
##   8. NON-VACUOUS: ``cat /opt/edge-a`` in c2 returns EXACTLY the marker —
##      proving edge A composed through the chain (a bare ``vmh-base``
##      container has NO ``/opt/edge-a``; asserted explicitly on c1 at launch).
##   9. Edge B (+config): write ``/opt/edge-b`` in c2; assert BOTH edge-a and
##      edge-b are present (the layers compose).
##  10. Teardown + residue assertion: no c1/c2, no temp/published images,
##      export dir removed.
##
## Skip/teardown discipline mirrors ``t_vmharness_incus_ephemeral_run``: the
## test self-skips cleanly (quit 0) when not Linux, or Incus is unusable, or
## the ``vmh-base`` image is absent, and ALL created containers + images +
## the export dir are destroyed on exit (even on failure). Unique throwaway
## names embed the PID so this never collides with live containers/images
## (``garm-*``, ``k3s-*``, ``nomad-*``, ``vmh-base``, ``vmh-linux-*``,
## ``ah-*``, ``sc15-*``, ``im2-*``).
##
## Run (from a vm-harness checkout on a Linux host with Incus):
##   export VMH_INCUS_CMD="sudo -n incus"   # only if group not yet active
##   nim r --hints:off tests/e2e/t_incus_layered_base_image.nim

import std/[os, strutils, tables, unittest]
import vm_harness

when not defined(linux):
  echo "[skip] t_incus_layered_base_image: Linux host required"
  quit(0)

let baseImage =
  block:
    let e = getEnv("VMH_INCUS_BASE")
    if e.len > 0: e else: "vmh-base"

let tag = "p" & $getCurrentProcessId()
let c1 = "vmh-layered-c1-" & tag
let c2 = "vmh-layered-c2-" & tag
let bareCheck = "vmh-layered-bare-" & tag
let publishedAlias = "vmh-base-plus-edgea-" & tag
let exportDir = getTempDir() / ("vmh-layered-export-" & tag)

const
  MarkerPath = "/opt/edge-a"
  MarkerText = "REPRO-EDGE-A-COMPOSED"
  EdgeBPath = "/opt/edge-b"
  EdgeBText = "cfg"
  SnapName = "edge-a"

proc b(): IncusBackend =
  newIncusBackend(baseImage = baseImage)

proc imageAliasExists(be: IncusBackend, alias: string): bool =
  let r = be.runIncus(@["image", "list", alias, "--format", "csv", "-c", "l"],
                      timeoutSec = 30)
  r.exitCode == 0 and r.stdout.strip().len > 0

proc launchAndReady(be: IncusBackend, name, image: string): VmHandle =
  result = be.provisionEphemeralClone(
    EphemeralIncusSpec(name: name, baseImage: image))
  be.startAndAwaitReady(result, 60)

proc catFile(be: IncusBackend, vm: VmHandle, path: string): ExecResult =
  be.execInGuest(vm, initTable[string, string](), @["cat", path],
                 timeoutSec = 30)

proc fileAbsent(be: IncusBackend, vm: VmHandle, path: string): bool =
  let r = be.execInGuest(vm, initTable[string, string](),
                         @["test", "-e", path], timeoutSec = 30)
  r.exitCode != 0

proc cleanupAll(be: IncusBackend) =
  ## Destroy every artifact this test could have created. Idempotent and
  ## never raises — safe from a ``finally``.
  for c in [c1, c2, bareCheck]:
    try:
      if be.containerExists(c): discard be.deleteContainer(c)
    except CatchableError: discard
  try:
    if be.imageAliasExists(publishedAlias):
      discard be.runIncus(@["image", "delete", publishedAlias], timeoutSec = 60)
  except CatchableError: discard
  # The transient export alias exportBaseline uses (cleaned by export, but
  # be defensive if a failure left it behind).
  try:
    let exAlias = "vmh-export-" & c1 & "-" & SnapName
    if be.imageAliasExists(exAlias):
      discard be.runIncus(@["image", "delete", exAlias], timeoutSec = 60)
  except CatchableError: discard
  try:
    if dirExists(exportDir): removeDir(exportDir)
  except CatchableError: discard

suite "t_incus_layered_base_image":
  let be = b()

  test "incus usable + base image present (else skip)":
    if not be.probeAvailability():
      echo "[skip] incus daemon not reachable via the configured command " &
           "(set VMH_INCUS_CMD=\"sudo -n incus\" if the incus-admin group " &
           "is not active in this session)"
      skip()
    else:
      var ok = true
      try:
        be.provisionBaseline(BaselineSpec(sourceImage: baseImage,
                                          guestOs: goLinux))
      except CatchableError:
        ok = false
      if not ok:
        echo "[skip] base image '" & baseImage & "' absent; pull it first"
        skip()
      else:
        check ok

  test "snapshot -> publish -> export -> import -> launch composes edge A":
    if not be.probeAvailability():
      echo "[skip] incus not usable"
      skip()
    else:
      var haveImage = true
      try:
        be.provisionBaseline(BaselineSpec(sourceImage: baseImage,
                                          guestOs: goLinux))
      except CatchableError:
        haveImage = false
      if not haveImage:
        echo "[skip] base image '" & baseImage & "' absent"
        skip()
      else:
        # Pre-clean any residue from a crashed prior run.
        cleanupAll(be)
        try:
          # -- (0) A bare vmh-base container has NO /opt/edge-a. This makes
          #        the later c2 assertion genuinely non-vacuous.
          block:
            let bareVm = launchAndReady(be, bareCheck, baseImage)
            check fileAbsent(be, bareVm, MarkerPath)
            be.stopAndCleanup(bareVm, deleteVm = true)

          # -- (1) Launch c1 from the empty base.
          let vm1 = launchAndReady(be, c1, baseImage)

          # -- (2) Edge A: mutate the guest with a distinctive marker.
          let mk = be.execInGuest(vm1, initTable[string, string](),
                                  @["sh", "-c",
                                    "mkdir -p /opt && echo " & MarkerText &
                                    " > " & MarkerPath], timeoutSec = 30)
          check mk.exitCode == 0

          # -- (3) Snapshot the edge output.
          check be.snapshot(c1, SnapName) == SnapName
          check SnapName in be.listSnapshots(c1)

          # -- (4) Publish the snapshot as a reusable local base image while
          #        c1 keeps running (clean path).
          let alias = be.publishAsImage(c1 & "/" & SnapName, publishedAlias)
          check alias == publishedAlias
          check be.imageAliasExists(publishedAlias)
          # c1 is undisturbed by publishing from its snapshot.
          check be.containerState(c1) == "RUNNING"

          # -- (5) Export the base image to a transferable on-disk bundle.
          be.exportBaseline(c1, exportDir, SnapName)
          check fileExists(exportDir / "incus-baseline.manifest")
          # The manifest records the tarball name; assert it exists on disk.
          var tarball = ""
          for line in readFile(exportDir /
              "incus-baseline.manifest").splitLines():
            if line.startsWith("tarball="):
              tarball = line["tarball=".len .. ^1]
          check tarball.len > 0
          check fileExists(exportDir / tarball)

          # -- (6) Simulate a FRESH consumer lacking the published image:
          #        delete the alias, then re-import from the bundle.
          discard be.runIncus(@["image", "delete", publishedAlias],
                              timeoutSec = 60)
          check (not be.imageAliasExists(publishedAlias))
          let imported = be.importBaseline(exportDir)
          # importBaseline re-registers the base image under the alias its
          # bundle manifest recorded and RETURNS it — the consumer uses that
          # returned name, never a hardcoded one (the producer's local publish
          # alias was deleted just above to simulate a fresh consumer that only
          # has the on-disk bundle).
          check imported.len == 1
          let importedAlias = imported[0]
          check be.imageAliasExists(importedAlias)

          # -- (7) Launch c2 from the IMPORTED base-image alias.
          let vm2 = launchAndReady(be, c2, importedAlias)

          # -- (8) NON-VACUOUS: edge A composed through the whole chain.
          let ea = catFile(be, vm2, MarkerPath)
          check ea.exitCode == 0
          check ea.stdout.strip() == MarkerText

          # -- (9) Edge B (+config): layer another edge on top; assert BOTH
          #        edge-a and edge-b are present (layers compose).
          let mkB = be.execInGuest(vm2, initTable[string, string](),
                                   @["sh", "-c",
                                     "echo " & EdgeBText & " > " & EdgeBPath],
                                   timeoutSec = 30)
          check mkB.exitCode == 0
          let eaAgain = catFile(be, vm2, MarkerPath)
          check eaAgain.exitCode == 0
          check eaAgain.stdout.strip() == MarkerText
          let eb = catFile(be, vm2, EdgeBPath)
          check eb.exitCode == 0
          check eb.stdout.strip() == EdgeBText
        finally:
          cleanupAll(be)

        # -- (10) Residue assertion: nothing this test made survives.
        check (not be.containerExists(c1))
        check (not be.containerExists(c2))
        check (not be.containerExists(bareCheck))
        check (not be.imageAliasExists(publishedAlias))
        check (not be.imageAliasExists("vmh-export-" & c1 & "-" & SnapName))
        check (not dirExists(exportDir))
