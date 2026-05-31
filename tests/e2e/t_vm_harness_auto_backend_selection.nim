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
    # For every (host, guest) cell that is *not* the current host's real
    # backend, we expect newBackend to fall back to NoopBackend and tag
    # the result with the auto-selected ID. This lets the M0 test pass
    # on any CI runner without needing real Tart/UTM/Hyper-V installed.
    for cell in dispatchTable:
      let (id, backend) = newBackendForGuest(cell.host, cell.guest,
                                            noopFallback = true)
      check id == cell.expected
      check backend.id == cell.expected
      # Even though the backend is structurally a NoopBackend, it
      # advertises itself as the auto-selected ID.
      check backend != nil
      # Sanity: the masquerading NoopBackend can still execute a full
      # lifecycle (this is exactly the property the CLI relies on for
      # the auto-selection smoke run).
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
    backend.provisionBaseline(BaselineSpec(name: "auto-cli-baseline"))
    let envelope = newOutputEnvelope(outDir)
    let gate = GateSpec(name: "auto-cli", baseline: "auto-cli-baseline",
                        cmd: @["/bin/echo", "auto-selected:" & $id])
    let r = runGate(backend, gate, envelope)
    check r.verdict == vPass
    check fileExists(outDir / "DONE")
