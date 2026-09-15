## Unit tests for ``vm-harness prune``: project-scoped, lock-guarded reclamation
## of leaked ephemeral resources.
##
## Justified fakes: a tiny ``tart`` stand-in script backs the tart-clone
## reaping path so the test can assert delete behavior without a real Tart
## install or macOS VMs. Everything else (qemu instance dirs, temp scratch
## files, the advisory lock) runs against the real filesystem and real
## ``flock``.

import std/[os, strutils, tempfiles, times, unittest]
import vm_harness
import vm_harness/prune

const
  Prefix = "repro-vm-test-garm"
  DeadPid = 2147480000          # far above any live PID on the host
  OldEpochMs = 1700000000000    # 2023-11-14, well past any age guard

proc mkInstance(stateDir, name: string, withLockFile: bool): string =
  let dir = ephemeralDirFor(stateDir, name)
  createDir(dir)
  writeFile(dir / QwaOverlayDiskName, "overlay-bytes")
  if withLockFile:
    writeFile(qwaInstanceLockPath(dir), "")
  dir

suite "prune: qemu-windows-arm instance dirs":
  test "reaps dead+old instances, keeps live and fresh and out-of-scope":
    let root = createTempDir("vmh-prune-qemu-", "")
    defer: removeDir(root)
    let stateDir = root / "state"
    createDir(stateDir / "instances")

    let deadDir = mkInstance(stateDir, Prefix & "-" & $OldEpochMs & "-" & $DeadPid,
                             withLockFile = true)
    let freshDir = mkInstance(stateDir,
                              Prefix & "-" & $(int64(epochTime() * 1000)) & "-" & $DeadPid,
                              withLockFile = false)
    let otherDir = mkInstance(stateDir, "some-other-prefix-" & $OldEpochMs & "-" & $DeadPid,
                              withLockFile = true)

    # A live instance: hold its lock for the duration of the prune.
    let liveName = Prefix & "-" & $OldEpochMs & "-" & $getCurrentProcessId()
    let liveDir = ephemeralDirFor(stateDir, liveName)
    createDir(liveDir)
    let b = newQemuWindowsArmBackend()
    b.acquireInstanceLock(liveName, liveDir)
    defer: b.releaseInstanceLock(liveName)

    let rep = runPrune(PruneScope(
      ephemeralPrefix: Prefix, stateDir: stateDir,
      olderThanSec: 3600, backend: "qemu-windows-arm"))

    check deadDir in rep.removedInstanceDirs
    check not dirExists(deadDir)
    check liveDir in rep.liveInstanceDirs
    check dirExists(liveDir)
    check freshDir in rep.freshInstanceDirs
    check dirExists(freshDir)
    # Out-of-scope prefix is never inspected or removed.
    check dirExists(otherDir)
    check otherDir notin rep.removedInstanceDirs

  test "dry-run reports the dead instance but deletes nothing":
    let root = createTempDir("vmh-prune-dry-", "")
    defer: removeDir(root)
    let stateDir = root / "state"
    createDir(stateDir / "instances")
    let deadDir = mkInstance(stateDir, Prefix & "-" & $OldEpochMs & "-" & $DeadPid,
                             withLockFile = true)

    let rep = runPrune(PruneScope(
      ephemeralPrefix: Prefix, stateDir: stateDir,
      olderThanSec: 3600, dryRun: true, backend: "qemu-windows-arm"))

    check deadDir in rep.removedInstanceDirs
    check dirExists(deadDir)   # dry-run: still there

suite "prune: temp scratch files":
  test "age-sweeps matching tmp files, keeps recent and unrelated ones":
    let savedTmp = getEnv("TMPDIR")
    let sweepDir = createTempDir("vmh-prune-tmp-", "")
    putEnv("TMPDIR", sweepDir)
    defer:
      putEnv("TMPDIR", savedTmp)
      removeDir(sweepDir)
    check getTempDir() == sweepDir or getTempDir() == sweepDir & "/"

    let oldQemuPwd = sweepDir / "vm-harness-qemu-win-arm-pwd-123-456"
    let oldTartPwd = sweepDir / "vm-harness-tart-pwd-1700.0-789"
    let recentPwd = sweepDir / "vm-harness-tart-pwd-9999.0-321"
    let unrelated = sweepDir / "keepme.txt"
    for f in [oldQemuPwd, oldTartPwd, recentPwd, unrelated]:
      writeFile(f, "x")
    # Backdate the two "old" files well past the guard; leave the others fresh.
    setLastModificationTime(oldQemuPwd, fromUnix(1))
    setLastModificationTime(oldTartPwd, fromUnix(1))

    let rep = runPrune(PruneScope(
      ephemeralPrefix: Prefix, olderThanSec: 3600,
      backend: "all", sweepTmp: true))

    check not fileExists(oldQemuPwd)
    check not fileExists(oldTartPwd)
    check fileExists(recentPwd)    # too new to sweep
    check fileExists(unrelated)    # not a vm-harness scratch file
    check oldQemuPwd in rep.removedTmpFiles
    check oldTartPwd in rep.removedTmpFiles

  test "without --sweep-tmp, tmp files are left alone":
    let savedTmp = getEnv("TMPDIR")
    let sweepDir = createTempDir("vmh-prune-notmp-", "")
    putEnv("TMPDIR", sweepDir)
    defer:
      putEnv("TMPDIR", savedTmp)
      removeDir(sweepDir)
    let oldPwd = sweepDir / "vm-harness-tart-pwd-1700.0-789"
    writeFile(oldPwd, "x")
    setLastModificationTime(oldPwd, fromUnix(1))

    let rep = runPrune(PruneScope(
      ephemeralPrefix: Prefix, olderThanSec: 3600, backend: "all"))

    check fileExists(oldPwd)
    check rep.removedTmpFiles.len == 0

