## vm-harness prune — reclaim ephemeral resources leaked by launchers that
## were hard-killed (SIGKILL / crash) before their teardown could run.
##
## vm-harness is a general tool shared by many projects, so cleanup is never
## global or implicit: a prune is always scoped to a caller-supplied
## ``ephemeralPrefix`` (the per-project tag already used to name ephemeral
## VMs) plus, for the qemu-windows-arm backend, its state directory. Nothing
## outside that scope is ever touched.
##
## Liveness is decided conservatively so a prune can never delete a running
## instance:
##   * qemu-windows-arm instance dirs carry a per-instance advisory lock; a
##     held lock means the owner is alive (race-free, PID-recycle proof).
##   * tart clones and legacy instance dirs fall back to the creator PID
##     embedded in the name, paired with an age guard so a recycled PID
##     cannot mask a genuine orphan.

import std/[os, strutils, times]
import ./backends/qemu_windows_arm
import ./backends/tart

type
  PruneScope* = object
    ephemeralPrefix*: string   ## required project scope (matched as a name prefix)
    stateDir*: string          ## qemu-windows-arm state dir (default when empty)
    olderThanSec*: int         ## age guard in seconds; 0 disables the guard
    dryRun*: bool              ## report what would be removed, delete nothing
    backend*: string           ## "qemu-windows-arm" | "tart" | "all"
    sweepTmp*: bool            ## also age-sweep transient /tmp scratch files

  PruneReport* = object
    removedInstanceDirs*: seq[string]
    liveInstanceDirs*: seq[string]
    freshInstanceDirs*: seq[string]
    removedTartClones*: seq[string]
    liveTartClones*: seq[string]
    removedTmpFiles*: seq[string]
    bytesReclaimed*: int64

const
  DefaultPruneAgeSec* = 3600
  # Transient scratch files vm-harness writes into the system temp dir. They
  # are consumed within a VM's provisioning window (seconds), so anything
  # older than the age guard is definitively orphaned.
  TartTmpPrefixes = ["vm-harness-tart-pwd-", "vm-harness-tart-mount-shares-"]
  QemuTmpPrefixes = ["vm-harness-qemu-win-arm-pwd-"]

proc parseTrailingTwo(name: string): tuple[epochMs: int64, pid: int] =
  ## ``<prefix>-<epochMs>-<pid>`` → (epochMs, pid); zeros when unparseable.
  result = (0'i64, 0)
  let parts = name.rsplit('-', 2)
  if parts.len == 3:
    try: result.epochMs = parseBiggestInt(parts[1])
    except ValueError: discard
    try: result.pid = parseInt(parts[2])
    except ValueError: discard

proc mtimeAgeSec(path: string): int =
  try:
    return max(0, int(epochTime() - getLastModificationTime(path).toUnixFloat()))
  except CatchableError:
    return 0

proc instanceAgeSec(name, path: string): int =
  ## Age of an ephemeral entry named ``<prefix>-<epochMs>-<pid>``. Uses the
  ## epoch-ms field when parseable, else the mtime. Only valid for the
  ## instance-dir / tart-clone naming — NOT the temp scratch files, whose
  ## field order differs, so those age by mtime alone.
  let (epochMs, _) = parseTrailingTwo(name)
  if epochMs > 0:
    return max(0, int(epochTime() - epochMs.float / 1000.0))
  mtimeAgeSec(path)

proc dirSizeBytes(path: string): int64 =
  try:
    for p in walkDirRec(path):
      try: result += getFileSize(p)
      except CatchableError: discard
  except CatchableError:
    discard

proc pruneQemuInstances(scope: PruneScope, ageSec: int, rep: var PruneReport) =
  let stateDir =
    if scope.stateDir.len > 0: scope.stateDir else: defaultStateDir()
  let instancesDir = stateDir / "instances"
  if not dirExists(instancesDir):
    return
  for kind, path in walkDir(instancesDir):
    if kind != pcDir:
      continue
    let name = extractFilename(path)
    if scope.ephemeralPrefix.len > 0 and not name.startsWith(scope.ephemeralPrefix):
      continue
    if instanceDirOwnerAlive(path):
      rep.liveInstanceDirs.add(path)
      continue
    if ageSec > 0 and instanceAgeSec(name, path) < ageSec:
      rep.freshInstanceDirs.add(path)
      continue
    let sz = dirSizeBytes(path)
    if not scope.dryRun:
      try: removeDir(path)
      except CatchableError: continue
    rep.removedInstanceDirs.add(path)
    rep.bytesReclaimed += sz

proc pruneTartClones(scope: PruneScope, ageSec: int, rep: var PruneReport) =
  if scope.ephemeralPrefix.len == 0:
    # A tart clone reap has no state dir to bound it; without a prefix it
    # would match every VM on the host, so we refuse to run unscoped.
    return
  let tb = newTartBackend(tartCmd = getEnv("VMH_TART_CMD", "tart"))
  var vms: seq[string]
  try: vms = tb.listTartVms()
  except CatchableError: return
  for v in vms:
    if not v.startsWith(scope.ephemeralPrefix):
      continue
    let (_, pid) = parseTrailingTwo(v)
    if pidAlive(pid):
      rep.liveTartClones.add(v)
      continue
    if ageSec > 0 and instanceAgeSec(v, "") < ageSec:
      continue
    if not scope.dryRun:
      try:
        tb.stopTartVm(v)
        tb.deleteTartVm(v)
      except CatchableError:
        continue
    rep.removedTartClones.add(v)

proc pruneTmpFiles(prefixes: openArray[string], ageSec: int,
                   scope: PruneScope, rep: var PruneReport) =
  let tmp = getTempDir()
  for kind, path in walkDir(tmp):
    if kind notin {pcFile, pcLinkToFile}:
      continue
    let base = extractFilename(path)
    var match = false
    for p in prefixes:
      if base.startsWith(p):
        match = true
        break
    if not match:
      continue
    if ageSec > 0 and mtimeAgeSec(path) < ageSec:
      continue
    var sz: int64 = 0
    try: sz = getFileSize(path)
    except CatchableError: discard
    if not scope.dryRun:
      try: removeFile(path)
      except CatchableError: continue
    rep.removedTmpFiles.add(path)
    rep.bytesReclaimed += sz

proc runPrune*(scope: PruneScope): PruneReport =
  ## Execute a scoped prune and return what was (or, in ``dryRun``, would be)
  ## reclaimed. Best-effort: individual failures are skipped, never raised.
  let ageSec = scope.olderThanSec
  let wantQemu = scope.backend in ["qemu-windows-arm", "all", ""]
  let wantTart = scope.backend in ["tart", "all", ""]
  if wantQemu:
    pruneQemuInstances(scope, ageSec, result)
  if wantTart:
    pruneTartClones(scope, ageSec, result)
  if scope.sweepTmp:
    if wantTart:
      pruneTmpFiles(TartTmpPrefixes, ageSec, scope, result)
    if wantQemu:
      pruneTmpFiles(QemuTmpPrefixes, ageSec, scope, result)
