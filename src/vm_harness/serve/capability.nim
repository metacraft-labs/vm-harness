## vm-harness serve — CAPABILITY MANIFEST + detection (RA6).
##
## The host self-reports a *machine-checkable* capability manifest that a
## remote controller reads over ``GET /v1/manifest``. It is the SOURCE for the
## Phase-C runner labels — labels are DERIVED from real hardware here, not
## hand-maintained in a class name (the operator's core complaint this campaign
## fixes).
##
## Design: every capability is decided by a **pure function** over injected
## inputs (raw ``/proc/cpuinfo`` text, ``/sys`` file contents, probe-binary
## exit results). The impure ``detectHostCapabilities`` merely gathers those
## inputs from the live host and feeds the pure deciders, so the whole
## detection surface is hermetically testable against fixtures
## (``tests/e2e/t_vmharness_serve_enrollment.nim`` +
## ``tests/unit/t_serve_enrollment.nim``) with the ONLY sanctioned mocks being
## a mock ``/proc/cpuinfo`` and mock probe outputs.
##
## When a probe BINARY is absent (e.g. ``nvidia-smi`` / ``lspci`` not
## installed, ``/sys/module/kvm_intel`` missing) the corresponding capability
## is reported ``false`` — "not proven present", never a guess. That is the
## safe default for label derivation: a host advertises only what its manifest
## proves (the RC1 linter enforces ``advertised ⊆ proven``).

import std/[json, strutils, sets, tables, os, osproc]

const
  ManifestVersion* = "1"
    ## Bumped on any breaking change to the manifest schema. Carried in the
    ## ``manifestVersion`` field so a controller detects a mismatch before
    ## interpreting fields, and so the RC1 label-derivation stays pinned.

# ---------------------------------------------------------------------------
# x86-64 micro-architecture levels (the psABI "x86-64-v{1,2,3,4}" feature
# groups). The controller maps these straight to the `x86-64-vN` runner label.
# Flag NAMES are the /proc/cpuinfo spellings (Linux kernel), which differ from
# the ISA names in a few cases (pni=sse3, lahf_lm=lahf/sahf, abm covers
# lzcnt/popcnt-on-AMD). Documented per group so the mapping is auditable.

