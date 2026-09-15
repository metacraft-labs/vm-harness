## Runner-Fleet-M3-ARM-Wave MA7 (hygiene half) gate:
## `t_m3_tart_orphan_dirs_reclaimed`.
##
## WHAT IS UNDER TEST
##
##   `pruneTartVmDirs` (src/vm_harness/prune.nim) — the ONLY code path that
##   can reclaim a Tart VM directory carrying no `disk.img`.
##
##   The leak it closes, measured on m3 2026-09-15: 600 `repro-vm-tart-*`
##   directories under /private/var/lib/vm-harness/tart/vms holding only
##   `config.json` + `nvram.bin`, 14.6 GiB in total, growing ~40/day. Tart
##   computes `tart list`'s Disk/SizeOnDisk columns from `disk.img` and omits
##   a VM that has none, so `tart list` named 4 of those 604 directories and
##   `tart delete` could not address the other 600 — which put them out of
##   reach of BOTH existing reapers (`pruneTartClones` here, and the
##   session-start sweep in `TartBackend.provisionBaseline`), since both
##   enumerate through the Tart CLI.
##
##   THE WHOLE RISK IS THE CONVERSE. "Has no disk.img" is also briefly true of
##   a VM being cloned RIGHT NOW, and on m3 that means a live CI job. So this
##   file does not mostly test that orphans are found; it tests that EACH of
##   the four guards INDEPENDENTLY spares a live VM, by standing up four
##   directories that each fail exactly one guard and asserting all four
##   survive a sweep that removes the genuine orphan sitting beside them.
##
##   One guard deserves its own note. The creator PID embedded in the
##   directory name is a WEAK liveness signal rather than a wrong one. On m3
##   it is the supervising `vm-harness run` process, which stays up for the
##   whole job and is the parent of the `tart run` hosting the guest, so for a
##   running ephemeral it is normally ALIVE and spares the directory
##   correctly — measured 2026-09-15, all three running Linux VMs had LIVE
##   creator PIDs, and a PID-only reap proposed removing none of them. What
##   the PID cannot see is a supervisor that was SIGKILLed while the `tart
##   run` it parented kept the guest going. That is why the PID is only ever
##   allowed to SPARE a directory and never to condemn one, and why `tart
##   list` membership has to hold independently of it.
##
##   AND DO NOT PROBE LIVENESS WITH `ps` HERE OR IN ANY HOST SCRIPT. On macOS
##   26 (m3 runs 26.5.1) `ps -p <pid>` prints `ps: time: requires entitlement`
##   and exits 1 for its default column set even for a live process, so the
##   usual `ps -p $pid >/dev/null 2>&1` idiom reports every pid dead on this
##   host. `ps -p $pid -o pid=` exits 0. The production code uses `kill(pid,
##   0)` (`pidAlive`), which is unaffected — this test's `getCurrentProcessId`
##   fixture exercises that path.
##
## JUSTIFIED FAKES (workspace mock policy)
##
##   One: a ~15-line `tart` stand-in shell script whose `list` output is read
##   from a state file, so the test can express "Tart can see this VM" and
##   "`tart list` is broken" without a Tart install, a macOS host or real VMs.
##   Everything else is real: real directories, real files, real `disk.img`
##   contents, real mtimes, the real `pidAlive` against this test's own PID,
##   and the real `removeDir`. The code under test is never replaced.

import std/[json, options, os, posix, strutils, tempfiles, times, unittest]
import vm_harness/cli
import vm_harness/prune
import vm_harness/backends/tart

const
  Prefix = "repro-vm-tart-macos-garm"
  DeadPid = 2147480000          # far above any live PID on the host
  # 2023-11-14 — well past any age floor these tests use.
  OldEpochMs = 1700000000000
  MacosNvramBytes = 33 * 1024 * 1024  ## what an m3 macOS orphan actually costs

proc orphanName(stem: string, epochMs: int64 = OldEpochMs,
                pid: int = DeadPid): string =
  Prefix & "-" & stem & "-" & $epochMs & "-" & $pid

proc mkVmDir(vmsDir, name: string, withDisk = false,
             nvramBytes = 131072): string =
  ## A faithful fixture of what Tart actually leaves behind: `config.json`
  ## plus an `nvram.bin` of the real size, and `disk.img` only when asked.
  result = vmsDir / name
  createDir(result)
  writeFile(result / TartVmConfigName, """{"os":"darwin"}""")
  writeFile(result / "nvram.bin", newString(nvramBytes))
  if withDisk:
    writeFile(result / TartVmDiskName, "disk-bytes")