proc writeFakeTart(dir, stateFile: string): string =
  ## A minimal ``tart`` that reports/deletes VMs from a state file. Each line
  ## of the state file is ``<name> <state>``, matching the Name and State
  ## columns of real ``tart list`` output — the run state is load-bearing for
  ## the reap decision, so the fixture has to carry it rather than hard-code
  ## one value for every VM.
  let script = dir / "fake-tart.sh"
  writeFile(script, """#!/bin/sh
state="$FAKE_TART_STATE"
case "$1" in
  list)
    echo "Source Name Disk Size SizeOnDisk State"
    if [ -f "$state" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$(echo "$line" | awk '{print $1}')
        s=$(echo "$line" | awk '{print $2}')
        [ -n "$s" ] || s=stopped
        echo "local $n 50 33 33 $s"
      done < "$state"
    fi
    ;;
  stop) : ;;
  delete)
    if [ -f "$state" ]; then
      grep -v "^$2 " "$state" > "$state.tmp" 2>/dev/null || true
      mv "$state.tmp" "$state" 2>/dev/null || true
    fi
    ;;
esac
""")
  inclFilePermissions(script, {fpUserExec})
  script

suite "prune: tart clones":
  test "reaps dead+old clones, keeps live ones, honors scope":
    when defined(posix):
      let root = createTempDir("vmh-prune-tart-", "")
      defer: removeDir(root)
      let stateFile = root / "vms.txt"
      let deadClone = Prefix & "-" & $OldEpochMs & "-" & $DeadPid
      let liveClone = Prefix & "-" & $OldEpochMs & "-" & $getCurrentProcessId()
      let otherClone = "unrelated-vm-" & $OldEpochMs & "-" & $DeadPid
      writeFile(stateFile,
        deadClone & " stopped\n" &
        liveClone & " stopped\n" &
        otherClone & " stopped\n")

      let tart = writeFakeTart(root, stateFile)
      putEnv("VMH_TART_CMD", tart)
      putEnv("FAKE_TART_STATE", stateFile)
      defer:
        delEnv("VMH_TART_CMD")
        delEnv("FAKE_TART_STATE")

      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, olderThanSec: 3600, backend: "tart"))

      check deadClone in rep.removedTartClones
      check liveClone in rep.liveTartClones
      check otherClone notin rep.removedTartClones
      let remaining = readFile(stateFile)
      check deadClone notin remaining        # deleted via fake tart
      check liveClone in remaining           # preserved
      check otherClone in remaining          # out of scope
    else:
      skip()

  test "a RUNNING clone is spared even when its creator PID is dead and old":
    # The case PID + age alone cannot see. On m3 the creator PID in the name
    # is the supervising `vm-harness run`, which normally lives for the whole
    # job — but if it is SIGKILLed, the `tart run` it parented is reparented
    # and the guest keeps serving its job. The name's PID is then dead and the
    # age floor lapses, so only the run state `tart list` reports separates a
    # live VM from residue.
    when defined(posix):
      let root = createTempDir("vmh-prune-tart-running-", "")
      defer: removeDir(root)
      let stateFile = root / "vms.txt"
      let runningClone = Prefix & "-" & $OldEpochMs & "-" & $DeadPid
      let stoppedClone = Prefix & "-" & $(OldEpochMs + 1) & "-" & $DeadPid
      writeFile(stateFile,
        runningClone & " running\n" & stoppedClone & " stopped\n")

      let tart = writeFakeTart(root, stateFile)
      putEnv("VMH_TART_CMD", tart)
      putEnv("FAKE_TART_STATE", stateFile)
      defer:
        delEnv("VMH_TART_CMD")
        delEnv("FAKE_TART_STATE")

      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, olderThanSec: 3600, backend: "tart"))

      check runningClone in rep.liveTartClones
      check runningClone notin rep.removedTartClones
      check runningClone in readFile(stateFile)
      # The converse, so "spare running" cannot pass by sparing everything.
      check stoppedClone in rep.removedTartClones
      check stoppedClone notin readFile(stateFile)
    else:
      skip()

  test "an unreadable `tart list` reaps no clone at all":
    when defined(posix):
      let root = createTempDir("vmh-prune-tart-unreadable-", "")
      defer: removeDir(root)
      let stateFile = root / "vms.txt"
      let clone = Prefix & "-" & $OldEpochMs & "-" & $DeadPid
      writeFile(stateFile, clone & " stopped\n")
      let tart = writeFakeTart(root, stateFile)
      putEnv("VMH_TART_CMD", tart)
      # Point the fake at a state file that does not exist AND make the
      # command itself fail, which is what a missing/broken tart looks like.
      putEnv("FAKE_TART_STATE", root / "missing.txt")
      defer:
        delEnv("VMH_TART_CMD")
        delEnv("FAKE_TART_STATE")
      # A `tart` that is not on the host at all: the strongest form.
      putEnv("VMH_TART_CMD", root / "no-such-tart")

      let rep = runPrune(PruneScope(
        ephemeralPrefix: Prefix, olderThanSec: 3600, backend: "tart"))
      check rep.removedTartClones.len == 0
      check clone in readFile(stateFile)
    else:
      skip()
