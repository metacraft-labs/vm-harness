## Ordered serial-console boot assertions over the direct-QEMU backend.
##
## *What it is.* Give it a disk image and an ordered list of regex lines
## you expect the guest to print on its serial console, and it boots the
## image under QEMU, matches the lines in order with a per-line timeout,
## captures the whole serial transcript as an artifact — on success AND
## on failure — and tears the VM down on every exit path.
##
## *Why it lives here.* Everything it does is composed from Tier-1
## primitives that already live in this repository:
## ``QemuBootBackend.bootFromMedia`` owns the QEMU process, the CoW
## overlay and the run directory, and matching goes through
## ``expectLine`` → ``serial.expectLineImpl``, the same cursor-advancing
## PCRE engine every vm-harness backend uses. No pattern matching is
## implemented here; this module only sequences those primitives, decides
## where the transcript lands, and turns a miss into a message that names
## what was not seen. It carries no product-, tool- or campaign-specific
## knowledge, so consumers (ReproOS boot gates, and this repository's own
## falsifiability gates) can share one implementation instead of each
## re-deriving the same loop.
##
## *Mocking.* None. Callers drive a real ``qemu-system-x86_64`` against a
## real disk image and read the bytes the guest really wrote. The only
## synthetic part is the *guest* offered by ``writeSyntheticBootDisk``
## below for harness self-tests, and that is a real bootable disk running
## real machine code under real firmware — not a stub standing in for the
## thing under test.

import std/[os, strutils, tables, times]

import ./types
import ./backends/qemu_boot

const BootSmokeArtifactDirEnv* = "VMH_BOOT_SMOKE_ARTIFACT_DIR"
  ## Overrides where serial transcripts are written.

const
  SyntheticStage1Marker* = "REPRO-BOOT-SMOKE-STAGE-1"
  SyntheticStage2Marker* = "REPRO-BOOT-SMOKE-STAGE-2"
  SyntheticLoginMarker* = "reproos-synthetic login: "

type
  BootSmokeStep* = object
    ## One line of the expected serial sequence.
    pattern*: string      ## PCRE, matched against the unconsumed transcript
    timeoutSec*: int      ## budget for THIS line, measured from the
                          ## moment the previous line matched
    label*: string        ## what this line proves, for the failure message

  BootSmokeSpec* = object
    caseName*: string             ## used in artifact filenames
    imagePath*: string
    imageFormat*: string          ## "qcow2" (default) or "raw"
    generation*: int              ## 1 = legacy BIOS, 2 = UEFI/OVMF (default)
    cpus*: int
    memoryMB*: int
    acceleration*: BootAcceleration
    steps*: seq[BootSmokeStep]
    artifactDir*: string          ## "" ⇒ resolveArtifactDir()
    namePrefix*: string           ## "" ⇒ QemuBootNamePrefix

  BootSmokeOutcome* = enum
    bsPassed = "passed"
    bsPatternNotSeen = "pattern-not-seen"
    bsSetupFailed = "setup-failed"

  BootSmokeResult* = object
    outcome*: BootSmokeOutcome
    failureMessage*: string       ## empty iff outcome == bsPassed
    failedStepIndex*: int         ## -1 when every step matched
    matches*: seq[SerialMatch]    ## one per step that was attempted
    vmName*: string
    runDir*: string               ## vm-harness per-VM dir; gone after the run
    serialLogPath*: string        ## artifact; survives the run
    elapsedMs*: int
    serialTail*: string           ## last bytes seen, for diagnosis

proc ok*(r: BootSmokeResult): bool = r.outcome == bsPassed

# ---------------------------------------------------------------------------
# Artifact placement.

proc resolveArtifactDir*(repoRoot = ""): string =
  ## ``$VMH_BOOT_SMOKE_ARTIFACT_DIR`` wins; then, when the caller knows
  ## its checkout root, ``<root>/build/test-artifacts/boot-smoke``; then a
  ## temp directory. Deliberately no checkout auto-detection: this module
  ## is consumed from several repositories and must not encode any one
  ## repository's marker file.
  let fromEnv = getEnv(BootSmokeArtifactDirEnv)
  if fromEnv.len > 0:
    return fromEnv
  if repoRoot.len > 0:
    return repoRoot / "build" / "test-artifacts" / "boot-smoke"
  getTempDir() / "vmh-boot-smoke-artifacts"

