## e2e_vm_harness_wsl_systemd_boot
##
## R1 Path A in vm-harness: boot a vendored Debian bookworm-slim rootfs
## under WSL2 with systemd as PID 1, then assert that systemd actually
## runs (``systemctl --version`` reports a sane version, and
## ``systemctl is-system-running`` returns a recognised state).
##
## This test is the canonical Nim replacement for the Python
## ``reprobuild/recipes/reproos-ref-iso/boot-test.py`` that previously
## drove the same scenario via a parallel Python boot harness. The Nim
## version goes through the same vm-harness primitives the rest of the
## campaign uses (``bootFromMedia`` + ``captureSerial`` + ``expectLine``
## + ``serialSend`` + ``stopAndCleanup``).
##
## Required artifacts:
##
## - A Windows host with WSL2 installed (``wsl.exe`` on PATH).
## - A Debian bookworm-slim rootfs tarball at:
##
##     $env:VMH_DEBIAN_ROOTFS_TAR        (if set), or
##     $env:LOCALAPPDATA\repro-boot-harness-cache\debian-bookworm-slim-amd64-rootfs.tar.gz, or
##     D:\metacraft\reprobuild\recipes\reproos-ref-iso\vendor\debian-bookworm-slim-amd64-rootfs.tar.gz
##
##   When none of the above are present the test SKIPs with a clear
##   reason (NEVER silently passes). Use
##   ``reprobuild/recipes/reproos-ref-iso/vendor/fetch.ps1`` to download
##   the rootfs into the vendor directory.
##
## Skips when WSL2 is unavailable or none of the rootfs candidates exist.

import std/[os, tables, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_wsl_systemd_boot: Windows host required"
  quit(0)

proc runBootScenario(backend: WslBackend, rootfs: string) =
  let spec = BootMediaSpec(
    kind: bmkRootfsTar,
    mediaPath: rootfs,
    memoryMB: 2048,
    cpus: 2,
    generation: 0,
    secureBootEnabled: false,
    serialLogPath: getTempDir() / "vm-harness-e2e-wsl-systemd-boot.log",
    extra: initTable[string, string]())

  let vm = backend.bootFromMedia(spec)
  defer: backend.stopAndCleanup(vm, deleteVm = true)

  let serial = backend.captureSerial(vm)
  defer: backend.closeSerial(serial)

  # Phase A: prove the interactive shell pump is alive by writing a
  # token and reading it back.
  backend.serialSend(serial, "echo VMH-BOOT-MARKER-WSL\n")
  let markerMatch = backend.expectLine(serial,
    r"VMH-BOOT-MARKER-WSL", timeoutSec = 30)
  check markerMatch.matched
  if not markerMatch.matched:
    echo "[diag] marker timeout. Tail of buffer:\n  ", markerMatch.matchedText

  # Phase B: systemctl --version must report a recognisable systemd
  # version string. The boot-from-media path already ran apt install +
  # wsl.conf + terminate; this exec re-enters under systemd-PID-1.
  backend.serialSend(serial, "systemctl --version | head -1\n")
  let versionMatch = backend.expectLine(serial,
    r"systemd \d+", timeoutSec = 30)
  check versionMatch.matched
  if versionMatch.matched:
    echo "[diag] systemd version line: ", versionMatch.matchedText

  # Phase C: systemctl is-system-running must return a state in the
  # set {running, degraded, starting, initializing} — any of those
  # proves systemd is PID 1 and managing the unit graph.
  backend.serialSend(serial, "systemctl is-system-running\n")
  let stateMatch = backend.expectLine(serial,
    r"(running|degraded|starting|initializing)", timeoutSec = 60)
  check stateMatch.matched
  if stateMatch.matched:
    echo "[diag] systemd state: ", stateMatch.matchedText

proc findRootfsTarball(): string =
  var candidates: seq[string] = @[]
  let envOverride = getEnv("VMH_DEBIAN_ROOTFS_TAR")
  if envOverride.len > 0:
    candidates.add(envOverride)
  let localAppData = getEnv("LOCALAPPDATA")
  if localAppData.len > 0:
    candidates.add(localAppData / "repro-boot-harness-cache" /
                   "debian-bookworm-slim-amd64-rootfs.tar.gz")
  candidates.add("D:\\metacraft\\reprobuild\\recipes\\reproos-ref-iso\\" &
                 "vendor\\debian-bookworm-slim-amd64-rootfs.tar.gz")
  for c in candidates:
    if fileExists(c):
      return c
  return ""

suite "e2e_vm_harness_wsl_systemd_boot":
  test "Debian rootfs boots WSL2 systemd; assertions pass via vm-harness primitives":
    let backend = newWslBackend(distroPrefix = "repro-test-boot-wsl")

    if not backend.probeAvailability():
      echo "[skip] WSL2 not available on this host (wsl --status failed)"
      skip()
    else:
      let rootfs = findRootfsTarball()
      if rootfs.len == 0:
        echo "[skip] Debian bookworm-slim rootfs not found. Set " &
             "VMH_DEBIAN_ROOTFS_TAR or run " &
             "`pwsh recipes/reproos-ref-iso/vendor/fetch.ps1` in reprobuild"
        skip()
      else:
        runBootScenario(backend, rootfs)

    discard
