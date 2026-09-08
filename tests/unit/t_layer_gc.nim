## Layer GC: the in-use guard and the stale-overlay sweep.
##
## MOCK POLICY — NO OBJECT IS MOCKED IN THIS FILE, AND NONE MAY BE.
## Every layer and every overlay is a REAL qcow2 file created by the real
## ``qemu-img``, with a real copy-on-write backing relationship, in a real
## temporary directory. The guard reads their real headers with the real
## parser. A synthesised header would have proved the parser parses what the
## test writes, which is the one thing that cannot go wrong in production.
##
## The two things supplied as data rather than queried are the DEFINED-DOMAIN
## and DEFINED-CONTAINER name sets. That is the module's designed seam, not a
## stub of one: ``LayerScope`` is data, ``planLayerDeletion`` is a pure
## function of it, and the CLI populates it from ``virsh list --all`` /
## ``incus list``. Querying a live hypervisor from a unit test would make the
## test both unrunnable in CI and a governance problem — this suite must
## never touch a real domain.
##
## ONE substitution is used and it is justified here, as the policy requires.
## The last suite drives ``tryListAllDomainNames`` against a FAKE ``virsh``:
## a two-line shell script on ``PATH``-free absolute invocation, executed as a
## real subprocess through the real ``startProcess`` path. It is not a mock
## object — no type is replaced and no call is recorded — it is a real
## executable standing in for one whose failure modes cannot be produced on
## demand. The property under test is what the CLI does when ``virsh`` CANNOT
## answer, and the only alternatives are stopping libvirtd on the developer's
## machine (destructive, and forbidden by this milestone's governance) or not
## testing the safety property at all. The seam is the process boundary, which
## is exactly where the real failure occurs.
##
## ``qemu-img`` is a hard prerequisite here, not an optional one. If it is
## missing the suite FAILS rather than skipping: a guard that reports success
## because it could not build its own fixture is exactly the fail-open shape
## the guard exists to prevent.

import std/[os, osproc, sequtils, strformat, strutils, tempfiles, times,
            unittest]

import vm_harness/layer_gc
import vm_harness/backends/libvirt

const
  # A golden of a plausible shape. Sparse, so the fixture is cheap while the
  # numbers stay realistic.
  GoldenVirtualSize = "16G"
  # The measured live state this fixture reproduces: sixteen stale per-job
  # overlays alongside six live ones. The sizes are the interesting part —
  # apparent and allocated differ by orders of magnitude for a CoW overlay,
  # and a sweep that reported only one of them would be wrong by that much.
  StaleOverlayCount = 16
  LiveOverlayCount = 6
  StaleApparentBytesEach = 2_700_000_000'i64     ## ~2.51 GiB apparent each
  StaleAgeDays = 56
  NowUnix = 1_704_067_200'i64                    ## 2024-01-01T00:00:00Z

proc qemuImg(): string =
  let found = findExe("qemu-img")
  doAssert found.len > 0,
    "qemu-img is a hard prerequisite of t_layer_gc: the fixture must build " &
    "REAL qcow2 backing chains, and a synthesised header would only prove " &
    "that the parser reads what this test wrote."
  found

proc run(args: seq[string]) =
  let (output, code) = execCmdEx(quoteShellCommand(args))
  doAssert code == 0, "command failed: " & args.join(" ") & "\n" & output

proc makeGolden(path: string) =
  run(@[qemuImg(), "create", "-f", "qcow2", path, GoldenVirtualSize])

proc makeOverlay(path, backing: string) =
  run(@[qemuImg(), "create", "-f", "qcow2", "-b", backing, "-F", "qcow2",
        path])

proc growSparse(path: string; apparentBytes: int64) =
  ## Extend a file's APPARENT size without allocating blocks, so the fixture
  ## can carry realistic apparent sizes at no disk cost — and so the
  ## apparent/allocated distinction the sweep reports is genuinely present
  ## rather than asserted against two copies of the same number.
  var f: File
  doAssert open(f, path, fmReadWriteExisting)
  defer: close(f)
  setFilePos(f, apparentBytes - 1)
  var zero: byte = 0
  doAssert writeBuffer(f, addr zero, 1) == 1

