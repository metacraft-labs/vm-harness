## Unit tests for the auto-backend-selection dispatch table.
##
## The dispatch table is pure logic; the e2e selection test
## (``t_vm_harness_auto_backend_selection.nim``) exercises the full
## ``newBackendForGuest`` + NoopBackend-fallback path. This file only
## checks the table.

import std/unittest
import vm_harness/types

suite "selectBackendId":
  test "Windows host dispatches correctly":
    check selectBackendId(hpWindows, goWindows) == biHyperv
    check selectBackendId(hpWindows, goLinux) == biWsl

  test "Linux host dispatches correctly":
    check selectBackendId(hpLinux, goLinux) == biLibvirt
    check selectBackendId(hpLinux, goWindows) == biLibvirt

  test "macOS-arm host dispatches correctly":
    check selectBackendId(hpMacosArm, goMacos) == biTartMacos
    check selectBackendId(hpMacosArm, goLinux) == biTartLinuxArm
    check selectBackendId(hpMacosArm, goWindows) == biUtmWindowsArm

  test "macOS guest on non-macOS host raises":
    expect BackendUnavailableError:
      discard selectBackendId(hpWindows, goMacos)
    expect BackendUnavailableError:
      discard selectBackendId(hpLinux, goMacos)

  test "isCleanupSafe returns true for revert and exec phases":
    check isCleanupSafe(lpRevert)
    check isCleanupSafe(lpExec)
    check isCleanupSafe(lpCopy)
    check isCleanupSafe(lpShim)
    check not isCleanupSafe(lpProbe)
    check not isCleanupSafe(lpProvisioning)
    check not isCleanupSafe(lpCleanup)