# ---------------------------------------------------------------------------
# A synthetic guest, for harnesses that need to prove themselves.
#
# A gate that proves this module works must not be able to skip, and must
# not cost minutes. So it needs a guest that (a) exists in ordinary CI
# with no prebuilt artifact, (b) reaches a known serial line in about
# half a second, and (c) is deterministic to the byte.
#
# A 512-byte legacy boot sector satisfies all three. The machine code
# below is hand-assembled 16-bit x86 that programs the 16550 UART's line
# control register and then writes a fixed string to COM1 (port 0x3F8)
# one byte at a time before halting. Writing it as a byte array rather
# than shelling out to an assembler is what keeps it deterministic and
# dependency-free: there is no toolchain to install and no compiler
# version that can change the artifact.
#
#   offset  bytes         instruction
#   ------  ------------  ---------------------------------------------
#   0x00    FC            cld                 ; lodsb walks forward
#   0x01    FA            cli                 ; no interrupts, no IVT
#   0x02    31 C0         xor ax, ax
#   0x04    8E D8         mov ds, ax          ; DS = 0 so SI is linear
#   0x06    BA FB 03      mov dx, 0x03FB      ; COM1 line control reg
#   0x09    B0 03         mov al, 0x03        ; 8N1, DLAB clear
#   0x0B    EE            out dx, al          ; so THR writes are data
#   0x0C    BE 1D 7C      mov si, 0x7C1D      ; -> message, just past code
#   0x0F    AC   .loop:   lodsb
#   0x10    84 C0         test al, al
#   0x12    74 06         jz .hang
#   0x14    BA F8 03      mov dx, 0x03F8      ; COM1 transmit holding reg
#   0x17    EE            out dx, al
#   0x18    EB F5         jmp .loop
#   0x1A    F4   .hang:   hlt                 ; halted, so QEMU idles
#   0x1B    EB FD         jmp .hang
#   0x1D    ...           NUL-terminated message
#
# The BIOS loads this sector at 0x7C00, which is why the message pointer
# is absolute. ``hlt`` with interrupts disabled means the guest burns no
# host CPU while the gate finishes reading.

const SyntheticBootSectorCode = [
  0xFC'u8, 0xFA, 0x31, 0xC0, 0x8E, 0xD8, 0xBA, 0xFB, 0x03, 0xB0, 0x03,
  0xEE, 0xBE, 0x1D, 0x7C, 0xAC, 0x84, 0xC0, 0x74, 0x06, 0xBA, 0xF8,
  0x03, 0xEE, 0xEB, 0xF5, 0xF4, 0xEB, 0xFD]

const SyntheticMessageOffset = 0x1D
  ## Must equal ``SyntheticBootSectorCode.len``; the ``mov si, 0x7C1D``
  ## above encodes it. A static check below keeps the two in step.

static:
  doAssert SyntheticBootSectorCode.len == SyntheticMessageOffset,
    "synthetic boot sector: code length and the encoded message pointer " &
    "must agree"

proc syntheticBootMessage(): string =
  SyntheticStage1Marker & "\r\n" &
  SyntheticStage2Marker & "\r\n" &
  SyntheticLoginMarker & "\r\n" & "\x00"

proc writeSyntheticBootDisk*(path: string): string =
  ## Write a 1 MiB raw disk whose boot sector prints the three synthetic
  ## markers to COM1 and halts. Returns ``path``.
  const SectorSize = 512
  const DiskSize = 1024 * 1024
  var sector = newString(SectorSize)
  for i in 0 ..< SectorSize:
    sector[i] = '\0'
  for i, b in SyntheticBootSectorCode:
    sector[i] = char(b)
  let msg = syntheticBootMessage()
  doAssert SyntheticMessageOffset + msg.len <= SectorSize - 2,
    "synthetic boot sector: message does not fit in one sector"
  for i, c in msg:
    sector[SyntheticMessageOffset + i] = c
  # The BIOS boot signature. Without it SeaBIOS refuses the disk and the
  # guest never runs, which would look like a harness bug rather than a
  # malformed image.
  sector[SectorSize - 2] = char(0x55)
  sector[SectorSize - 1] = char(0xAA)

  let dir = parentDir(path)
  if dir.len > 0:
    createDir(dir)
  var f = open(path, fmWrite)
  defer: f.close()
  f.write(sector)
  var pad = newString(DiskSize - SectorSize)
  for i in 0 ..< pad.len:
    pad[i] = '\0'
  f.write(pad)
  path

proc syntheticBootSteps*(loginTimeoutSec = 60): seq[BootSmokeStep] =
  ## The ordered sequence the synthetic guest really produces.
  @[
    BootSmokeStep(pattern: SyntheticStage1Marker, timeoutSec: loginTimeoutSec,
                  label: "firmware handed control to the boot sector"),
    BootSmokeStep(pattern: SyntheticStage2Marker, timeoutSec: loginTimeoutSec,
                  label: "the guest kept running past the first marker"),
    BootSmokeStep(pattern: r"synthetic login: ", timeoutSec: loginTimeoutSec,
                  label: "the guest reached its login prompt"),
  ]