proc backdate(path: string) =
  ## Push every mtime under `path` (and the directory itself) into the past,
  ## so the age floor cannot spare it. Children first: writing a child bumps
  ## the parent's mtime.
  let t = fromUnix(1)
  for kind, p in walkDir(path):
    setLastModificationTime(p, t)
  setLastModificationTime(path, t)

proc writeFakeTart(dir, stateFile: string): string =
  ## `tart list` renders one `local` row per line of a state file, each line
  ## being `<name> [<state>]` (state defaults to `stopped`). The columns match
  ## real `tart list` output, State last. When the state file does NOT exist
  ## the fake exits 1 — the "tart cannot be asked" shape.
  result = dir / "fake-tart.sh"
  writeFile(result, """#!/bin/sh
state="$FAKE_TART_STATE"
case "$1" in
  list)
    if [ ! -f "$state" ]; then
      echo "tart: could not read VM storage" >&2
      exit 1
    fi
    echo "Source Name Disk Size SizeOnDisk State"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$(echo "$line" | awk '{print $1}')
      s=$(echo "$line" | awk '{print $2}')
      [ -n "$s" ] || s=stopped
      echo "local $n 50 33 33 $s"
    done < "$state"
    ;;
  stop) : ;;
  delete) : ;;
  *) : ;;
esac
""")
  inclFilePermissions(result, {fpUserExec})

template withCapturedStdout(path: string, body: untyped): untyped =
  ## Run `body` with this process's real stdout redirected to `path`, so the
  ## CLI's own emission is asserted rather than a re-implementation of it.
  ## The fd is restored whatever happens.
  let savedFd = dup(stdout.getFileHandle())
  doAssert savedFd >= 0
  doAssert reopen(stdout, path, fmWrite)
  let captured =
    try:
      body
    finally:
      stdout.flushFile()
      discard dup2(savedFd, stdout.getFileHandle())
      discard close(savedFd)
  captured

template withFakeTart(root, stateFile: string, body: untyped) =
  let fakeTart = writeFakeTart(root, stateFile)
  putEnv("VMH_TART_CMD", fakeTart)
  putEnv("FAKE_TART_STATE", stateFile)
  try:
    body
  finally:
    delEnv("VMH_TART_CMD")
    delEnv("FAKE_TART_STATE")

suite "t_m3_tart_orphan_dirs_reclaimed: the four guards each spare a live VM":

  test "a genuine orphan is reclaimed while each guard's VM survives":
    let root = createTempDir("vmh-ma7-guards-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"

    # THE ORPHAN: fails every guard. This is the m3 population.
    let orphan = mkVmDir(vmsDir, orphanName("orphan"))
    backdate(orphan)

    # GUARD 1 — `tart list` names it. The fixture is DELIBERATELY harsher than
    # the real host: it has NO disk.img, an ancient name and ancient mtimes,
    # so guards 2, 3 and 4 all fail and only guard 1 can be what spares it.
    # On m3 a running ephemeral is spared by guards 1, 2 AND 3 at once (it is
    # listed, it has a disk.img, and its creator PID — the supervising
    # `vm-harness run` — is alive), which is precisely why the hermetic
    # fixture has to strip the other three away: otherwise a regression that
    # dropped guard 1 entirely would still pass.
    let listedByTart = mkVmDir(vmsDir, orphanName("listed"))
    backdate(listedByTart)
    # `running`, the state m3's live ephemerals report.
    writeFile(stateFile, extractFilename(listedByTart) & " running\n")

    # GUARD 2 — it still holds a guest disk, and is absent from `tart list`.
    let hasDisk = mkVmDir(vmsDir, orphanName("hasdisk"), withDisk = true)
    backdate(hasDisk)

    # GUARD 3 — the creator PID in the name is THIS process, which is alive.
    let ownerAlive = mkVmDir(
      vmsDir, orphanName("owner", pid = getCurrentProcessId()))
    backdate(ownerAlive)

    # GUARD 4 — inside the age floor. This is the "being cloned right now"
    # shape: an old-looking NAME but fresh contents, so the guard has to be
    # reading the youngest evidence, not the name alone.
    let fresh = mkVmDir(vmsDir, orphanName("fresh"))

    # Out of project scope entirely: never even inspected.
    let outOfScope = mkVmDir(vmsDir, "ah-linux-builder")
    backdate(outOfScope)

    withFakeTart(root, stateFile):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, backend: "tart"))

      check not rep.tartVmDirSweepAborted

      # The orphan is gone, and its bytes are counted.
      check orphan in rep.removedTartVmDirs
      check not dirExists(orphan)

      # Each guard spared its own VM, and said WHICH guard did it, so a
      # regression names the guard that stopped being consulted.
      check listedByTart in rep.tartVmDirsListedByTart
      check dirExists(listedByTart)
      check hasDisk in rep.tartVmDirsWithDisk
      check dirExists(hasDisk)
      check ownerAlive in rep.tartVmDirsOwnerAlive
      check dirExists(ownerAlive)
      check fresh in rep.freshTartVmDirs
      check dirExists(fresh)

      # No spared directory is ever also reported as removed.
      for spared in [listedByTart, hasDisk, ownerAlive, fresh, outOfScope]:
        check spared notin rep.removedTartVmDirs

      # Out-of-scope names are not inspected at all.
      check dirExists(outOfScope)
      check outOfScope notin rep.tartVmDirsListedByTart
      check outOfScope notin rep.tartVmDirsWithDisk

  test "a VM being cloned right now survives, name epoch notwithstanding":
    # The `:risk2:` case in its purest form: the directory looks ancient by
    # name (a recycled stem, a clock skew, a re-used id) but something wrote
    # into it a moment ago. The age floor must read the YOUNGEST evidence.
    let root = createTempDir("vmh-ma7-creating-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")

    let creating = mkVmDir(vmsDir, orphanName("creating"))
    backdate(creating)
    # ... and now the clone writes its config, as it would mid-creation.
    writeFile(creating / TartVmConfigName, """{"os":"darwin","fresh":true}""")

    withFakeTart(root, stateFile):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, backend: "tart"))
      check creating in rep.freshTartVmDirs
      check dirExists(creating)
      check rep.removedTartVmDirs.len == 0

