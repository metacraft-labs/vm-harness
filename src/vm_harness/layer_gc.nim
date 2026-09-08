## vm-harness layer GC — deleting a base image, snapshot or backing file is
## refused while anything still references it, and per-job overlays that
## nothing references any more are swept.
##
## ## Why this lives here
##
## A LAYER is a file on a host that other files and running instances point
## at: a golden qcow2 that per-job overlays are copy-on-write clones of, or a
## published image a container was launched from. vm-harness is the component
## that CREATES those relationships — ``provisionEphemeralClone`` runs
## ``qemu-img create -f qcow2 -b <golden>`` and names the result
## ``<domain>.overlay.qcow2`` in the image pool — so it is the component that
## can answer whether one still exists. Nothing else in the workspace models a
## qcow2 backing chain.
##
## Two things this is NOT, both of which have their own owner and a different
## referent:
##
##   * It is not a LEASE reaper. A lease expires on a deadline and on holder
##     liveness; a backing chain expires on nothing and is a pure structural
##     fact about files on disk.
##   * It is not a content-addressed STORE GC. A store entry is referenced by
##     hardlinks and is decided by root reachability over a CAS prefix. That
##     is a different question with a different answer and must not be
##     answered by this code.
##
## ## The guard is a refusal, not a warning
##
## Deleting a layer while an overlay is stacked on it does not degrade the
## overlay, it destroys it: every unwritten block in the overlay resolves
## through the backing file, so removing the backing file turns a running
## guest into one that reads garbage or fails IO. There is no partial
## outcome to warn about. ``deleteLayer`` therefore returns ``lgoRefused``
## with the referents NAMED, and the CLI maps that to a non-zero exit.
##
## ## Reading a backing file without shelling out
##
## ``qcow2BackingFile`` parses the qcow2 header directly. ``qemu-img info``
## would answer the same question, but a GUARD that has to spawn a process
## per candidate file is a guard that gets skipped on a large pool, and one
## that reports "no backing file" when the binary is missing is a guard that
## fails OPEN — it would permit exactly the deletion it exists to refuse.
## The header is a fixed, documented 24-byte prefix; parsing it cannot fail
## for a reason the caller should ignore.
##
## ## Sizes are reported twice, on purpose
##
## Overlays are sparse: a per-job CoW overlay's apparent size is the size of
## the golden it backs onto, while its allocated size is only the blocks the
## job actually wrote. A sweep that reported one number would be wrong by
## more than an order of magnitude in whichever direction it chose, and a
## fixture that asserted on one number would pass against an implementation
## that miscounted the other. Both are always carried.

import std/[algorithm, os, strutils, times]

when defined(posix):
  import std/posix

type
  LayerReferentKind* = enum
    lrkOverlay      ## a qcow2 file whose backing file is this layer
    lrkDomain       ## a defined domain whose disk resolves onto this layer
    lrkContainer    ## a container/instance created from this layer's image
    lrkSnapshot     ## a snapshot whose disk or memory state names this layer

  LayerReferent* = object
    kind*: LayerReferentKind
    name*: string     ## overlay basename / domain name / container name
    path*: string     ## the referring file, when the referent is one

  OverlayFile* = object
    ## One per-job copy-on-write overlay in an image pool.
    path*: string
    name*: string
      ## The instance the overlay belongs to. For the naming
      ## ``provisionEphemeralClone`` uses (``<domain>.overlay.qcow2``) this is
      ## the domain name; otherwise it is the file's stem.
    backingFile*: string     ## absolute path, empty when the file has none
    apparentBytes*: int64    ## ``st_size`` — what the guest sees
    allocatedBytes*: int64   ## ``st_blocks * 512`` — what the disk pays
    mtimeUnix*: int64

  LayerScope* = object
    ## Everything the planner is allowed to know. Deliberately DATA rather
    ## than a live hypervisor handle: the decision is a pure function of it,
    ## so a fixture can drive the real decision procedure without a
    ## hypervisor, and the CLI populates it from the real one.
    imagePoolDir*: string
    liveDomains*: seq[string]
      ## Names of DEFINED domains (running or not). A defined-but-shut-off
      ## domain still owns its overlay: undefining it is a separate operator
      ## action, and sweeping the disk out from under it would break the next
      ## start.
    liveContainers*: seq[string]
    containerImages*: seq[string]
      ## Image aliases/fingerprints currently in use by ``liveContainers``,
      ## positionally aligned with it.
    snapshotFiles*: seq[string]
      ## Absolute paths of snapshot disk/memory-state files. A snapshot's
      ## frozen disk is a backing file for the live overlay above it, so a
      ## layer named by one is in use.
    nowUnix*: int64          ## injected clock; 0 means read the real one
    olderThanSec*: int       ## age guard for the sweep; 0 disables it
    dryRun*: bool

  LayerGcOutcome* = enum
    lgoDeleted
    lgoRefused
    lgoAbsent
    lgoDryRun

  LayerGcResult* = object
    outcome*: LayerGcOutcome
    layerPath*: string
    referents*: seq[LayerReferent]
    apparentBytes*: int64
    allocatedBytes*: int64
    message*: string

  OverlaySweepReport* = object
    scanned*: int
    removed*: seq[OverlayFile]
    keptLive*: seq[OverlayFile]
    keptFresh*: seq[OverlayFile]
    removedApparentBytes*: int64
    removedAllocatedBytes*: int64
    keptApparentBytes*: int64
    keptAllocatedBytes*: int64