proc setAgeDays(path: string; days: int) =
  let t = fromUnix(NowUnix - int64(days) * 86_400)
  setLastModificationTime(path, t)

type Fixture = object
  root: string
  pool: string
  golden: string

proc makeFixture(tag: string): Fixture =
  let root = createTempDir("vmh-layer-gc-" & tag & "-", "")
  let pool = root / "pool"
  createDir(pool)
  let golden = root / "golden-base.qcow2"
  makeGolden(golden)
  Fixture(root: root, pool: pool, golden: golden)

proc overlayFor(f: Fixture; name: string): string =
  f.pool / (name & OverlaySuffix)

proc addOverlay(f: Fixture; name: string; backing = "") =
  makeOverlay(f.overlayFor(name), if backing.len > 0: backing else: f.golden)

proc scopeOf(f: Fixture; liveDomains: seq[string] = @[];
             dryRun = false; olderThanSec = 3600): LayerScope =
  LayerScope(
    imagePoolDir: f.pool,
    liveDomains: liveDomains,
    nowUnix: NowUnix,
    olderThanSec: olderThanSec,
    dryRun: dryRun)

suite "layer GC — the in-use guard":

  test "durable receipts protect stopped or undefined instance files":
    let f = makeFixture("durable")
    defer: removeDir(f.root)
    f.addOverlay("retained")
    setAgeDays(f.overlayFor("retained"), StaleAgeDays)
    # Even a damaged receipt must fail closed, not turn data into stale garbage.
    writeFile(f.pool / "instance.json", "interrupted receipt")
    check deleteLayer(f.scopeOf(), f.overlayFor("retained")).outcome == lgoRefused
    check sweepStaleOverlays(f.scopeOf()).removed.len == 0
    check fileExists(f.overlayFor("retained"))

  test "qcow2BackingFile reads a real backing chain, and reports none for a base":
    ## The parser, against files ``qemu-img`` wrote. Everything below depends
    ## on this being right; if it silently returned "" the guard would refuse
    ## nothing and every other case here would still pass.
    let f = makeFixture("parse")
    defer: removeDir(f.root)
    f.addOverlay("job-1")

    check qcow2BackingFile(f.overlayFor("job-1")) == f.golden
    # A golden has NO backing file. This is what keeps `scanOverlays` from
    # ever returning a base image, so a sweep cannot reach one.
    check qcow2BackingFile(f.golden) == ""
    # A non-qcow2 file, and a missing one.
    writeFile(f.root / "notes.txt", "not a disk image\n")
    check qcow2BackingFile(f.root / "notes.txt") == ""
    check qcow2BackingFile(f.root / "absent.qcow2") == ""

  test "t_layer_gc_refuses_in_use_layer":
    ## THE NEGATIVE CONTROL, and both arms are required.
    ##
    ## Arm 1: with a live overlay whose backing file is layer L, a GC run
    ## targeting L refuses, names the referencing overlay, and leaves L on
    ## disk.
    ## Arm 2: with the overlay removed, the SAME run deletes L.
    ##
    ## Arm 1 alone would pass against an unconditional refusal — a guard
    ## that cannot delete is not a guard, it is a broken command.
    let f = makeFixture("guard")
    defer: removeDir(f.root)
    f.addOverlay("win-job-7")
    let scope = f.scopeOf(liveDomains = @["win-job-7"])

    # --- Arm 1: refused, with the referent named, and L untouched.
    let refused = deleteLayer(scope, f.golden)
    checkpoint("refusal message: " & refused.message)
    check refused.outcome == lgoRefused
    check fileExists(f.golden)
    check refused.referents.len >= 1
    check refused.referents.anyIt(it.kind == lrkOverlay and
      it.name == "win-job-7")
    # The domain is named too, so an operator is told what to stop and not
    # merely which file is in the way.
    check refused.referents.anyIt(it.kind == lrkDomain and
      it.name == "win-job-7")
    check "win-job-7" in refused.message
    check f.golden in refused.message
    # "exits non-zero" is part of the contract, so it is asserted rather than
    # left to the CLI. `layerGcExitCode` is the single definition both this
    # gate and `cmdLayer` use, so the two cannot drift.
    check layerGcExitCode(refused.outcome) == 3

    # A plan and a real run must agree; a `--dry-run` that said something
    # different from the run it previews would be worse than no preview.
    check planLayerDeletion(scope, f.golden).outcome == lgoRefused

    # --- Arm 2: remove the overlay, and the same call now deletes L.
    removeFile(f.overlayFor("win-job-7"))
    let allowed = deleteLayer(f.scopeOf(), f.golden)
    checkpoint("second run: " & allowed.message)
    check allowed.outcome == lgoDeleted
    check allowed.referents.len == 0
    check not fileExists(f.golden)
    check layerGcExitCode(allowed.outcome) == 0

  test "the guard sees an overlay whose domain is NOT defined":
    ## A leaked overlay from a crashed job still references the layer.
    ## Liveness of the DOMAIN is not the question the guard asks — the file
    ## is what resolves reads through the backing chain, and deleting the
    ## layer under a leaked overlay corrupts it just as thoroughly.
    let f = makeFixture("orphan-ref")
    defer: removeDir(f.root)
    f.addOverlay("crashed-job")
    let scope = f.scopeOf(liveDomains = @[])      # no domains at all

    let res = deleteLayer(scope, f.golden)
    check res.outcome == lgoRefused
    check res.referents.anyIt(it.kind == lrkOverlay and
      it.name == "crashed-job")
    # ...and NO domain referent, since none is defined. The two are reported
    # separately so the operator can tell "stop the job" from "delete a
    # leaked file".
    check not res.referents.anyIt(it.kind == lrkDomain)
    check fileExists(f.golden)

  test "an unrelated overlay does not protect a layer":
    ## The other direction of the negative control: the guard must key on
    ## the actual backing relationship, not on "the pool is non-empty".
    let f = makeFixture("unrelated")
    defer: removeDir(f.root)
    let otherGolden = f.root / "other-base.qcow2"
    makeGolden(otherGolden)
    makeOverlay(f.overlayFor("other-job"), otherGolden)

    let res = deleteLayer(f.scopeOf(liveDomains = @["other-job"]), f.golden)
    check res.outcome == lgoDeleted
    check not fileExists(f.golden)
    # ...and the other chain is intact.
    check fileExists(otherGolden)
    check qcow2BackingFile(f.overlayFor("other-job")) == otherGolden

  test "a container using the layer's image refuses it":
    let f = makeFixture("container")
    defer: removeDir(f.root)
    var scope = f.scopeOf()
    scope.liveContainers = @["ci-runner-3"]
    scope.containerImages = @[f.golden]

    let res = deleteLayer(scope, f.golden)
    check res.outcome == lgoRefused
    check res.referents.anyIt(it.kind == lrkContainer and
      it.name == "ci-runner-3")
    check fileExists(f.golden)

  test "a snapshot backed by the layer refuses it":
    let f = makeFixture("snapshot")
    defer: removeDir(f.root)
    let snap = f.root / "job.snap.qcow2"
    makeOverlay(snap, f.golden)                   # outside the image pool
    var scope = f.scopeOf()
    scope.snapshotFiles = @[snap]

    let res = deleteLayer(scope, f.golden)
    check res.outcome == lgoRefused
    check res.referents.anyIt(it.kind == lrkSnapshot)
    check fileExists(f.golden)

  test "dryRun never deletes, and a missing layer is not an error":
    let f = makeFixture("dry")
    defer: removeDir(f.root)
    let res = deleteLayer(f.scopeOf(dryRun = true), f.golden)
    check res.outcome == lgoDryRun
    check fileExists(f.golden)

    let absent = deleteLayer(f.scopeOf(), f.root / "never-existed.qcow2")
    check absent.outcome == lgoAbsent

