## e2e_vm_harness_auto_backend_selection (M0 verification).
##
## Drives ``--backend auto`` for every (host OS, guest OS) cell in the
## design doc §6 dispatch table and verifies the resolved ``BackendId``
## matches the spec.
##
## Per the milestone deliverables: "Since real backends aren't
## implemented yet in M0, this can use NoopBackend stand-ins for the
## selection-logic test; document why." The test exercises the full
## ``autoSelectBackendId → newBackend(noopFallback=true)`` path. The
## NoopBackend masquerades as the requested ID via ``newBackend``'s
## fallback path so we can verify backend.id matches the auto-selected
## value without needing the real hypervisor installed on every CI
## runner. This is the documented use of NoopBackend per design doc §9.1.

import std/[os, tables, tempfiles, unittest]
import vm_harness

const dispatchTable = @[
  (host: hpWindows,  guest: goWindows, expected: biHyperv),
  (host: hpWindows,  guest: goLinux,   expected: biWsl),
  (host: hpLinux,    guest: goLinux,   expected: biLibvirt),
  (host: hpLinux,    guest: goWindows, expected: biLibvirt),
  (host: hpMacosArm, guest: goMacos,   expected: biTartMacos),
  (host: hpMacosArm, guest: goLinux,   expected: biTartLinuxArm),
  (host: hpMacosArm, guest: goWindows, expected: biUtmWindowsArm),
]

suite "e2e_vm_harness_auto_backend_selection":
  test "every (host, guest) cell resolves to the documented backend":
    for cell in dispatchTable:
      check autoSelectBackendId(cell.host, cell.guest) == cell.expected

  test "macOS guest on non-macOS host raises BackendUnavailableError":
    expect BackendUnavailableError:
      discard autoSelectBackendId(hpWindows, goMacos)
    expect BackendUnavailableError:
      discard autoSelectBackendId(hpLinux, goMacos)

  test "newBackend(noopFallback=true) yields a backend tagged with the requested ID":
    # For every (host, guest) cell, newBackend should either:
    #   (a) construct the real backend if its factory is registered and
    #       the underlying tool is available on this host, OR
    #   (b) fall back to NoopBackend tagged with the requested ID.
    # The M0 contract is that the *dispatch* always succeeds; the M0
    # smoke lifecycle exercise (provision/revert/exec) is only run
    # against backends that probe as available — the per-backend
    # lifecycle is covered by each backend's own integration tests
    # under tests/integration/.
    for cell in dispatchTable:
      let (id, backend) = newBackendForGuest(cell.host, cell.guest,
                                            noopFallback = true)
      check id == cell.expected
      check backend.id == cell.expected
      check backend != nil
      # Lifecycle exercise: only run it against backends that can
      # actually serve I/O on the current host. NoopBackend always
      # can; M1+ backends advertise via probeAvailability. UTM
      # additionally requires a pre-built golden bundle (the recipe
      # under guest-recipes/windows-arm-base/ is a 30+ minute one-time
      # build), so we skip its lifecycle exercise unless the golden
      # exists — probeAvailability alone isn't enough.
      var canExercise =
        backend.id == biNoop or
        (try: backend.probeAvailability() except CatchableError: false)
      if canExercise and backend.id == biUtmWindowsArm:
        # Only exercise UTM if the golden is registered with UTM.
        let utm = cast[UtmBackend](backend)
        var goldenPresent = false
        for v in utm.listUtmVms():
          if v.name == utm.goldenBundleName: goldenPresent = true
        if not goldenPresent:
          canExercise = false
      if canExercise and backend.id == biLibvirt:
        # Only exercise libvirt if the test baseline already exists
        # as a defined domain. The M4 Phase A slice's
        # provisionBaseline needs either a pre-defined domain or a
        # real ISO source — neither is plausible from this generic
        # selection test, so we skip the lifecycle exercise. The
        # libvirt-specific lifecycle is covered by
        # tests/integration/t_libvirt_backend.nim.
        let lv = cast[LibvirtBackend](backend)
        if not lv.domainExists("auto-cell-baseline"):
          canExercise = false
      if canExercise:
        backend.provisionBaseline(BaselineSpec(name: "auto-cell-baseline"))
        let vm = backend.revertToBaseline("auto-cell-baseline")
        let r = backend.execInGuest(vm, initTable[string, string](),
                                    @["/bin/echo", $cell.host, $cell.guest])
        check r.exitCode == 0
        backend.stopAndCleanup(vm)

  test "auto-selection drives the full CLI run subcommand without errors":
    # End-to-end: parseCliOpts → resolveBackend(auto) → runGate.
    # We can't import cli.nim directly into a test file as a sibling
    # subcommand call, so we go through the same code path by exercising
    # newBackendForGuest + runGate (which is what cmdRun does).
    let outDir = createTempDir("vmh-auto-cli-", "")
    defer: removeDir(outDir)
    let host = detectHostPlatform()
    # Pick a guest that's always selectable for the current host.
    let guest = case host
                of hpWindows: goLinux        # → wsl
                of hpLinux:   goLinux        # → libvirt
                of hpMacosArm: goLinux       # → tart-linux-arm
    let (id, backend) = newBackendForGuest(host, guest, noopFallback = true)
    # Skip the live-libvirt exercise on Linux hosts where the real
    # libvirt backend is auto-selected: provisioning a fresh baseline
    # would need a real Win11 ISO. The libvirt CLI dispatch path is
    # covered by tests/integration/t_libvirt_backend.nim.
    let libvirtNeedsBaseline =
      backend.id == biLibvirt and
      not cast[LibvirtBackend](backend).domainExists("auto-cli-baseline")
    if libvirtNeedsBaseline:
      # Skip the live-libvirt exercise on Linux hosts where the real
      # libvirt backend is auto-selected: provisioning a fresh
      # baseline would need a real Win11 ISO. The libvirt CLI dispatch
      # path is covered by tests/integration/t_libvirt_backend.nim.
      skip()
    else:
      backend.provisionBaseline(BaselineSpec(name: "auto-cli-baseline"))
      let envelope = newOutputEnvelope(outDir)
      let gate = GateSpec(name: "auto-cli", baseline: "auto-cli-baseline",
                          cmd: @["/bin/echo", "auto-selected:" & $id])
      let r = runGate(backend, gate, envelope)
      check r.verdict == vPass
      check fileExists(outDir / "DONE")
