## Backend-agnostic snapshot-revert benchmark.
##
## Measures the per-iteration wall-clock cost of "revert from a hot
## snapshot back to a guest-ready state" across N iterations. The same
## program drives every backend that implements ``snapshotRunning``
## (today: Hyper-V; planned: Tart via ``tart suspend`` — see
## ``docs/design.md`` running-state snapshots note).
##
## Phases (timing decomposition output as JSON):
##
##   Phase A (one-time setup, paid once per bench run):
##     - revertToBaseline(<cold-baseline>)   ← bring VM to a known cold state
##     - startAndAwaitReady                  ← wait for the guest
##     - snapshotRunning(<hot-name>)         ← capture memory + CPU + device state
##
##   Phase B (per-iteration, repeated N times):
##     - restoreSnapshot(<hot-name>)         ← memory-image load
##     - startAndAwaitReady                  ← guest reachable again
##
##   Phase C (cleanup):
##     - remove the hot snapshot
##     - revertToBaseline(<cold-baseline>)   ← leave the VM in its starting state
##     - stopAndCleanup
##
## Usage:
##
##   vm-harness-bench-snapshot-revert
##     --backend <id>           backend id (hyperv, noop, tart-macos, ...)
##     --vm <name>              VM name the backend recognizes
##     --baseline <cold-name>   cold snapshot the bench reverts to between runs
##     --hot-name <name>        name for the bench's hot snapshot (default: bench-hot)
##     --iterations <N>         number of revert iterations (default: 3)
##     --ready-timeout <sec>    per-iteration guest-ready poll timeout (default: 60)
##     --cred-path <path>       backend-specific credentials file (Hyper-V: vm-cred.xml)
##     --output <path>          JSON output file (default: stdout)
##
## Output schema (one JSON object):
##
##   {
##     "backend": "...",
##     "vm": "...",
##     "iterations": N,
##     "phase_a_setup_ms":  ...,
##     "phase_a_snapshot_ms": ...,
##     "iterations_per_revert_ms": [..., ..., ...],
##     "iterations_per_ready_ms":  [..., ..., ...],
##     "per_iteration_total_ms":   [..., ..., ...],
##     "median_per_iteration_ms":  ...,
##     "phase_c_cleanup_ms":       ...
##   }

import std/[algorithm, json, os, strutils, times]

import vm_harness/types
import vm_harness/auto

# Force-register the backends we might dispatch to. Tart/UTM/Lima don't
# need to register on Windows (their constructors no-op probe to false),
# but importing them is harmless and keeps the bench usable on any host.
{.push warning[UnusedImport]: off.}
import vm_harness/backends/noop
import vm_harness/backends/hyperv
import vm_harness/backends/tart
import vm_harness/backends/utm
import vm_harness/backends/lima
import vm_harness/backends/wsl
# libvirt implements snapshotRunning as of campaign WR0, so `--backend
# libvirt` must resolve through newBackend(); without this import the
# backend never registers itself and the bench dies in the factory instead
# of producing the number WR0 needs.
import vm_harness/backends/libvirt
import vm_harness/backends/incus
{.pop.}

type
  BenchOpts = object
    backendId: BackendId
    vmName: string
    coldBaseline: string
    hotName: string
    iterations: int
    readyTimeoutSec: int
    credPath: string
    outputPath: string

proc parseArgs(): BenchOpts =
  result.hotName = "bench-hot"
  result.iterations = 3
  result.readyTimeoutSec = 60
  # parseopt's default is `--foo bar` → empty val + positional `bar`.
  # Walk the raw argv ourselves so both `--foo bar` and `--foo=bar`
  # work the same way (the more shell-friendly form is the former).
  let args = commandLineParams()
  var i = 0
  proc takeVal(flag: string): string =
    if args[i].contains('='):
      let parts = args[i].split('=', maxSplit = 1)
      inc i
      return parts[1]
    if i + 1 >= args.len:
      stderr.writeLine("--" & flag & " requires a value")
      quit(2)
    inc i
    let v = args[i]
    inc i
    v
  while i < args.len:
    let a = args[i]
    if not a.startsWith("--"):
      stderr.writeLine("unexpected positional: " & a)
      quit(2)
    let key = a.split('=', maxSplit = 1)[0][2 .. ^1]
    case key
    of "backend":       result.backendId = parseEnum[BackendId](takeVal("backend"))
    of "vm":            result.vmName = takeVal("vm")
    of "baseline":      result.coldBaseline = takeVal("baseline")
    of "hot-name":      result.hotName = takeVal("hot-name")
    of "iterations":    result.iterations = parseInt(takeVal("iterations"))
    of "ready-timeout": result.readyTimeoutSec = parseInt(takeVal("ready-timeout"))
    of "cred-path":     result.credPath = takeVal("cred-path")
    of "output":        result.outputPath = takeVal("output")
    of "help", "h":
      echo "see file header for usage"; quit(0)
    else:
      stderr.writeLine("unknown flag: --" & key); quit(2)
  if result.vmName.len == 0:
    stderr.writeLine("--vm is required"); quit(2)
  if result.coldBaseline.len == 0:
    stderr.writeLine("--baseline is required"); quit(2)
  if result.iterations < 1:
    stderr.writeLine("--iterations must be >= 1"); quit(2)