const
  OverlaySuffix* = ".overlay.qcow2"
  DefaultStaleOverlayAgeSec* = 24 * 3600
  Qcow2Magic = ['Q', 'F', 'I', '\xfb']

# ---------------------------------------------------------------------------
# qcow2 header parsing.
# ---------------------------------------------------------------------------

proc beU32(b: openArray[byte]; off: int): uint32 =
  (uint32(b[off]) shl 24) or (uint32(b[off + 1]) shl 16) or
    (uint32(b[off + 2]) shl 8) or uint32(b[off + 3])

proc beU64(b: openArray[byte]; off: int): uint64 =
  (uint64(beU32(b, off)) shl 32) or uint64(beU32(b, off + 4))

proc qcow2BackingFile*(path: string): string =
  ## The backing file recorded in a qcow2 header, or "" when the file has
  ## none, is not a qcow2, or cannot be read.
  ##
  ## Layout (all big-endian, from the qcow2 specification):
  ##   0..3   magic ``QFI\xfb``
  ##   4..7   version
  ##   8..15  backing_file_offset  (0 ⇒ no backing file)
  ##   16..19 backing_file_size    (bytes, not NUL-terminated)
  ##
  ## An unreadable or malformed file yields "" — which the CALLER must treat
  ## as "this file references nothing", never as "nothing references this
  ## file". The two are not the same question and only the second would be
  ## unsafe to answer from an empty string.
  var f: File
  if not open(f, path, fmRead):
    return ""
  defer: close(f)
  var header: array[24, byte]
  if readBuffer(f, addr header[0], header.len) != header.len:
    return ""
  for i in 0 ..< 4:
    if header[i] != byte(ord(Qcow2Magic[i])):
      return ""
  let offset = beU64(header, 8)
  let size = beU32(header, 16)
  if offset == 0'u64 or size == 0'u32 or size > 4096'u32:
    return ""
  try:
    setFilePos(f, int64(offset))
  except IOError:
    return ""
  var buf = newString(int(size))
  if readBuffer(f, addr buf[0], buf.len) != buf.len:
    return ""
  buf

# ---------------------------------------------------------------------------
# Scanning an image pool.
# ---------------------------------------------------------------------------

proc allocatedBytesOf(path: string): int64 =
  ## ``st_blocks * 512``. This is the number that says what the DISK is
  ## paying, and for a copy-on-write overlay it is nothing like ``st_size``.
  when defined(posix):
    var st: Stat
    if stat(path.cstring, st) == 0:
      return int64(st.st_blocks) * 512'i64
    return 0'i64
  else:
    # Windows has no portable st_blocks; report the apparent size so the
    # number is never silently zero. Callers that compare the two must
    # therefore not treat equality as proof of a non-sparse file on Windows.
    try: getFileSize(path)
    except OSError, IOError: 0'i64

proc overlayInstanceName*(fileName: string): string =
  ## ``<domain>.overlay.qcow2`` → ``<domain>``; any other name → its stem.
  if fileName.endsWith(OverlaySuffix):
    fileName[0 ..< fileName.len - OverlaySuffix.len]
  else:
    fileName.splitFile.name