suite "t_m3_tart_orphan_dirs_reclaimed: an unreadable listing aborts the sweep":

  test "a failing `tart list` removes NOTHING and says so":
    # An unreadable listing reads as 'nothing is referenced', which is exactly
    # the state in which every live VM looks like garbage. The fake exits 1
    # when its state file is absent.
    let root = createTempDir("vmh-ma7-abort-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let missingState = root / "does-not-exist.txt"

    let orphan = mkVmDir(vmsDir, orphanName("orphan"))
    backdate(orphan)

    withFakeTart(root, missingState):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, backend: "tart"))
      check rep.tartVmDirSweepAborted
      check "tart list" in rep.tartVmDirSweepAbortReason
      check vmsDir in rep.tartVmDirSweepAbortReason
      check rep.removedTartVmDirs.len == 0
      check dirExists(orphan)

  test "`tart list` succeeding with no local VMs is NOT an abort":
    # The converse of the above, so the abort cannot pass vacuously: an EMPTY
    # listing is a real answer and the sweep must proceed on it.
    let root = createTempDir("vmh-ma7-empty-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")

    let orphan = mkVmDir(vmsDir, orphanName("orphan"))
    backdate(orphan)

    withFakeTart(root, stateFile):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, backend: "tart"))
      check not rep.tartVmDirSweepAborted
      check orphan in rep.removedTartVmDirs
      check not dirExists(orphan)

  test "an unscoped prune refuses to sweep any VM directory":
    let root = createTempDir("vmh-ma7-unscoped-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")
    let orphan = mkVmDir(vmsDir, orphanName("orphan"))
    backdate(orphan)

    withFakeTart(root, stateFile):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: "", tartVmsDir: vmsDir,
        olderThanSec: 3600, backend: "tart"))
      check rep.removedTartVmDirs.len == 0
      check dirExists(orphan)

suite "t_m3_tart_orphan_dirs_reclaimed: dry-run, accounting, and reporting":

  test "dry-run names the reclaimable bytes and deletes nothing":
    let root = createTempDir("vmh-ma7-dry-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")

    # Two macOS-shaped orphans at the size m3's actually are.
    var orphans: seq[string] = @[]
    for i in 0 ..< 2:
      let d = mkVmDir(vmsDir, orphanName("m" & $i, epochMs = OldEpochMs + i),
                      nvramBytes = MacosNvramBytes)
      backdate(d)
      orphans.add(d)

    withFakeTart(root, stateFile):
      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, dryRun: true, backend: "tart"))
      for d in orphans:
        check d in rep.removedTartVmDirs
        check dirExists(d)          # dry-run: still there
      # The accounting is what tells an operator whether a sweep is worth
      # scheduling, so it must be real bytes, not a directory count.
      check rep.bytesReclaimed >= int64(2 * MacosNvramBytes)

  test "the age floor is honoured and 0 disables it":
    let root = createTempDir("vmh-ma7-age-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")
    let justMade = mkVmDir(vmsDir, orphanName("justmade",
      epochMs = int64(epochTime() * 1000)))

    withFakeTart(root, stateFile):
      let guarded = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 3600, dryRun: true, backend: "tart"))
      check justMade in guarded.freshTartVmDirs
      check justMade notin guarded.removedTartVmDirs

      let unguarded = runPrune(PruneScope(
        ephemeralPrefix: Prefix, tartVmsDir: vmsDir,
        olderThanSec: 0, dryRun: true, backend: "tart"))
      check justMade in unguarded.removedTartVmDirs

