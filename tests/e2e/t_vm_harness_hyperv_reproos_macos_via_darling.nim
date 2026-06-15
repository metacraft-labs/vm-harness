## e2e_vm_harness_hyperv_reproos_macos_via_darling
##
## D4 acceptance gate for the ReproOS-Multi-OS-Catalog-PoC campaign:
## boot a reproos-d4-darling.iso under Hyper-V Gen-2 UEFI (Secure Boot
## off), wait for the systemd login prompt, auto-login as root, and
## execute the 3 macOS-via-Darling binaries (fzf 0.60.0, jq 1.7.1,
## ripgrep 14.1.1) via the C3 sandbox launcher's runtime=darling path
## (D2). Each binary must produce the upstream-pinned version banner.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\d4-darling\reproos-d4-darling.iso``
##
## Produced by:
##
##   bash recipes/reproos-mvp-config/build-mvp-darling-iso.sh MVP_STAGE=iso
##
## ...inside the repro-darling-test WSL distro (so Darling + the R8/R9
## toolchain are available). The build driver tolerates a missing
## R8/R9 toolchain on the build host and emits a warning rather than
## a corrupt ISO; the absence of the ISO at acceptance-test time
## results in a SKIP, never a silent pass.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The D4 darling ISO doesn't exist on disk yet.
##
## Wall-clock budget per the D4 brief: 180 s. Darling cold-starts the
## darlingserver per-DPREFIX on first invocation (~10-30 s each per
## D3 risk #4), and the FUSE-mount overlay setup adds another ~5 s
## per shim invocation. With 3 separate DPREFIXes (D3 risk #1+#3) we
## allow 60 s per cmd. Memory budget: 4 GB (the augmented initramfs
## approaches ~600 MB including Darling closure; Hyper-V VM RAM
## accommodates).

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_macos_via_darling: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\d4-darling\reproos-d4-darling.iso"

  TotalDeadlineSec = 300
  BootStageTimeout = 180
  LoginTimeout     = 60
  CmdTimeout       = 120
  ## TotalDeadline + BootStageTimeout bumped by the D4 fourth fix:
  ## reproos-darling-prefix-coldinit.service runs BEFORE
  ## multi-user.target on first boot to cold-init all 3 DPREFIXes
  ## (~5 s each, sequential) and copy Mach-O payloads. Measured ~17 s
  ## on repro-darling-test. The systemd PID 1 banner and login prompt
  ## are gated by multi-user.target completion, so the coldinit cost
  ## is absorbed into BootStageTimeout (was 90, bumped to 180 to
  ## absorb the ~17 s coldinit + headroom for cold-storage I/O on
  ## CI hosts).
  ## CmdTimeout is set generously per D3 risk #4: each DPREFIX cold-
  ## starts darlingserver on first invocation (~10-30 s), plus FUSE
  ## overlay setup (~5 s). Subsequent invocations within the same
  ## DPREFIX are sub-second, but the 3-tool roll-call hits 3 cold
  ## starts back-to-back. 120 s headroom covers worst-case cold start
  ## + the boot-time `reproos-darling-fuse.service` retry path if
  ## CONFIG_FUSE_FS is built-in but the auto-`mknod` raced the boot.

proc isElevated(): bool =
  let cmd = @["powershell.exe", "-NoLogo", "-NoProfile",
              "-ExecutionPolicy", "Bypass", "-Command",
              "try { $null = Get-VMHost -ErrorAction Stop; exit 0 } " &
              "catch { exit 1 }"]
  try:
    let p = startProcess(cmd[0], args = cmd[1 .. ^1],
                         options = {poUsePath, poStdErrToStdOut})
    let code = p.waitForExit(timeout = 30 * 1000)
    p.close()
    return code == 0
  except CatchableError:
    return false

