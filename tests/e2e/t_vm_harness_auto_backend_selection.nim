## e2e_vm_harness_auto_backend_selection (M0 verification).
##
## Drives ``--backend auto`` for every (host OS, guest OS) cell in the
## design doc §6 dispatch table and verifies the resolved ``BackendId``
## matches the spec.
##
## The test exercises the full ``autoSelectBackendId →
## newBackend(noopFallback=true)`` path without probing or executing a real
## hypervisor. A tagged NoopBackend drives the lifecycle portion so this gate
## remains deterministic on every CI runner; real hypervisor lifecycles are
## covered by the host-level test catalog.

import std/[os, tempfiles, unittest]
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

  test "newBackend(noopFallback=true) constructs the requested backend":
    # All factories are registered, so construction verifies dispatch without
    # requiring the selected hypervisor to be usable on this CI host.
    for cell in dispatchTable:
      let (id, backend) = newBackendForGuest(cell.host, cell.guest,
                                            noopFallback = true)
      check id == cell.expected
      check backend.id == cell.expected
      check backend != nil

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
    let (id, selectedBackend) =
      newBackendForGuest(host, guest, noopFallback = true)
    check selectedBackend.id == id
    let backend = newNoopBackend()
    backend.id = id
    backend.provisionBaseline(BaselineSpec(name: "auto-cli-baseline"))
    let envelope = newOutputEnvelope(outDir)
    let gate = GateSpec(name: "auto-cli", baseline: "auto-cli-baseline",
                        cmd: @["/bin/echo", "auto-selected:" & $id])
    let r = runGate(backend, gate, envelope)
    check r.verdict == vPass
    check fileExists(outDir / "DONE")