proc scanOverlays*(imagePoolDir: string): seq[OverlayFile] =
  ## Every qcow2 in the pool that HAS a backing file, i.e. every overlay.
  ## A qcow2 without one is a base image, not an overlay, and this never
  ## returns it — a sweep must not be able to reach a golden by accident.
  result = @[]
  if not dirExists(imagePoolDir):
    return
  for kind, path in walkDir(imagePoolDir):
    if kind != pcFile:
      continue
    let backing = qcow2BackingFile(path)
    if backing.len == 0:
      continue
    var entry = OverlayFile(
      path: path,
      name: overlayInstanceName(extractFilename(path)),
      backingFile:
        if isAbsolute(backing): backing
        else: parentDir(path) / backing,
      allocatedBytes: allocatedBytesOf(path))
    try:
      entry.apparentBytes = getFileSize(path)
      entry.mtimeUnix = toUnix(getLastModificationTime(path))
    except OSError, IOError:
      discard
    result.add(entry)
  result.sort(proc (a, b: OverlayFile): int = cmp(a.path, b.path))

# ---------------------------------------------------------------------------
# The in-use guard.
# ---------------------------------------------------------------------------

proc samePath(a, b: string): bool =
  ## Compare by resolved absolute path so a symlinked pool, a relative
  ## backing reference, or a trailing ``/.`` cannot make a live reference
  ## look like a different file. Falls back to a textual compare when a path
  ## cannot be resolved (it may legitimately not exist yet).
  if a.len == 0 or b.len == 0:
    return false
  let ra = try: expandFilename(a) except OSError, ValueError: a
  let rb = try: expandFilename(b) except OSError, ValueError: b
  ra == rb

proc layerReferents*(scope: LayerScope; layerPath: string;
                     overlays: seq[OverlayFile]): seq[LayerReferent] =
  ## Everything that still points at ``layerPath``.
  ##
  ## Order matters for the diagnostic, not for correctness: overlays first,
  ## because an overlay is the referent an operator can act on (destroy the
  ## job), then the domain that owns it, then containers and snapshots.
  result = @[]
  for overlay in overlays:
    if samePath(overlay.backingFile, layerPath):
      result.add(LayerReferent(kind: lrkOverlay, name: overlay.name,
        path: overlay.path))
      if overlay.name in scope.liveDomains:
        result.add(LayerReferent(kind: lrkDomain, name: overlay.name,
          path: overlay.path))
  for i, container in scope.liveContainers:
    if i < scope.containerImages.len:
      let image = scope.containerImages[i]
      if image.len > 0 and
          (samePath(image, layerPath) or image == extractFilename(layerPath)):
        result.add(LayerReferent(kind: lrkContainer, name: container,
          path: image))
  for snapshot in scope.snapshotFiles:
    if samePath(qcow2BackingFile(snapshot), layerPath):
      result.add(LayerReferent(kind: lrkSnapshot,
        name: extractFilename(snapshot), path: snapshot))

proc describe*(referents: seq[LayerReferent]): string =
  var parts: seq[string] = @[]
  for r in referents:
    let kindName =
      case r.kind
      of lrkOverlay: "overlay"
      of lrkDomain: "domain"
      of lrkContainer: "container"
      of lrkSnapshot: "snapshot"
    parts.add(kindName & " '" & r.name & "'" &
      (if r.path.len > 0 and r.path != r.name: " (" & r.path & ")" else: ""))
  parts.join(", ")

proc planLayerDeletion*(scope: LayerScope; layerPath: string): LayerGcResult =
  ## Decide, without touching anything. ``deleteLayer`` is this plus the
  ## unlink, so a ``--dry-run`` and a real run can never disagree about the
  ## decision.
  result.layerPath = layerPath
  let receipt = parentDir(layerPath) / "instance.json"
  if fileExists(receipt) or symlinkExists(receipt):
    result.outcome = lgoRefused
    result.message = "durable instance data requires instance destroy --purge: " & receipt
    return
  if not fileExists(layerPath):
    result.outcome = lgoAbsent
    result.message = "layer does not exist: " & layerPath
    return
  result.apparentBytes =
    try: getFileSize(layerPath) except OSError, IOError: 0'i64
  result.allocatedBytes = allocatedBytesOf(layerPath)
  let overlays = scanOverlays(scope.imagePoolDir)
  result.referents = layerReferents(scope, layerPath, overlays)
  if result.referents.len > 0:
    result.outcome = lgoRefused
    result.message = "refusing to delete layer " & layerPath &
      ": still referenced by " & describe(result.referents)
  else:
    result.outcome = lgoDryRun
    result.message = "layer " & layerPath & " is unreferenced"

