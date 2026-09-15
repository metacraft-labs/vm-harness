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
##   * tart VM DIRECTORIES that `tart list` cannot see (``pruneTartVmDirs``)
##     are gated on four independent guards, each of which alone spares a
##     live VM — see that proc's doc comment.

import std/[options, os, sets, strutils, times]
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
    tartVmsDir*: string        ## tart VM home (default: resolved from env)

  PruneReport* = object
    removedInstanceDirs*: seq[string]
    liveInstanceDirs*: seq[string]
    freshInstanceDirs*: seq[string]
    removedTartClones*: seq[string]
    liveTartClones*: seq[string]
    removedTmpFiles*: seq[string]
    # --- the disk-less tart VM directory sweep (see pruneTartVmDirs) ---
    removedTartVmDirs*: seq[string]
      ## Directories `tart list` cannot see and that passed every guard.
    tartVmDirsListedByTart*: seq[string]
      ## Spared: Tart can see it, so Tart's own reaper owns it.
    tartVmDirsWithDisk*: seq[string]
      ## Spared: it still holds a guest disk. An UNLISTED directory that has
      ## one is an anomaly worth an operator's attention, never a deletion.
    tartVmDirsOwnerAlive*: seq[string]
      ## Spared: the creator PID embedded in the name is still running.
    freshTartVmDirs*: seq[string]
      ## Spared: inside the age floor. This is the guard that covers a VM
      ## being created RIGHT NOW, which has no disk image yet either.
    tartVmDirSweepAborted*: bool
      ## True when the sweep refused to run. Nothing was removed by it.
    tartVmDirSweepAbortReason*: string
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
  ## Reap ephemeral clones that ``tart list`` CAN see.
  ##
  ## THE RUN STATE IS CHECKED BEFORE THE PID, and that ordering is the safety
  ## property. Anything Tart does not report as ``stopped``/``suspended`` is
  ## spared, and a state that cannot be read or recognised reads as RUNNING
  ## (see ``isRunning`` in ./backends/tart.nim), so the reap fails toward
  ## sparing rather than toward deleting.
  ##
  ## The PID and age guards are kept, but only as additional reasons to SPARE
  ## a clone Tart already calls idle — they are not sufficient on their own.
  ## On the ordinary path the creator PID embedded in an ephemeral's name is
  ## ALIVE: measured on m3 2026-09-15 it is the supervising ``vm-harness run``
  ## process, which stays up for the whole job and is the parent of the ``tart
  ## run`` hosting the guest, so a reap gated on PID plus age proposed removing
  ## nothing on that host. The case such a reap gets WRONG is the supervisor
  ## being SIGKILLed while the orphaned ``tart run`` keeps the guest going:
  ## the PID is then genuinely dead, the age floor lapses, and a VM that is
  ## still serving a job becomes indistinguishable from residue. Only the run
  ## state separates the two, which is why it is consulted first.
  if scope.ephemeralPrefix.len == 0:
    # A tart clone reap has no state dir to bound it; without a prefix it
    # would match every VM on the host, so we refuse to run unscoped.
    return
  let tb = newTartBackend(tartCmd = getEnv("VMH_TART_CMD", "tart"))
  var rowsOpt: Option[seq[TartVmListing]]
  try: rowsOpt = tb.tryListTartVmsDetailed()
  except CatchableError: return
  if rowsOpt.isNone:
    return
  for row in rowsOpt.get():
    let v = row.name
    if not v.startsWith(scope.ephemeralPrefix):
      continue
    if row.isRunning:
      rep.liveTartClones.add(v)
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

proc newestActivitySec(path: string): int =
  ## Seconds since the most recent modification of ``path`` or of anything
  ## DIRECTLY inside it. Returns 0 — "brand new, do not touch" — when the
  ## directory cannot be read, because every failure here must push toward
  ## sparing rather than deleting.
  var newest = 0.0
  try:
    newest = getLastModificationTime(path).toUnixFloat()
  except CatchableError:
    return 0
  try:
    for kind, p in walkDir(path):
      try:
        let t = getLastModificationTime(p).toUnixFloat()
        if t > newest: newest = t
      except CatchableError:
        return 0
  except CatchableError:
    return 0
  if newest <= 0.0:
    return 0
  max(0, int(epochTime() - newest))

proc tartVmDirAgeSec(name, path: string): int =
  ## The YOUNGEST evidence of age available for a tart VM directory: the
  ## epoch-ms in its name AND the freshest mtime under it. Taking the minimum
  ## is the point — a directory whose name says "65 days old" but whose
  ## contents were written a second ago is being written to right now.
  result = instanceAgeSec(name, path)
  let recent = newestActivitySec(path)
  if recent < result:
    result = recent

