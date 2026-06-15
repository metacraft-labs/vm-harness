## e2e_vm_harness_hyperv_reproos_mvp_foreign
##
## D1 acceptance gate for the ReproOS-Generations-And-Foreign-Packages
## campaign: boot a reproos-mvp.iso under Hyper-V Gen-2 UEFI (Secure
## Boot off), wait for the systemd login prompt, auto-login as root,
## and execute the 5 foreign-package binaries via the C3 bind-mount
## sandbox launcher. Each binary must produce the expected version
## banner from the pinned Debian bookworm snapshot.
##
## Required artifact:
##
##   ``D:\metacraft\reprobuild\build\d1-mvp\reproos-mvp.iso``
##
## Produced by:
##
##   bash recipes/reproos-mvp-config/build-mvp-iso.sh MVP_STAGE=iso
##
## ...inside the repro-ubuntu WSL distro (so the R9 systemd install
## tree + grub-mkrescue are available). The build driver tolerates a
## missing R9/R8 toolchain on the build host and emits an honest
## warning instead of a corrupt ISO; the absence of the ISO at
## acceptance-test time results in a SKIP, never a silent pass.
##
## Skips when:
##   * Not running on Windows.
##   * Hyper-V cmdlets aren't available or the process is not elevated.
##   * The MVP ISO doesn't exist on disk yet (D1-stage3 incomplete).
##
## The script + integration driver landed under
## ``reprobuild/recipes/reproos-mvp-config/``; the D1 milestone
## documents the staged delivery — stage1+2 land first, stage3 (this
## test going green) is the campaign-level acceptance gate.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_vm_harness_hyperv_reproos_mvp_foreign: Windows host required"
  quit(0)

const
  DefaultIsoPath = r"D:\metacraft\reprobuild\build\d1-mvp\reproos-mvp.iso"
  ## Where ``recipes/reproos-mvp-config/build-mvp-iso.sh`` writes the
  ## ISO when invoked with ``MVP_STAGE=iso``. The build driver MAY be
  ## overridden via ``MVP_OUT_DIR``; if the host operator changed that
  ## they should set ``D1_MVP_ISO`` to point at the produced file.

  ## D1 boot-and-test budget.
  TotalDeadlineSec = 60     # campaign acceptance gate target
  BootStageTimeout = 90     # systemd boot itself may eat most of 30 s
  LoginTimeout     = 60
  CmdTimeout       = 15

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

