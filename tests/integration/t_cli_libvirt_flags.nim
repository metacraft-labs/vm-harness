## CLI flag-plumbing test for the libvirt M4 canonical command.
##
## The libvirt M4 slice ships with a "canonical" operator command
## documented in both docs/m4-libvirt.md and the windows-runner-001
## prototype README:
##
##   vm-harness provision \
##       --backend libvirt \
##       --recipe windows-x64-base \
##       --name windows-runner-001 \
##       --vcpu 4 --memory-gb 8 --disk-gb 80 \
##       --network-bridge virbr0 \
##       --first-boot-script ./bootstrap-windows-runner-001.ps1
##
## This test parses the canonical command via ``parseCliOpts`` and
## asserts that every flag lands in the right CliOpts / BaselineSpec
## field — without making any virsh / libvirtd calls. It's the
## smallest possible regression guard against the M4 flag surface
## quietly drifting back out of sync with the operator-facing docs.
##
## NoopBackend-style: no live VM, no virsh, no virt-install. The test
## stops short of calling ``provisionBaseline`` itself (which would
## then need a working libvirtd connection); instead it exercises the
## CLI → BaselineSpec → backend-construction wiring and lets the
## live-virsh case land with M4 Phase B's integration suite.

import std/[os, strutils, tables, unittest]
import vm_harness
import vm_harness/cli

# Replicate the private helper in cli.nim so the test exercises the
# same observable behaviour the CLI does.
proc applyDefaultsForTest(opts: CliOpts): BaselineSpec =
  result.name = opts.baseline
  result.sourceImage = opts.sourceImage
  result.cpus = if opts.cpus > 0: opts.cpus else: 2
  result.memoryMB = if opts.memoryMB > 0: opts.memoryMB else: 4096
  result.diskGB = if opts.diskGB > 0: opts.diskGB else: 50
  if opts.guestSet:
    result.guestOs = opts.guest
  result.recipeDir = opts.recipeDir
  result.firstBootScript = opts.firstBootScript
  result.controllerPubKey = opts.controllerPubKey
  result.networkBridge = opts.networkBridge
  result.imagePoolDir = opts.imagePoolDir
  result.backendOptions = initTable[string, string]()