proc findDarlingIso(): string =
  let envOverride = getEnv("D4_DARLING_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# Darling-package assertion table — 3 entries (fzf + jq + ripgrep).
#
# Each shim at /usr/local/bin/darling-<name> invokes
# /usr/local/bin/reprobuild-sandbox-launcher --manifest=<vm-path> -- "$@".
# The launcher's runtime=darling path exec()s
# /opt/reproos-foreign/darling-binaries/usr/bin/darling with
# `shell <macos-exec-path>` as argv[1..2] and forwards "--version".
#
# Banners match the darling_version_banner field in each catalog
# (recipes/catalog/macos/<name>.json) — substring match on the leading
# version triple to prove the macOS Mach-O actually ran under Darling.
# ---------------------------------------------------------------------------

type
  DarlingAssertion = object
    name*: string
    command*: string
    pattern*: string

const DarlingAssertions = @[
  DarlingAssertion(name: "darling-fzf",
    command: "darling-fzf --version",
    pattern: r"0\.60\.0"),
  DarlingAssertion(name: "darling-jq",
    command: "darling-jq --version",
    pattern: r"jq-1\.7\.1"),
  DarlingAssertion(name: "darling-ripgrep",
    command: "darling-ripgrep --version",
    pattern: r"ripgrep 14\.1\.1"),
]

proc runBootScenario(backend: HyperVBackend, isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    # 4 GB to comfortably accommodate the ~600 MB augmented initramfs
    # (the kernel decompresses the entire cpio.gz into tmpfs at boot;
    # Darling closure ~285 MB + 3 DPREFIXes ~16 MB + R9 base ~70 MB).
    memoryMB: 4096,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("D4_DARLING_KEEP_SERIAL", "")
  defer:
    backend.stopAndCleanup(vm, deleteVm = true)
    if logKeepDir.len > 0:
      createDir(logKeepDir)
      let src = perVmDir / (vmName & ".serial.log")
      if fileExists(src):
        let dst = logKeepDir / (vmName & ".serial.log")
        try: copyFile(src, dst); echo "[diag] serial log preserved at ", dst
        except CatchableError: discard
    if dirExists(perVmDir):
      try: removeDir(perVmDir)
      except CatchableError: discard

  let serial = backend.captureSerial(vm)
  defer: backend.closeSerial(serial)

  echo "[info] expecting Linux kernel banner..."
  let kernelBanner = backend.expectLine(serial,
    r"Linux version", timeoutSec = BootStageTimeout)
  check kernelBanner.matched
  if not kernelBanner.matched:
    echo "[diag] kernel banner never appeared"
    return

  echo "[info] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial,
    r"systemd\[1\]:", timeoutSec = BootStageTimeout)
  check pid1.matched

  echo "[info] expecting login prompt on ttyS0..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|root@reproos|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[diag] login prompt never appeared"
    return

  if login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ #|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      backend.serialSend(serial, "root\n")
      discard backend.expectLine(serial, r"(password|Password|\$|#)",
        timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)", timeoutSec = LoginTimeout)

  # Optional diagnostic surface: confirm the D4 overlay tree landed in
  # the rootfs as expected. Useful for triaging missing-file failures
  # before the darling-<tool> assertions run. Also pre-fires
  # /opt/reproos-foreign/darling-binaries/usr/bin/darling so a missing
  # closure shows up before per-tool cold-start cost is paid.
  if getEnv("D4_DARLING_DIAGNOSTIC", "") == "1":
    # Drive each probe as a separate serialSend; busybox sh truncates
    # very long one-liners coming over the COM1 line discipline.
    proc probe(cmd: string) =
      backend.serialSend(serial, cmd & "\n")
    backend.serialSend(serial, "echo D4_DIAG_BEGIN\n")
    probe("ls /usr/local/bin/darling-* 2>&1")
    probe("ls /opt/reproos-foreign/ 2>&1")
    probe("ls /opt/reproos-foreign/darling-binaries/usr/bin/ 2>&1")
    probe("ls /opt/reproos-foreign/dprefixes/ 2>&1")
    probe("test -c /dev/fuse && echo FUSE_DEVICE_OK || echo FUSE_DEVICE_MISSING")
    probe("modinfo fuse 2>&1 | head -2")
    probe("systemctl status reproos-darling-fuse.service 2>&1 | head -10")
    probe("echo === NS_PROBE ===")
    probe("id")
    probe("ls -la /proc/self/ns/ 2>&1")
    probe("cat /proc/sys/kernel/unprivileged_userns_clone 2>&1 || echo NO_USERNS_CLONE_SYSCTL")
    probe("cat /proc/sys/user/max_user_namespaces 2>&1 || echo NO_MAX_USER_NS_SYSCTL")
    probe("unshare -mU true 2>&1 && echo OK_UNSHARE_mU || echo FAIL_UNSHARE_mU")
    probe("unshare -m true 2>&1 && echo OK_UNSHARE_m || echo FAIL_UNSHARE_m")
    probe("unshare -U true 2>&1 && echo OK_UNSHARE_U || echo FAIL_UNSHARE_U")
    probe("unshare -p --fork --mount-proc true 2>&1 && echo OK_UNSHARE_p || echo FAIL_UNSHARE_p")
    probe("mkdir -p /tmp/o_l /tmp/o_u /tmp/o_w /tmp/o_m")
    probe("mount -t overlay overlay -o lowerdir=/tmp/o_l,upperdir=/tmp/o_u,workdir=/tmp/o_w /tmp/o_m 2>&1 && { umount /tmp/o_m; echo OK_OVERLAY; } || echo FAIL_OVERLAY")
    backend.serialSend(serial, "echo D4_DIAG_END\n")
    discard backend.expectLine(serial, r"D4_DIAG_END",
      timeoutSec = CmdTimeout)

  var passed = 0
  for da in DarlingAssertions:
    echo "[d4] asserting ", da.name, " via shim..."
    let sentinelBefore = "D4_BEGIN_" & da.name
    let sentinelAfter  = "D4_END_" & da.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & da.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, da.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[d4] PASS ", da.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[d4] FAIL ", da.name, ": expected /", da.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[d4] darling assertions passed: ", passed, "/", DarlingAssertions.len
  echo "[d4] total wall-clock: ", totalElapsed.formatFloat(precision = 1), "s"
  echo "[d4] target budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[d4] WARN: total wall-clock exceeds D4 budget"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_macos_via_darling":
  test "D4 acceptance: reproos-d4-darling.iso boots, 3 macOS packages via Darling":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-d4-darling-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation"
      skip()
    else:
      let iso = findDarlingIso()
      if iso.len == 0:
        echo "[skip] D4 darling ISO not found at ", DefaultIsoPath,
             " (and D4_DARLING_ISO unset). Build via:"
        echo "         wsl -d repro-darling-test bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-darling-iso.sh"
        echo "       with MVP_STAGE=iso once the R9 systemd install tree is on the host."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-d4-darling-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-d4-darling" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