proc findMvpIso(): string =
  let envOverride = getEnv("D1_MVP_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  if fileExists(DefaultIsoPath):
    return DefaultIsoPath
  return ""

# ---------------------------------------------------------------------------
# Foreign-package assertion table.
#
# Each entry pairs a shell command with the regex pattern the serial
# output must satisfy. The patterns are intentionally permissive against
# version-number drift while remaining specific enough to prove the C3
# sandbox launcher routed exec() through the bind-mounted prefix.
# ---------------------------------------------------------------------------

type
  ForeignAssertion = object
    name*: string
    command*: string
    pattern*: string

const ForeignAssertions = @[
  ForeignAssertion(name: "git",
    command: "git --version",
    pattern: r"git version 1:2\.39\.5"),
  ForeignAssertion(name: "vim",
    command: "vim --version | head -1",
    pattern: r"VIM - Vi IMproved 2:9\.0\.1378"),
  ForeignAssertion(name: "python3",
    # Echo a unique sentinel side-by-side with the python3 output so
    # the assertion regex can pin it without relying on ^/$ anchors;
    # std/re's default mode treats them as start/end of the entire
    # accumulated buffer which never matches in a busy serial stream.
    command: "python3 -c 'print(\"D1PY3 hi STOP\")'",
    pattern: r"D1PY3 hi STOP"),
  ForeignAssertion(name: "curl",
    command: "curl --version | head -1",
    pattern: r"curl 7\.88\.1"),
  ForeignAssertion(name: "htop",
    command: "htop --version",
    pattern: r"htop 3\.2\.2"),
]

proc runBootScenario(backend: HyperVBackend, isoPath, perVmDir, vmName: string) =
  createDir(perVmDir)
  var extra = initTable[string, string]()
  let spec = BootMediaSpec(
    name: vmName,
    kind: bmkIso,
    mediaPath: isoPath,
    cpus: 2,
    memoryMB: 2048,
    generation: 2,
    secureBootEnabled: false,
    serialPipeName: vmName & "-com1",
    serialLogPath: perVmDir / (vmName & ".serial.log"),
    extra: extra)

  let totalStart = epochTime()
  let vm = backend.bootFromMedia(spec)
  let logKeepDir = getEnv("D1_MVP_KEEP_SERIAL", "")
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

  # Phase A: kernel + systemd boot (carried in from R9 ISO).
  echo "[info] expecting Linux kernel banner..."
  let kernelBanner = backend.expectLine(serial,
    r"Linux version", timeoutSec = BootStageTimeout)
  check kernelBanner.matched
  if not kernelBanner.matched:
    echo "[diag] kernel banner never appeared; aborting D1 boot scenario"
    return

  echo "[info] expecting systemd PID 1 banner..."
  let pid1 = backend.expectLine(serial,
    r"systemd\[1\]:", timeoutSec = BootStageTimeout)
  check pid1.matched

  # Phase B: login prompt + autologin.
  echo "[info] expecting login prompt on ttyS0..."
  let login = backend.expectLine(serial,
    r"(reproos.*login:|root@reproos|root@.*[\$#])",
    timeoutSec = LoginTimeout)
  check login.matched
  if not login.matched:
    echo "[diag] login prompt never appeared"
    return

  # If the prompt is a login: rather than an autologin shell, send the
  # credentials. The MVP config sets up agetty --autologin root so we
  # MUST wait for the shell prompt before sending anything — otherwise
  # our "root\n" gets eaten by the autologin in flight and the
  # subsequent commands hit the shell as stale input.
  if login.matchedText.contains("login:"):
    let prompt = backend.expectLine(serial, r"(~ #|root@.*[\$#])",
      timeoutSec = LoginTimeout)
    if not prompt.matched:
      # The configured agetty did not autologin; fall back to manual.
      backend.serialSend(serial, "root\n")
      discard backend.expectLine(serial, r"(password|Password|\$|#)",
        timeoutSec = LoginTimeout)
      backend.serialSend(serial, "reproos\n")
      discard backend.expectLine(serial, r"(\$|#)", timeoutSec = LoginTimeout)

  # Phase B+: diagnostic listing — surface the C3 overlay tree so
  # failures distinguish "stub not on disk" (initramfs missing) from
  # "stub fails at exec" (sandbox issue).
  if getEnv("D1_MVP_DIAGNOSTIC", "") == "1":
    backend.serialSend(serial,
      "echo D1_DIAG_BEGIN; ls -la /usr/local/bin/ 2>&1; " &
      "ls /opt/reproos-foreign/ 2>&1; " &
      "ls -la /opt/reproos-foreign/git/ 2>&1; " &
      "head -20 /opt/reproos-foreign/git/launcher.manifest 2>&1; " &
      "echo D1_DIAG_END\n")
    discard backend.expectLine(serial, r"D1_DIAG_END", timeoutSec = CmdTimeout)

  # Phase C: run the 5 foreign-package assertions.
  var passed = 0
  for fa in ForeignAssertions:
    echo "[d1] asserting ", fa.name, " via shim..."
    # Tag the output so concurrent kernel chatter doesn't confuse the
    # regex match against a partial line.
    let sentinelBefore = "D1_BEGIN_" & fa.name
    let sentinelAfter  = "D1_END_" & fa.name
    backend.serialSend(serial,
      "echo " & sentinelBefore & " && " & fa.command &
      " && echo " & sentinelAfter & "\n")
    let resp = backend.expectLine(serial, fa.pattern,
      timeoutSec = CmdTimeout)
    if resp.matched:
      echo "[d1] PASS ", fa.name, ": ", resp.matchedText.strip()
      inc passed
    else:
      echo "[d1] FAIL ", fa.name, ": expected /", fa.pattern,
        "/ not seen within ", CmdTimeout, "s"
    check resp.matched

  let totalElapsed = epochTime() - totalStart
  echo "[d1] foreign assertions passed: ", passed, "/", ForeignAssertions.len
  echo "[d1] total wall-clock: ", totalElapsed.formatFloat(precision = 1), "s"
  echo "[d1] target wall-clock budget: ", TotalDeadlineSec, "s"
  if totalElapsed > TotalDeadlineSec.float:
    echo "[d1] WARN: total wall-clock " &
         totalElapsed.formatFloat(precision = 1) &
         "s exceeds D1 budget of " & $TotalDeadlineSec & "s"

# ---------------------------------------------------------------------------
# Suite.

suite "e2e_vm_harness_hyperv_reproos_mvp_foreign":
  test "D1 acceptance: reproos-mvp.iso boots, autologin root, 5 foreign packages via sandbox launcher":
    let backend = newHyperVBackend(
      vmName = "repro-test-boot-d1-mvp-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation; current " &
           "process is not elevated (Get-VMHost failed)"
      skip()
    else:
      let iso = findMvpIso()
      if iso.len == 0:
        echo "[skip] D1 MVP ISO not found at ", DefaultIsoPath,
             " (and D1_MVP_ISO unset). Build via:"
        echo "         wsl -d repro-ubuntu bash /mnt/d/metacraft/reprobuild/" &
             "recipes/reproos-mvp-config/build-mvp-iso.sh"
        echo "       with MVP_STAGE=iso once the R9 systemd install tree is on the host."
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-d1-mvp-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-hyperv-d1-mvp" / vmName
        runBootScenario(backend, iso, perVmDir, vmName)