# ---------------------------------------------------------------------------
# The harness itself.

proc describeMiss(spec: BootSmokeSpec, stepIndex: int,
                  m: SerialMatch): string =
  let step = spec.steps[stepIndex]
  result = "boot-smoke: expected serial line was never seen.\n" &
    "  step        : " & $(stepIndex + 1) & " of " & $spec.steps.len & "\n" &
    "  pattern     : " & step.pattern & "\n" &
    "  expected    : " & (if step.label.len > 0: step.label else: "(unlabelled)") & "\n" &
    "  timeout     : " & $step.timeoutSec & "s (waited " & $m.elapsedMs & " ms)\n"
  if m.matchedText.len > 0:
    result.add("  serial tail : " & m.matchedText.strip() & "\n")

proc runBootSmoke*(spec: BootSmokeSpec): BootSmokeResult =
  ## Boot ``spec.imagePath`` and assert ``spec.steps`` in order.
  ##
  ## Never raises: a setup error, a missed line and a clean pass are all
  ## reported through ``BootSmokeResult`` so the caller can assert on the
  ## failure rather than on an exception escaping from somewhere in the
  ## middle. Teardown of the QEMU process, the CoW overlay and the run
  ## directory happens on every one of those paths.
  let started = epochTime()
  result = BootSmokeResult(outcome: bsSetupFailed, failedStepIndex: -1)

  if spec.steps.len == 0:
    result.failureMessage =
      "boot-smoke: refusing to run with an empty expected-line sequence; " &
      "a boot assertion that asserts nothing always passes"
    return

  let prefix = if spec.namePrefix.len > 0: spec.namePrefix
               else: QemuBootNamePrefix
  let artifactDir = if spec.artifactDir.len > 0: spec.artifactDir
                    else: resolveArtifactDir()
  let vmName = newQemuBootVmName(prefix)
  result.vmName = vmName

  let caseName = if spec.caseName.len > 0: spec.caseName else: "boot-smoke"
  let serialLogPath = artifactDir / (caseName & "." & vmName & ".serial.log")
  result.serialLogPath = serialLogPath

  var backend: QemuBootBackend
  try:
    backend = newQemuBootBackend(namePrefix = prefix)
  except CatchableError as e:
    result.failureMessage = "boot-smoke: backend construction failed: " & e.msg
    return
  result.runDir = backend.runDirFor(vmName)

  var extra = initTable[string, string]()
  if spec.imageFormat.len > 0:
    extra["diskFormat"] = spec.imageFormat
  let media = BootMediaSpec(
    name: vmName,
    kind: bmkQcow2,
    mediaPath: spec.imagePath,
    cpus: (if spec.cpus > 0: spec.cpus else: 2),
    memoryMB: (if spec.memoryMB > 0: spec.memoryMB else: 1024),
    generation: (if spec.generation > 0: spec.generation else: 2),
    acceleration: spec.acceleration,
    graphics: bgNone,
    serialLogPath: serialLogPath,
    extra: extra)

  var vm: VmHandle = nil
  var stream: SerialStream = nil
  try:
    try:
      vm = backend.bootFromMedia(media)
      stream = backend.captureSerial(vm)
      var allMatched = true
      for i, step in spec.steps:
        let m = backend.expectLine(stream, step.pattern,
                                   timeoutSec = max(step.timeoutSec, 1))
        result.matches.add(m)
        if not m.matched:
          result.outcome = bsPatternNotSeen
          result.failedStepIndex = i
          result.failureMessage = describeMiss(spec, i, m)
          result.serialTail = m.matchedText
          allMatched = false
          break
      if allMatched:
        result.outcome = bsPassed
        result.failureMessage = ""
        result.failedStepIndex = -1
    except CatchableError as e:
      result.outcome = bsSetupFailed
      result.failureMessage =
        "boot-smoke: " & $e.name & ": " & e.msg
  finally:
    # Unconditional: reached by a clean pass, a missed line, a timeout and
    # an exception alike. Neither call raises.
    if stream != nil:
      backend.closeSerial(stream)
    if vm != nil:
      backend.stopAndCleanup(vm, deleteVm = true)
  result.elapsedMs = int((epochTime() - started) * 1000)

proc serialLogExcerpt*(path: string, maxBytes = 4000): string =
  ## Tail of the captured transcript, for echoing into a failing gate's
  ## output. Missing/unreadable logs are reported as such rather than
  ## swallowed — "no serial log" is itself a diagnosis.
  if not fileExists(path):
    return "(no serial log at " & path & ")"
  try:
    let content = readFile(path)
    if content.len <= maxBytes:
      return content
    return "…\n" & content[content.len - maxBytes .. ^1]
  except CatchableError as e:
    return "(serial log unreadable: " & e.msg & ")"
