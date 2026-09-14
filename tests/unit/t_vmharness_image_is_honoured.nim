## Runner-Fleet-M3-ARM-Wave MA0 gate: ``t_vmharness_image_is_honoured``.
##
## The gate has three assertions. Two of them are provider-side (Go) and live
## in ``metacraft-labs/nixos-modules``:
##
##   (a) the local-exec provider passes the configured image on the flag
##       vm-harness actually resolves from
##         -> packages/garm-provider-vmharness/src/internal/backend/
##            vmharness_test.go, ``TestVMHarnessImageIsHonouredLocalExec*``
##   (b) the remote RPC recipe does the same for every non-incus target
##         -> .../internal/backend/remote_test.go,
##            ``TestVMHarnessImageIsHonouredRemoteRecipe*``
##
## Both are run by the nix check ``t_vmharness_image_is_honoured``
## (nixos-modules/checks/vmharness-image-is-honoured.nix).
##
## THIS FILE OWNS ASSERTION (c): *a registry-constructed tart backend with no
## image configured RAISES rather than substituting a default.* It is the half
## of the gate that can only be asserted here, because the substitution
## happened inside ``newTartBackend``/``provisionBaseline``.
##
## WHY IT MATTERS. The cirruslabs default used to apply to registry-built
## backends too. The registry is exactly what the CLI — and therefore
## ``garm-provider-vmharness`` — resolves a backend through, so every
## configuration-driven caller went down the defaulting path. When the provider
## passed the configured image on ``--baseline`` (which cli.nim routes to
## ``BaselineSpec.name``, not ``.sourceImage``) the image was discarded without
## a word and macOS CI ran ``ghcr.io/cirruslabs/macos-tahoe-base`` while every
## configuration file named ``ghcr.io/metacraft-labs/macos-tart-runner``. The
## non-negotiable this restores: a configured image is either honoured or the
## call FAILS — never silently replaced.
##
## Direct construction keeps the default, which is what makes it convenient for
## smoke tests and local experiments; that distinction is asserted here too, so
## the fail-loud behaviour cannot be widened or narrowed unnoticed.

import std/[strutils, tables, tempfiles, os, unittest]
import vm_harness/auto
import vm_harness/backends/tart
import vm_harness/types

proc writeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc emptySpec(name: string): BaselineSpec =
  result = BaselineSpec(name: name)
  result.backendOptions = initTable[string, string]()

suite "t_vmharness_image_is_honoured (c): tart golden image selection":

  test "direct construction keeps the cirruslabs default":
    check newTartBackend(guestOs = goMacos).goldenImage ==
      CirrusLabsMacosGolden
    check newTartBackend(guestOs = goLinux).goldenImage ==
      CirrusLabsLinuxArmGolden

  test "an explicit golden always wins over the default":
    let backend = newTartBackend(
      guestOs = goMacos,
      goldenImage = "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1")
    check backend.goldenImage ==
      "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"

  test "opting out of the default leaves no golden configured":
    check newTartBackend(
      guestOs = goMacos, useDefaultGolden = false).goldenImage == ""
    check newTartBackend(
      guestOs = goLinux, useDefaultGolden = false).goldenImage == ""

  test "registry-built backends have no default golden":
    for id in [biTartMacos, biTartLinuxArm]:
      let backend = TartBackend(newBackend(id))
      check backend.goldenImage == ""

  test "provisionBaseline fails loudly when no image was selected":
    let backend = newTartBackend(guestOs = goMacos, useDefaultGolden = false)
    expect VmHarnessError:
      backend.provisionBaseline(emptySpec("macos-tart-runner"))

  test "a registry-built backend with no image RAISES, never defaults":
    # The gate assertion itself, end to end: take the backend the way the CLI
    # and garm-provider-vmharness take it (through the registry), give it a
    # spec that names a baseline but no source image — precisely the shape the
    # provider used to send — and require an error rather than a boot of the
    # cirruslabs base.
    for id in [biTartMacos, biTartLinuxArm]:
      let backend = TartBackend(newBackend(id))
      var raised = false
      try:
        backend.provisionBaseline(emptySpec("macos-tart-runner"))
      except VmHarnessError as err:
        raised = true
        # The message has to name the fix. An operator who hits this is
        # looking at a lane that just went red on a change of behaviour, and
        # the actionable detail is WHICH flag carries an image.
        check "--source-image" in err.msg
        check "no golden image configured" in err.msg
      check raised
      # And the default must not have been quietly adopted on the way out.
      check backend.goldenImage == ""

  test "provisionBaseline adopts sourceImage over a default":
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let tart = tmp / "tart"
    writeExecutable(tart, "#!/bin/sh\nexit 0\n")

    let backend = newTartBackend(guestOs = goMacos, tartCmd = tart)
    var spec = emptySpec("macos-tart-runner")
    spec.sourceImage = "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"
    backend.provisionBaseline(spec)
    check backend.goldenImage ==
      "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"

  test "a registry-built backend accepts an explicit sourceImage":
    # The other side of the fail-loud change: opting out of the default must
    # not make registry-built backends unusable, or MA2 would have no working
    # tart lane at all.
    let tmp = createTempDir("vmh-tart-unit-", "")
    defer: removeDir(tmp)
    let tart = tmp / "tart"
    writeExecutable(tart, "#!/bin/sh\nexit 0\n")

    let backend = TartBackend(newBackend(biTartMacos))
    backend.tartCmd = tart
    var spec = emptySpec("macos-tart-runner")
    spec.sourceImage = "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"
    backend.provisionBaseline(spec)
    check backend.goldenImage ==
      "ghcr.io/metacraft-labs/macos-tart-runner:tahoe-nix-v1"