proc deleteLayer*(scope: LayerScope; layerPath: string): LayerGcResult =
  ## Delete a layer, or REFUSE with its referents named.
  ##
  ## The refusal is the whole point, so it is checked here rather than left
  ## to the caller: a guard a caller can forget to call is not a guard.
  result = planLayerDeletion(scope, layerPath)
  if result.outcome != lgoDryRun:
    return
  if scope.dryRun:
    result.message = "would delete unreferenced layer " & layerPath
    return
  try:
    removeFile(layerPath)
    result.outcome = lgoDeleted
    result.message = "deleted unreferenced layer " & layerPath
  except OSError as err:
    result.outcome = lgoRefused
    result.message = "could not delete layer " & layerPath & ": " & err.msg

proc layerGcExitCode*(outcome: LayerGcOutcome): int =
  ## The process exit code for a layer-GC outcome.
  ##
  ## A REFUSAL must be non-zero, and it must be distinguishable from a usage
  ## error, or a caller cannot tell "the layer is in use" from "you typed the
  ## flag wrong" without parsing prose. 2 is this CLI's usage code
  ## everywhere, so the refusal takes 3.
  ##
  ## It lives here, next to the decision, rather than inline in the CLI, so
  ## the gate that asserts "a refusal exits non-zero" and the code that
  ## exits share one definition. An exit code asserted in one place and
  ## produced in another is an exit code that drifts.
  case outcome
  of lgoRefused: 3
  of lgoDeleted, lgoAbsent, lgoDryRun: 0

# ---------------------------------------------------------------------------
# Stale-overlay sweep.
# ---------------------------------------------------------------------------

proc sweepStaleOverlays*(scope: LayerScope): OverlaySweepReport =
  ## Remove per-job overlays that no defined domain owns and that are older
  ## than the age guard. Two independent conditions, BOTH required:
  ##
  ##   * LIVENESS. An overlay whose instance name is a defined domain is
  ##     kept whatever its age. This is the primary condition and it is not
  ##     an age heuristic: a long-lived domain's overlay is old by design.
  ##   * AGE. An overlay no domain owns is still kept until it is older than
  ##     ``olderThanSec``, because a clone that is being provisioned right
  ##     now exists on disk for a window before its domain is defined.
  ##     Without the guard the sweep would race provisioning.
  ##
  ## Golden images are structurally unreachable here: ``scanOverlays``
  ## returns only files that HAVE a backing file, and a golden has none.
  let now = if scope.nowUnix != 0: scope.nowUnix else: toUnix(getTime())
  let ageGuard = if scope.olderThanSec > 0: scope.olderThanSec
                 else: DefaultStaleOverlayAgeSec
  for overlay in scanOverlays(scope.imagePoolDir):
    inc result.scanned
    let receipt = parentDir(overlay.path) / "instance.json"
    if fileExists(receipt) or symlinkExists(receipt) or
        overlay.name in scope.liveDomains or
        overlay.name in scope.liveContainers:
      result.keptLive.add(overlay)
      result.keptApparentBytes += overlay.apparentBytes
      result.keptAllocatedBytes += overlay.allocatedBytes
      continue
    if int(now - overlay.mtimeUnix) < ageGuard:
      result.keptFresh.add(overlay)
      result.keptApparentBytes += overlay.apparentBytes
      result.keptAllocatedBytes += overlay.allocatedBytes
      continue
    if scope.dryRun:
      result.removed.add(overlay)
      result.removedApparentBytes += overlay.apparentBytes
      result.removedAllocatedBytes += overlay.allocatedBytes
      continue
    try:
      removeFile(overlay.path)
      result.removed.add(overlay)
      result.removedApparentBytes += overlay.apparentBytes
      result.removedAllocatedBytes += overlay.allocatedBytes
    except OSError:
      result.keptLive.add(overlay)
      result.keptApparentBytes += overlay.apparentBytes
      result.keptAllocatedBytes += overlay.allocatedBytes