suite "CLI libvirt M4 canonical-command flag plumbing":

  test "resolveRecipeDir locates an in-tree guest-recipes/<id>/ directory":
    # Run from the repo root (nimble test always invokes nim from the
    # package's srcDir-adjacent root). The windows-x64-base recipe is
    # checked in, so the resolver MUST find it without env overrides.
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    # Walk up from the test file's location until we find guest-recipes/.
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    let resolved = resolveRecipeDir("windows-x64-base")
    check resolved.endsWith("windows-x64-base")
    check dirExists(resolved)
    check fileExists(resolved / "build-autounattend-iso.sh")

  test "resolveRecipeDir rejects path-shaped ids":
    expect ValueError:
      discard resolveRecipeDir("../something")
    expect ValueError:
      discard resolveRecipeDir("a/b")
    expect ValueError:
      discard resolveRecipeDir(".hidden")

  test "resolveRecipeDir raises ValueError for an unknown id":
    expect ValueError:
      discard resolveRecipeDir("definitely-not-a-recipe-xyzzy")

  test "canonical libvirt M4 command parses into the documented CliOpts shape":
    # Mirror the exact invocation from docs/m4-libvirt.md and the
    # windows-runner-001 prototype README. ``--first-boot-script``
    # validates at parse time, so we point it at a file that
    # definitely exists on every host (the running test binary itself).
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    let firstBoot = getAppFilename()
    let opts = parseCliOpts(@[
      "provision",
      "--backend", "libvirt",
      "--recipe", "windows-x64-base",
      "--name", "windows-runner-001",
      "--vcpu", "4",
      "--memory-gb", "8",
      "--disk-gb", "80",
      "--network-bridge", "virbr0",
      "--first-boot-script", firstBoot
    ])
    check opts.subcommand == "provision"
    check opts.backend == "libvirt"
    # --name aliases --baseline.
    check opts.baseline == "windows-runner-001"
    check opts.name == "windows-runner-001"
    # --vcpu lands in cpus (alias).
    check opts.cpus == 4
    # --memory-gb is converted to MiB at parse time.
    check opts.memoryMB == 8 * 1024
    check opts.diskGB == 80
    check opts.networkBridge == "virbr0"
    check opts.firstBootScript == firstBoot
    check opts.recipe == "windows-x64-base"
    check opts.recipeDir.endsWith("windows-x64-base")
    check dirExists(opts.recipeDir)

  test "applyDefaults threads the libvirt-slice flags into BaselineSpec":
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    let firstBoot = getAppFilename()
    let opts = parseCliOpts(@[
      "provision",
      "--backend", "libvirt",
      "--recipe", "windows-x64-base",
      "--name", "windows-runner-001",
      "--vcpu", "4", "--memory-gb", "8", "--disk-gb", "80",
      "--network-bridge", "virbr0",
      "--first-boot-script", firstBoot
    ])
    let spec = applyDefaultsForTest(opts)
    check spec.name == "windows-runner-001"
    check spec.cpus == 4
    check spec.memoryMB == 8 * 1024
    check spec.diskGB == 80
    check spec.networkBridge == "virbr0"
    check spec.firstBootScript == firstBoot
    check spec.recipeDir.endsWith("windows-x64-base")

  test "--image-pool-dir lands in CliOpts and threads through BaselineSpec":
    let opts = parseCliOpts(@[
      "provision",
      "--backend", "libvirt",
      "--name", "windows-runner-001",
      "--image-pool-dir", "/storage/libvirt"
    ])
    check opts.imagePoolDir == "/storage/libvirt"
    let spec = applyDefaultsForTest(opts)
    check spec.imagePoolDir == "/storage/libvirt"

  test "--image-pool-dir absent ⇒ empty (backend default preserved)":
    let opts = parseCliOpts(@[
      "provision", "--backend", "libvirt", "--name", "windows-runner-001"
    ])
    check opts.imagePoolDir == ""
    let spec = applyDefaultsForTest(opts)
    check spec.imagePoolDir == ""
    # An empty override must NOT disturb the backend's configured default.
    let b = newLibvirtBackend()
    check b.imagePoolDir == DefaultLibvirtImagePool

  test "--cpus and --vcpu are interchangeable":
    let a = parseCliOpts(@["provision", "--cpus", "2"])
    let b = parseCliOpts(@["provision", "--vcpu", "2"])
    check a.cpus == b.cpus
    check a.cpus == 2

  test "--memory-mb and --memory-gb both land in memoryMB":
    let a = parseCliOpts(@["provision", "--memory-mb", "4096"])
    let b = parseCliOpts(@["provision", "--memory-gb", "4"])
    check a.memoryMB == 4096
    check b.memoryMB == 4096
    check a.memoryMB == b.memoryMB

  test "--name without --baseline becomes the baseline":
    let opts = parseCliOpts(@["provision", "--name", "vm-x"])
    check opts.baseline == "vm-x"
    check opts.name == "vm-x"

  test "--name and --baseline together must match":
    expect ValueError:
      discard parseCliOpts(@[
        "provision", "--baseline", "one", "--name", "two"
      ])
    # When they match, both fields are set.
    let opts = parseCliOpts(@[
      "provision", "--baseline", "same", "--name", "same"
    ])
    check opts.baseline == "same"
    check opts.name == "same"

  test "--first-boot-script without --recipe is rejected at parse time":
    let firstBoot = getAppFilename()
    expect ValueError:
      discard parseCliOpts(@[
        "provision",
        "--first-boot-script", firstBoot
      ])

  test "--first-boot-script with non-existent path is rejected at parse time":
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    expect ValueError:
      discard parseCliOpts(@[
        "provision",
        "--recipe", "windows-x64-base",
        "--first-boot-script", "/definitely/not/a/real/file.ps1"
      ])

  test "--controller-pubkey lands in CliOpts and threads through BaselineSpec":
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    # Use the running test binary as a stand-in for the pubkey path
    # (file existence is the only thing parseCliOpts checks).
    let pub = getAppFilename()
    let opts = parseCliOpts(@[
      "provision",
      "--backend", "libvirt",
      "--recipe", "windows-x64-base",
      "--name", "windows-runner-001",
      "--controller-pubkey", pub
    ])
    check opts.controllerPubKey == pub
    let spec = applyDefaultsForTest(opts)
    check spec.controllerPubKey == pub

  test "--controller-pubkey without --recipe is rejected at parse time":
    let pub = getAppFilename()
    expect ValueError:
      discard parseCliOpts(@[
        "provision",
        "--controller-pubkey", pub
      ])

  test "--controller-pubkey with non-existent path is rejected at parse time":
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    expect ValueError:
      discard parseCliOpts(@[
        "provision",
        "--recipe", "windows-x64-base",
        "--controller-pubkey", "/definitely/not/a/real/id_ed25519.pub"
      ])

  test "BaselineSpec accepts the new fields and round-trips through libvirt":
    # End-to-end no-virsh check: the resulting BaselineSpec is what
    # libvirt's ``provisionBaseline`` would consume. We don't call
    # provisionBaseline (it would require libvirtd) but we do
    # construct the backend and verify the spec carries every value
    # the canonical command supplied.
    let prevCwd = getCurrentDir()
    defer: setCurrentDir(prevCwd)
    var search = currentSourcePath().parentDir
    for _ in 0 .. 5:
      if dirExists(search / "guest-recipes"):
        setCurrentDir(search)
        break
      search = search.parentDir
    let firstBoot = getAppFilename()
    let opts = parseCliOpts(@[
      "provision",
      "--backend", "libvirt",
      "--recipe", "windows-x64-base",
      "--name", "windows-runner-001",
      "--vcpu", "4", "--memory-gb", "8", "--disk-gb", "80",
      "--network-bridge", "br-custom",
      "--first-boot-script", firstBoot
    ])
    let spec = applyDefaultsForTest(opts)
    let backend = newLibvirtBackend()
    check backend.id == biLibvirt
    # The backend default bridge is virbr0; the spec carries the
    # operator's override. ``provisionBaseline`` applies
    # spec.networkBridge over backend.networkBridge.
    check backend.networkBridge == DefaultLibvirtBridge
    check spec.networkBridge == "br-custom"
    check spec.recipeDir.len > 0
    check spec.firstBootScript == firstBoot