const
  V2Flags = ["cx16", "lahf_lm", "popcnt", "pni", "sse4_1", "sse4_2", "ssse3"]
    ## x86-64-v2: SSE3/SSSE3/SSE4.1/SSE4.2, POPCNT, CMPXCHG16B, LAHF/SAHF.
  V3Flags = ["avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "movbe"]
    ## x86-64-v3: AVX/AVX2, BMI1/BMI2, F16C, FMA, MOVBE (+ ABM/OSXSAVE which
    ## v2's popcnt + the AVX support imply on any real v3 part).
  V4Flags = ["avx512f", "avx512bw", "avx512cd", "avx512dq", "avx512vl"]
    ## x86-64-v4: the AVX-512 foundation + BW/CD/DQ/VL.

proc parseCpuFlags*(procCpuinfo: string): seq[string] =
  ## Extract the (deduplicated) CPU feature flags from ``/proc/cpuinfo`` text.
  ## Reads the first ``flags`` (x86) or ``Features`` (arm64) line.
  for line in procCpuinfo.splitLines():
    let low = line.toLowerAscii()
    if low.startsWith("flags") or low.startsWith("features"):
      let idx = line.find(':')
      if idx >= 0:
        var seen = initOrderedTable[string, bool]()
        for f in line[idx + 1 .. ^1].splitWhitespace():
          seen[f] = true
        for k in seen.keys: result.add(k)
        return

proc archLevelFromFlags*(flags: seq[string], arch: string): string =
  ## Derive the x86-64 micro-arch level from CPU flags. Returns
  ## ``"x86-64-v1".."x86-64-v4"`` for x86-64 hosts (v1 = any 64-bit baseline),
  ## or ``""`` for non-x86 architectures (arm64 has no such psABI levels — the
  ## controller uses the plain ``arch`` label there).
  let a = arch.toLowerAscii()
  if a notin ["x86_64", "amd64", "x64"]:
    return ""
  var have = initHashSet[string]()
  for f in flags: have.incl(f.toLowerAscii())
  proc hasAll(group: openArray[string]): bool =
    for g in group:
      if g notin have: return false
    true
  if hasAll(V2Flags) and hasAll(V3Flags) and hasAll(V4Flags):
    return "x86-64-v4"
  if hasAll(V2Flags) and hasAll(V3Flags):
    return "x86-64-v3"
  if hasAll(V2Flags):
    return "x86-64-v2"
  "x86-64-v1"

proc cpuCount*(procCpuinfo: string): int =
  ## Count logical CPUs = number of ``processor`` lines in ``/proc/cpuinfo``.
  for line in procCpuinfo.splitLines():
    if line.toLowerAscii().startsWith("processor"):
      inc result

proc memTotalMb*(procMeminfo: string): int =
  ## Parse ``MemTotal`` (kB) from ``/proc/meminfo`` and return whole MiB.
  for line in procMeminfo.splitLines():
    if line.toLowerAscii().startsWith("memtotal"):
      let parts = line.splitWhitespace()
      if parts.len >= 2:
        let kb = try: parseInt(parts[1]) except ValueError: 0
        return kb div 1024
  0

proc gpuPresent*(nvidiaSmiOk: bool, lspciText: string): bool =
  ## GPU present iff ``nvidia-smi`` succeeded OR ``lspci`` shows a VGA / 3D /
  ## Display controller from a known GPU vendor. Pure over the injected probe
  ## results so it is fixture-testable.
  if nvidiaSmiOk: return true
  for line in lspciText.splitLines():
    let low = line.toLowerAscii()
    if ("vga compatible controller" in low) or ("3d controller" in low) or
       ("display controller" in low):
      if ("nvidia" in low) or ("amd" in low) or ("advanced micro devices" in low) or
         ("intel" in low):
        return true
  false

proc nestedVirt*(kvmIntelNested, kvmAmdNested: string): bool =
  ## Nested virtualization enabled iff either KVM module reports ``Y``/``1``
  ## in ``/sys/module/kvm_{intel,amd}/parameters/nested``.
  proc on(v: string): bool =
    let s = v.strip().toLowerAscii()
    s == "y" or s == "1"
  on(kvmIntelNested) or on(kvmAmdNested)

proc rrHwCounters*(perfEventParanoid: string, arch: string): bool =
  ## rr's hardware-counter recording needs (a) an x86-64 host and (b) the
  ## kernel to permit userspace PMU access, i.e.
  ## ``/proc/sys/kernel/perf_event_paranoid <= 1``. This is a NECESSARY,
  ## machine-checkable precondition; rr does further CPU-model checks at
  ## runtime, so this is reported as "counters accessible", the label the
  ## controller keys on. Empty/unreadable paranoid file ⇒ false.
  let a = arch.toLowerAscii()
  if a notin ["x86_64", "amd64", "x64"]:
    return false
  let s = perfEventParanoid.strip()
  if s.len == 0: return false
  let v = try: parseInt(s) except ValueError: return false
  v <= 1

type
  HostCapabilities* = object
    ## The machine-checkable capability manifest. Serialized under
    ## ``GET /v1/manifest`` (inside the signed identity) and consumed by the
    ## RC1 label-derivation. Every field is self-reported from the host.
    os*: string                 ## "linux" | "windows" | "macos"
    arch*: string               ## "x86_64" | "arm64" | …
    archLevel*: string          ## "x86-64-v2".."v4"; "" for non-x86
    cpuCount*: int
    memTotalMb*: int
    gpu*: bool
    nestedVirt*: bool
    docker*: bool
    podman*: bool
    rrHwCounters*: bool
    hypervisors*: seq[tuple[id: string, available: bool, guests: seq[string]]]
      ## the hypervisor backends THIS daemon can drive (from the same probe
      ## the ``/v1/info`` seed uses), so the controller learns which
      ## incus/libvirt/hyperv/tart pools this host can back.

proc toJson*(c: HostCapabilities): JsonNode =
  ## Stable, sorted-by-construction JSON schema (v = ``ManifestVersion``).
  var hv = newJArray()
  for h in c.hypervisors:
    hv.add(%*{"id": h.id, "available": h.available, "guests": h.guests})
  result = %*{
    "manifestVersion": ManifestVersion,
    "os": c.os,
    "arch": c.arch,
    "archLevel": c.archLevel,
    "cpuCount": c.cpuCount,
    "memTotalMb": c.memTotalMb,
    "gpu": c.gpu,
    "nestedVirt": c.nestedVirt,
    "docker": c.docker,
    "podman": c.podman,
    "rrHwCounters": c.rrHwCounters,
    "hypervisors": hv}

# ---------------------------------------------------------------------------
# Impure host gathering. Reads the live host's /proc, /sys, and probe binaries
# and feeds the pure deciders above. Kept tiny + tolerant: any missing input
# degrades to the safe "false"/"" default rather than raising.

proc readOrEmpty(path: string): string =
  try:
    if fileExists(path): readFile(path) else: ""
  except CatchableError: ""

proc binaryPresent(name: string): bool =
  findExe(name).len > 0

proc runOk(exe: string, args: openArray[string]): bool =
  ## Run a probe binary, discard output, return true iff it exits 0. Missing
  ## binary ⇒ false.
  if findExe(exe).len == 0: return false
  try:
    let p = startProcess(exe, args = @args,
                         options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    for _ in p.lines: discard    # drain so the pipe never blocks
    p.waitForExit() == 0
  except CatchableError:
    false

proc probeLspci(): string =
  if findExe("lspci").len == 0: return ""
  try: execProcess("lspci", options = {poUsePath, poStdErrToStdOut})
  except CatchableError: ""

proc detectArch*(): string =
  ## Runtime CPU architecture as a manifest string.
  when defined(amd64): "x86_64"
  elif defined(arm64) or defined(aarch64): "arm64"
  elif defined(i386): "i386"
  else: hostCPU

proc detectHostCapabilities*(
    hypervisors: seq[tuple[id: string, available: bool, guests: seq[string]]] = @[]):
    HostCapabilities =
  ## Gather the live host's capability manifest. ``hypervisors`` is passed in
  ## by the daemon (from its backend registry) so this module does not depend
  ## on the backend layer. Off-Linux the /proc-based fields are best-effort;
  ## the Phase-A fleet only enrolls Linux/macOS/Windows serve hosts and the
  ## controller keys on ``os``/``arch`` there.
  result.os =
    when defined(windows): "windows"
    elif defined(macosx): "macos"
    elif defined(linux): "linux"
    else: hostOS
  result.arch = detectArch()
  result.hypervisors = hypervisors

  let cpuinfo = readOrEmpty("/proc/cpuinfo")
  let meminfo = readOrEmpty("/proc/meminfo")
  let flags = parseCpuFlags(cpuinfo)
  result.archLevel = archLevelFromFlags(flags, result.arch)
  result.cpuCount = max(cpuCount(cpuinfo), countProcessors())
  result.memTotalMb = memTotalMb(meminfo)
  result.gpu = gpuPresent(runOk("nvidia-smi", ["-L"]), probeLspci())
  result.nestedVirt = nestedVirt(
    readOrEmpty("/sys/module/kvm_intel/parameters/nested"),
    readOrEmpty("/sys/module/kvm_amd/parameters/nested"))
  result.docker = binaryPresent("docker")
  result.podman = binaryPresent("podman")
  result.rrHwCounters = rrHwCounters(
    readOrEmpty("/proc/sys/kernel/perf_event_paranoid"), result.arch)