proc pruneTartVmDirs(scope: PruneScope, ageSec: int, rep: var PruneReport) =
  ## Reclaim tart VM directories that Tart itself can no longer see.
  ##
  ## WHY THIS EXISTS. Tart derives the ``Disk``/``SizeOnDisk`` columns of
  ## ``tart list`` from the VM's ``disk.img``, and omits a VM that has none.
  ## A clone interrupted between "create the directory" and "materialise the
  ## disk" therefore leaves a directory holding only ``config.json`` and
  ## ``nvram.bin`` that is invisible to ``tart list``, unreachable by ``tart
  ## delete``, and consequently invisible to BOTH reapers that enumerate
  ## through the Tart CLI — ``pruneTartClones`` here and the session-start
  ## sweep in ``TartBackend.provisionBaseline``. On a macOS golden
  ## ``nvram.bin`` alone is 33 MB, so the leak is measured in GB, not in
  ## inodes. This is the ONLY code path that can reclaim one.
  ##
  ## WHY IT CANNOT RACE A CREATION. "No ``disk.img``" is also briefly true of
  ## a VM being cloned right now, so it is never the criterion on its own. A
  ## directory is removed only when ALL FOUR of these hold, and each one
  ## ALONE spares a live VM:
  ##   1. ``tart list`` does not name it — and if the listing cannot be read
  ##      at all the whole sweep ABORTS having removed nothing, because an
  ##      unreadable listing reads as "nothing is referenced";
  ##   2. it holds no ``disk.img`` — a VM that has one is a real VM whose
  ##      guest state deletion would destroy, whatever the listing says;
  ##   3. the creator PID embedded in its name is not running;
  ##   4. its youngest evidence of activity — name epoch AND freshest mtime
  ##      underneath — is older than the age floor.
  ## Guard 4 is the one that covers the creation window, since a VM being
  ## cloned right now fails 1, 2 and 4 simultaneously.
  if scope.ephemeralPrefix.len == 0:
    # Same refusal as pruneTartClones: without a project scope this would
    # match every VM directory on the host.
    return
  let vmsDir =
    if scope.tartVmsDir.len > 0: scope.tartVmsDir else: tartVmsDir()
  if not dirExists(vmsDir):
    return

  # Source of truth #1, and it must be READABLE. `listTartVms` returns an
  # empty seq both for "no VMs" and for "tart is missing / failed", and the
  # two mean opposite things here.
  let tb = newTartBackend(tartCmd = getEnv("VMH_TART_CMD", "tart"))
  var listedOpt: Option[seq[string]]
  try:
    listedOpt = tb.tryListTartVms()
  except CatchableError:
    listedOpt = none(seq[string])
  if listedOpt.isNone:
    rep.tartVmDirSweepAborted = true
    rep.tartVmDirSweepAbortReason =
      "`tart list` could not be read, so it is unknown which VM directories " &
      "are live; refusing to remove anything under " & vmsDir
    return
  var listed = initHashSet[string]()
  for v in listedOpt.get():
    listed.incl(v)

  for kind, path in walkDir(vmsDir):
    if kind != pcDir:
      continue
    let name = extractFilename(path)
    if not name.startsWith(scope.ephemeralPrefix):
      continue
    if name in listed:
      rep.tartVmDirsListedByTart.add(path)
      continue
    if fileExists(path / TartVmDiskName):
      rep.tartVmDirsWithDisk.add(path)
      continue
    let (_, pid) = parseTrailingTwo(name)
    if pidAlive(pid):
      rep.tartVmDirsOwnerAlive.add(path)
      continue
    if ageSec > 0 and tartVmDirAgeSec(name, path) < ageSec:
      rep.freshTartVmDirs.add(path)
      continue
    let sz = dirSizeBytes(path)
    if not scope.dryRun:
      try: removeDir(path)
      except CatchableError: continue
    rep.removedTartVmDirs.add(path)
    rep.bytesReclaimed += sz

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
    # Runs after the CLI-driven clone reap, and reclaims exactly what that
    # reap cannot see: VM directories absent from `tart list`.
    pruneTartVmDirs(scope, ageSec, result)
  if scope.sweepTmp:
    if wantTart:
      pruneTmpFiles(TartTmpPrefixes, ageSec, scope, result)
    if wantQemu:
      pruneTmpFiles(QemuTmpPrefixes, ageSec, scope, result)