suite "layer GC — the stale-overlay sweep":

  test "t_layer_gc_clears_stale_overlays":
    ## Against a fixture reproducing the measured live state: sixteen stale
    ## per-job overlays alongside six live ones. The sweep must remove
    ## exactly the sixteen and none of the six.
    ##
    ## Sizes are asserted on BOTH apparent and allocated, because a CoW
    ## overlay is sparse: an implementation that summed ``st_size`` and
    ## reported it as reclaimed space would over-report by three orders of
    ## magnitude, and one that summed ``st_blocks`` and called it the
    ## overlay's size would under-report by the same. Neither miscount can
    ## pass both assertions.
    let f = makeFixture("sweep")
    defer: removeDir(f.root)

    var staleNames: seq[string] = @[]
    for i in 0 ..< StaleOverlayCount:
      let name = &"stale-job-{i:02}"
      staleNames.add(name)
      f.addOverlay(name)
      growSparse(f.overlayFor(name), StaleApparentBytesEach)
      setAgeDays(f.overlayFor(name), StaleAgeDays)

    var liveNames: seq[string] = @[]
    for i in 0 ..< LiveOverlayCount:
      let name = &"live-job-{i:02}"
      liveNames.add(name)
      f.addOverlay(name)
      growSparse(f.overlayFor(name), StaleApparentBytesEach)
      # The live ones are just as OLD as the stale ones. That is the point:
      # if the sweep decided on age alone it would take all 22, and if it
      # decided on liveness alone the age guard would be untested. Both
      # conditions have to be right for this to pass.
      setAgeDays(f.overlayFor(name), StaleAgeDays)

    # The fixture is genuinely sparse, or the size assertions below say
    # nothing. Asserted rather than assumed.
    let before = scanOverlays(f.pool)
    check before.len == StaleOverlayCount + LiveOverlayCount
    for entry in before:
      check entry.apparentBytes >= StaleApparentBytesEach
      check entry.allocatedBytes < entry.apparentBytes div 100
      check entry.backingFile == f.golden

    let report = sweepStaleOverlays(f.scopeOf(liveDomains = liveNames))
    checkpoint(&"scanned={report.scanned} removed={report.removed.len} " &
      &"keptLive={report.keptLive.len} keptFresh={report.keptFresh.len} " &
      &"removedApparent={report.removedApparentBytes} " &
      &"removedAllocated={report.removedAllocatedBytes}")

    check report.scanned == StaleOverlayCount + LiveOverlayCount
    check report.removed.len == StaleOverlayCount
    check report.keptLive.len == LiveOverlayCount
    check report.keptFresh.len == 0

    # Exactly the stale set, by name.
    let removedNames = report.removed.mapIt(it.name)
    for name in staleNames:
      check name in removedNames
      check not fileExists(f.overlayFor(name))
    for name in liveNames:
      check name notin removedNames
      check fileExists(f.overlayFor(name))

    # Both size axes.
    check report.removedApparentBytes >=
      StaleApparentBytesEach * StaleOverlayCount
    check report.keptApparentBytes >=
      StaleApparentBytesEach * LiveOverlayCount
    # Allocated is orders of magnitude smaller, and non-zero (the qcow2
    # metadata is real blocks). A sweep that conflated the two axes fails
    # one of these two lines whichever way it conflated them.
    check report.removedAllocatedBytes > 0
    check report.removedAllocatedBytes < report.removedApparentBytes div 100

    # ...and the golden is untouched. `scanOverlays` cannot return it (no
    # backing file), but that is a property worth pinning rather than
    # trusting.
    check fileExists(f.golden)

  test "the age guard keeps a fresh unowned overlay":
    ## A clone that is being provisioned right now exists on disk for a
    ## window before its domain is defined. Without the age guard the sweep
    ## would race provisioning and delete it.
    let f = makeFixture("fresh")
    defer: removeDir(f.root)
    f.addOverlay("just-created")
    setLastModificationTime(f.overlayFor("just-created"),
      fromUnix(NowUnix - 5))
    f.addOverlay("long-abandoned")
    setAgeDays(f.overlayFor("long-abandoned"), 30)

    let report = sweepStaleOverlays(f.scopeOf(olderThanSec = 3600))
    check report.keptFresh.len == 1
    check report.keptFresh[0].name == "just-created"
    check report.removed.len == 1
    check report.removed[0].name == "long-abandoned"
    check fileExists(f.overlayFor("just-created"))
    check not fileExists(f.overlayFor("long-abandoned"))

  test "the sweep never returns or removes a base image":
    ## A golden has no backing file, so it is not an overlay and is
    ## structurally unreachable. This is the assertion that keeps a future
    ## "sweep everything old in the pool" refactor from deleting the one
    ## file the whole pool depends on.
    let f = makeFixture("golden-safety")
    defer: removeDir(f.root)
    let poolGolden = f.pool / "golden-in-pool.qcow2"
    makeGolden(poolGolden)
    setAgeDays(poolGolden, 400)                    # far past any age guard

    let report = sweepStaleOverlays(f.scopeOf())
    check report.scanned == 0
    check report.removed.len == 0
    check fileExists(poolGolden)

  test "dryRun reports the same plan and removes nothing":
    let f = makeFixture("sweep-dry")
    defer: removeDir(f.root)
    for i in 0 ..< 3:
      let name = &"stale-{i}"
      f.addOverlay(name)
      setAgeDays(f.overlayFor(name), 10)

    let planned = sweepStaleOverlays(f.scopeOf(dryRun = true))
    check planned.removed.len == 3
    for i in 0 ..< 3:
      check fileExists(f.overlayFor(&"stale-{i}"))

    let done = sweepStaleOverlays(f.scopeOf())
    check done.removed.mapIt(it.name) == planned.removed.mapIt(it.name)
    for i in 0 ..< 3:
      check not fileExists(f.overlayFor(&"stale-{i}"))