suite "t_m3_tart_orphan_dirs_reclaimed: run state is the trustworthy signal":

  test "`tart list` run state is parsed off the last column, per local row":
    let root = createTempDir("vmh-ma7-state-", "")
    defer: removeDir(root)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "vm-running running\nvm-stopped stopped\n")
    withFakeTart(root, stateFile):
      let tb = newTartBackend(tartCmd = getEnv("VMH_TART_CMD"))
      let rows = tb.tryListTartVmsDetailed()
      check rows.isSome
      check rows.get().len == 2
      check rows.get()[0].name == "vm-running"
      check rows.get()[0].state == "running"
      check rows.get()[1].state == "stopped"
      # The name-only view keeps working for the callers that use it.
      check tb.tryListTartVms().get() == @["vm-running", "vm-stopped"]

  test "an UNKNOWN run state reads as running — reapers must fail toward sparing":
    # If a Tart release renames, reorders or drops the State column, the
    # parse lands on something that is not a known state. That must spare
    # the VM, not condemn it: on m3 the alternative is stopping a guest that
    # is running a CI job.
    check TartVmListing(name: "v", state: "running").isRunning
    check TartVmListing(name: "v", state: "").isRunning
    check TartVmListing(name: "v", state: "v").isRunning
    check TartVmListing(name: "v", state: "some-future-state").isRunning
    # ... and the two states that genuinely mean "not executing" do not.
    check not TartVmListing(name: "v", state: "stopped").isRunning
    check not TartVmListing(name: "v", state: "suspended").isRunning

suite "t_m3_tart_orphan_dirs_reclaimed: the CLI surface a scheduled sweeper uses":

  test "--tart-vms-dir + --dry-run --log-format json reports the new fields":
    # A host sweeper is declared in nix and never watched, so its output has
    # to be machine-readable. This asserts the exact contract that gate
    # `t_m3_host_hygiene_is_declared` (metacraft-labs/infra) probes for.
    let root = createTempDir("vmh-ma7-cli-", "")
    defer: removeDir(root)
    let vmsDir = root / "vms"
    createDir(vmsDir)
    let stateFile = root / "tart-vms.txt"
    writeFile(stateFile, "")
    let orphan = mkVmDir(vmsDir, orphanName("orphan"),
                         nvramBytes = MacosNvramBytes)
    backdate(orphan)

    let argv = @["prune",
      "--ephemeral-prefix", Prefix,
      "--backend", "tart",
      "--tart-vms-dir", vmsDir,
      "--older-than", "3600",
      "--dry-run", "--log-format", "json"]

    # The flag really reaches the scope object, not just the option struct.
    check parseCliOpts(argv).tartVmsDir == vmsDir

    let capture = root / "prune.json"
    var code = -1
    withFakeTart(root, stateFile):
      code = withCapturedStdout(capture):
        runCli(argv)
    check code == 0

    let lines = readFile(capture).strip().splitLines()
    let j = parseJson(lines[^1])
    check j["removedTartVmDirs"].getElems().len == 1
    check j["removedTartVmDirs"][0].getStr() == orphan
    check j["tartVmDirSweepAborted"].getBool() == false
    check j["bytesReclaimed"].getBiggestInt() >= int64(MacosNvramBytes)
    # Still there: --dry-run.
    check dirExists(orphan)

  test "tartVmsDir resolves from TART_HOME, then VM_HARNESS_TART_STATE_DIR":
    # The precedence a scheduled sweeper falls back on when it is not given
    # --tart-vms-dir. Asserted because m3's launchd daemons set BOTH.
    let savedTartHome = getEnv("TART_HOME")
    let savedVmhState = getEnv("VM_HARNESS_TART_STATE_DIR")
    defer:
      if savedTartHome.len > 0: putEnv("TART_HOME", savedTartHome)
      else: delEnv("TART_HOME")
      if savedVmhState.len > 0: putEnv("VM_HARNESS_TART_STATE_DIR", savedVmhState)
      else: delEnv("VM_HARNESS_TART_STATE_DIR")

    putEnv("TART_HOME", "/tmp/ma7-tart-home")
    putEnv("VM_HARNESS_TART_STATE_DIR", "/tmp/ma7-vmh-state")
    check tartVmsDir() == "/tmp/ma7-tart-home/vms"

    delEnv("TART_HOME")
    check tartVmsDir() == "/tmp/ma7-vmh-state/vms"

    delEnv("VM_HARNESS_TART_STATE_DIR")
    check tartVmsDir() == getHomeDir() / ".tart" / "vms"