proc buildBackend(opts: BenchOpts): VmBackend =
  case opts.backendId
  of biHyperv:
    when defined(windows):
      let cred =
        if opts.credPath.len > 0: opts.credPath
        else: getEnv("LOCALAPPDATA") / "Repro" / "hyperv-m69" / "vm-cred.xml"
      result = newHyperVBackend(vmName = opts.vmName, credentialCachePath = cred)
    else:
      raise newException(BackendUnavailableError,
        "biHyperv bench requires a Windows host")
  of biNoop:
    result = newNoopBackend()
  else:
    # Other backends use their factory; bench may not be portable to
    # them yet (no snapshotRunning impl) but probing is harmless.
    result = newBackend(opts.backendId)

proc msSince(start: float): int = int((epochTime() - start) * 1000.0)

proc median(xs: seq[int]): int =
  if xs.len == 0: return 0
  var sorted = xs
  sorted.sort()
  if sorted.len mod 2 == 1:
    sorted[sorted.len div 2]
  else:
    (sorted[sorted.len div 2 - 1] + sorted[sorted.len div 2]) div 2

proc runBench(opts: BenchOpts): JsonNode =
  let backend = buildBackend(opts)
  var revertMs: seq[int] = @[]
  var readyMs: seq[int] = @[]
  var totalMs: seq[int] = @[]
  var phaseASetupMs = 0
  var phaseASnapshotMs = 0
  var phaseCCleanupMs = 0
  var vm: VmHandle = nil

  # --- Phase A ----------------------------------------------------------
  block phaseA:
    let aStart = epochTime()
    vm = backend.revertToBaseline(opts.coldBaseline)
    backend.startAndAwaitReady(vm, timeoutSec = opts.readyTimeoutSec)
    phaseASetupMs = msSince(aStart)
    let snapStart = epochTime()
    discard backend.snapshotRunning(opts.vmName, opts.hotName)
    phaseASnapshotMs = msSince(snapStart)

  # --- Phase B ----------------------------------------------------------
  for i in 1 .. opts.iterations:
    let revertStart = epochTime()
    backend.restoreSnapshot(opts.vmName, opts.hotName)
    let revertEnd = msSince(revertStart)
    revertMs.add(revertEnd)
    let readyStart = epochTime()
    backend.startAndAwaitReady(vm, timeoutSec = opts.readyTimeoutSec)
    let readyEnd = msSince(readyStart)
    readyMs.add(readyEnd)
    totalMs.add(revertEnd + readyEnd)

  # --- Phase C ----------------------------------------------------------
  block phaseC:
    let cStart = epochTime()
    try:
      backend.removeSnapshot(opts.vmName, opts.hotName)
    except CatchableError: discard
    try:
      discard backend.revertToBaseline(opts.coldBaseline)
    except CatchableError: discard
    try:
      backend.stopAndCleanup(vm, deleteVm = false)
    except CatchableError: discard
    phaseCCleanupMs = msSince(cStart)

  result = %*{
    "backend": $opts.backendId,
    "vm": opts.vmName,
    "iterations": opts.iterations,
    "phase_a_setup_ms": phaseASetupMs,
    "phase_a_snapshot_ms": phaseASnapshotMs,
    "iterations_per_revert_ms": revertMs,
    "iterations_per_ready_ms": readyMs,
    "per_iteration_total_ms": totalMs,
    "median_per_iteration_ms": median(totalMs),
    "phase_c_cleanup_ms": phaseCCleanupMs,
    "ready_timeout_sec": opts.readyTimeoutSec,
    "cold_baseline": opts.coldBaseline,
    "hot_snapshot": opts.hotName
  }

when isMainModule:
  let opts = parseArgs()
  let result = runBench(opts)
  let pretty = result.pretty()
  if opts.outputPath.len > 0:
    writeFile(opts.outputPath, pretty)
  else:
    echo pretty