suite "layer GC — domain enumeration must fail closed":
  ## The sweep's PRIMARY liveness condition is "is this overlay's instance a
  ## defined domain?". Everything else in this file supplies that set as data,
  ## which is the module's designed seam — but `vm-harness layer` has to get it
  ## from the host, and how it behaves when it CANNOT is a safety property of
  ## the same weight as the guard itself.
  ##
  ## No hypervisor is touched here either. The seam under test is the
  ## `virsh` INVOCATION, so a fake `virsh` — a real executable, driven as a
  ## real subprocess — exercises the real code path. The three failures that
  ## matter in production are all a non-zero exit (libvirtd down, no
  ## permission on `qemu:///system`, wrong URI) or an absent binary, and a
  ## script that exits 1 reproduces the first class exactly.

  proc fakeVirsh(dir, name, body: string): string =
    let path = dir / name
    writeFile(path, "#!/bin/sh\n" & body & "\n")
    inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})
    path

  test "a virsh that cannot reach libvirtd is a REFUSAL, not an empty list":
    ## The defect this pins: `listAllDomainNames` documents "returns an empty
    ## seq on error", and an empty domain list is precisely the reading under
    ## which `sweep-overlays` deletes every overlay past the age guard —
    ## including the ones live domains are running on. A caller that deletes
    ## must be able to tell "I could not get the list" from "the list is
    ## empty"; these two assertions are that difference.
    let dir = createTempDir("vmh-virsh-fail-", "")
    defer: removeDir(dir)
    let virsh = fakeVirsh(dir, "virsh",
      "echo 'error: failed to connect to the hypervisor' >&2; exit 1")
    let b = newLibvirtBackend(virshCmd = virsh)

    let checked = b.tryListAllDomainNames()
    check not checked.ok
    check checked.names.len == 0
    check "exited 1" in checked.message

    # ...and the legacy entry point still reports the same failure as an
    # EMPTY LIST, which is why anything that deletes must not use it. Pinned
    # so the two contracts cannot silently converge and hide the distinction.
    check b.listAllDomainNames().len == 0

  test "an absent virsh binary is a REFUSAL too":
    ## The other failure shape: `startProcess` raises rather than exiting
    ## non-zero. Both have to end in the same place or the guard is closed
    ## against one of them and open against the other.
    let b = newLibvirtBackend(
      virshCmd = "vm-harness-no-such-virsh-binary-ever")
    let checked = b.tryListAllDomainNames()
    check not checked.ok
    check checked.names.len == 0
    check checked.message.len > 0

  test "a working virsh yields the domain names":
    ## The positive control. Without it, an implementation that refused
    ## unconditionally would pass both cases above and never enumerate
    ## anything — the `deleteLayer` "arm 2" mistake, one layer up.
    let dir = createTempDir("vmh-virsh-ok-", "")
    defer: removeDir(dir)
    let virsh = fakeVirsh(dir, "virsh",
      "printf 'win-job-7\\n\\nlive-job-00\\n'")
    let b = newLibvirtBackend(virshCmd = virsh)

    let checked = b.tryListAllDomainNames()
    check checked.ok
    check checked.message.len == 0
    # Blank lines are dropped; the names survive in order.
    check checked.names == @["win-job-7", "live-job-00"]
