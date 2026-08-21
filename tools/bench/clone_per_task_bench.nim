## Backend-agnostic clone-per-task benchmark.
##
## The counterpart to ``snapshot_revert_bench.nim``. That one measures the
## inner loop of ``recycle-from-pool-per-task``; this one measures the inner
## loop of ``clone-per-task``. Run both against the same backend and the
## comparison decides which algorithm that backend should use -- see
## ``docs/pool-algorithms.md`` for the rule and the recorded selections.
##
## Emits the same JSON shape and reports the same median so the two are
## directly comparable. Report the MEDIAN, not the mean: both loops throw
## occasional multi-second outliers from host I/O, and a mean lets one
## outlier pick an architecture.
##
## Phases:
##
##   Phase A (one-time):
##     - probeAvailability                   <- fail fast on the wrong host
##
##   Phase B (per-iteration, repeated N times):
##     - revertToBaseline(<baseline>)        <- produce a task-ready instance
##     - startAndAwaitReady                  <- guest reachable
##     - stopAndCleanup(deleteVm = true)     <- destroy it again
##
## WHAT ``revertToBaseline`` MEANS HERE, and why the number is only
## comparable within a backend:
##
## The lifecycle interface has no uniform "clone" primitive, because the
## backends genuinely differ:
##
##   * libvirt  -- creates a fresh per-job qcow2 CoW overlay over the golden
##                 and defines a domain around it. This IS clone-per-task,
##                 and the measurement is exactly right.
##   * incus    -- launches/copies an instance. Also a real clone.
##   * Hyper-V  -- restores a checkpoint on ONE long-lived VM. That is the
##                 RECYCLE operation, not a clone. Hyper-V's clone path is
##                 Export-VM + Import-VM, which this program does not drive.
##                 Measuring Hyper-V with this bench therefore does NOT give
##                 you its clone cost; see the hyperv notes for those
##                 figures, taken by hand.
##
## The program refuses to pretend otherwise: pass ``--assert-creates-instance``
## and it verifies the handle names differ between iterations, which is the
## observable difference between "made a new instance" and "reset the same
## one". Without a distinguishing name the flag fails the run rather than
## reporting a number that would be quietly mislabelled.

import std/[json, os, sequtils, algorithm, strutils, times]
import vm_harness

type
  BenchOpts = object
    backendId: BackendId
    vmName: string
    baseline: string
    iterations: int
    readyTimeoutSec: int
    credPath: string
    outputPath: string
    assertCreates: bool
    provisionBaseline: bool

proc parseArgs(): BenchOpts =
  result.backendId = biNoop
  result.iterations = 5
  result.readyTimeoutSec = 300
  # Same hand-rolled walk as snapshot_revert_bench so `--foo bar` and
  # `--foo=bar` behave identically.
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
    of "baseline":      result.baseline = takeVal("baseline")
    of "iterations":    result.iterations = parseInt(takeVal("iterations"))
    of "ready-timeout": result.readyTimeoutSec = parseInt(takeVal("ready-timeout"))
    of "cred-path":     result.credPath = takeVal("cred-path")
    of "output":        result.outputPath = takeVal("output")
    of "assert-creates-instance": result.assertCreates = true; inc i
    # Real backends already have their baseline; this exists so the bench can
    # be smoke-tested end to end against `--backend noop` without a
    # hypervisor. A benchmark that cannot be exercised is a benchmark nobody
    # can trust the numbers from.
    of "provision-baseline": result.provisionBaseline = true; inc i
    of "help", "h":
      echo "see file header for usage"; quit(0)
    else:
      stderr.writeLine("unknown flag: --" & key); quit(2)
  if result.baseline.len == 0:
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
    result = newBackend(opts.backendId)

proc msSince(start: float): int = int((epochTime() - start) * 1000.0)

proc median(xs: seq[int]): int =
  if xs.len == 0: return 0
  var s = xs
  s.sort()
  if s.len mod 2 == 1: s[s.len div 2]
  else: (s[s.len div 2 - 1] + s[s.len div 2]) div 2

proc runBench(opts: BenchOpts): JsonNode =
  let backend = buildBackend(opts)
  if not backend.probeAvailability():
    raise newException(BackendUnavailableError,
      $opts.backendId & " is not available on this host")

  if opts.provisionBaseline:
    var spec = BaselineSpec(name: opts.baseline, guestOs: goLinux,
                            guestArch: gaX86_64)
    backend.provisionBaseline(spec)

  var createMs, readyMs, destroyMs, totalMs: seq[int] = @[]
  var seenNames: seq[string] = @[]

  for iter in 0 ..< opts.iterations:
    let iterStart = epochTime()

    let cStart = epochTime()
    let vm = backend.revertToBaseline(opts.baseline)
    createMs.add(msSince(cStart))

    let rStart = epochTime()
    backend.startAndAwaitReady(vm, timeoutSec = opts.readyTimeoutSec)
    readyMs.add(msSince(rStart))

    seenNames.add(vm.name)

    let dStart = epochTime()
    backend.stopAndCleanup(vm, deleteVm = true)
    destroyMs.add(msSince(dStart))

    totalMs.add(msSince(iterStart))

  # A backend whose revertToBaseline resets one long-lived VM will hand back
  # the same name every time. That is a legitimate implementation, but it is
  # NOT clone-per-task, and reporting it as such would mislabel the number
  # that picks an architecture.
  let uniqueNames = seenNames.deduplicate()
  if opts.assertCreates and uniqueNames.len < opts.iterations:
    raise newException(ValueError,
      "--assert-creates-instance: expected " & $opts.iterations &
      " distinct instances, saw " & $uniqueNames.len & " (" &
      uniqueNames.join(", ") & "). This backend's revertToBaseline RESETS an " &
      "existing instance rather than creating one, so this bench is " &
      "measuring recycle, not clone.")

  result = %*{
    "bench": "clone_per_task",
    "backend": $opts.backendId,
    "vm": opts.vmName,
    "baseline": opts.baseline,
    "iterations": opts.iterations,
    "per_iteration_create_ms": createMs,
    "per_iteration_ready_ms": readyMs,
    "per_iteration_destroy_ms": destroyMs,
    "per_iteration_total_ms": totalMs,
    "median_per_iteration_ms": median(totalMs),
    "distinct_instances": uniqueNames.len,
    "ready_timeout_sec": opts.readyTimeoutSec
  }

when isMainModule:
  let opts = parseArgs()
  let res = runBench(opts)
  let rendered = res.pretty()
  if opts.outputPath.len > 0:
    writeFile(opts.outputPath, rendered)
  else:
    echo rendered
