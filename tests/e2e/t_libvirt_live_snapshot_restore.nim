## t_libvirt_live_snapshot_restore (campaign WR0 gate).
##
## The gate that decides whether libvirt can host a WARM pool: does a
## running-state snapshot RESUME on restore, instead of booting?
##
## No mocks — a real libvirt domain, a real guest, real SSH. What it
## asserts, in one run on one host:
##
##   (a) RESUME, not boot. Take a LIVE snapshot of a running guest, mutate
##       it (delete a marker file, start a process), restore, and check
##       that the marker is back, the post-snapshot process is gone, and —
##       the load-bearing one — the guest's boot id is UNCHANGED. A boot id
##       survives only if the kernel was never re-initialised, so an equal
##       boot id is direct evidence the guest resumed from captured RAM.
##   (b) NON-VACUITY. The same domain restored from a COLD (disk-only)
##       snapshot comes back with a DIFFERENT boot id, i.e. it booted. If
##       (a) passed and (b) did not, the test would be asserting nothing:
##       both paths would be doing the same thing.
##   (c) COST. Interleaved reps of cold-boot-to-ready and
##       restore-to-ready, reported as p50s and a ratio. The absolutes are
##       reported separately from the ratio on purpose: an unrelated host
##       change (e.g. a CPU-weight deploy) moves the absolutes but not the
##       ratio, and the ratio is the claim.
##
## THRESHOLDS, and where they come from. `p50(restore) <= 10 s` is the
## pre-existing libvirt per-revert budget in `docs/design.md` §3.4. The
## `>= 4x faster than cold boot` ratio is DERIVED from Hyper-V's measured
## 36 s boot / 7.2 s restore+resume on the same Windows 11 golden
## (`docs/per-backend-notes/hyperv-snapshot-benchmarks.md`), discounted
## from 5.0x to 4x to absorb qcow2-vs-VHDX and host differences. Hyper-V is
## the ANALOGY that motivates this milestone, not a measurement of libvirt;
## this test is what turns it into one.
##
## PREREQUISITES — the test skips loudly, never silently, when any is
## missing. It needs a guest, and it deliberately does not create one:
## making a suitable throwaway is an operator act on a shared host.
##
##   VMH_LIBVIRT_WARM_DOMAIN   name of a THROWAWAY libvirt domain, already
##                             defined, whose guest is Linux with SSH
##                             reachable on the libvirt network. Its state
##                             is destroyed by this test.
##   VMH_LIBVIRT_WARM_SSH_USER      guest login (default: root)
##   VMH_LIBVIRT_WARM_SSH_KEY       private key path, or
##   VMH_LIBVIRT_WARM_SSH_PASSWORD  password (needs sshpass)
##   VMH_LIBVIRT_WARM_REPS          timing reps per arm (default 3; the
##                                  campaign's gate wants 10)
##   LIBVIRT_DEFAULT_URI            e.g. qemu:///session
##
## SAFETY. The domain name is checked against the production fleet's
## prefixes and the test ABORTS (does not skip) if it matches — this test
## destroys guest state and restarts domains, and `garm-*` / `win-ci-*` on
## high-mem-server are live CI runners.
##
## Run:
##   export LIBVIRT_DEFAULT_URI=qemu:///session
##   export VMH_LIBVIRT_WARM_DOMAIN=vmh-wr0-warm-scratch
##   export VMH_LIBVIRT_WARM_SSH_USER=root VMH_LIBVIRT_WARM_SSH_KEY=~/.ssh/id_ed25519
##   nim r --hints:off tests/e2e/t_libvirt_live_snapshot_restore.nim

import std/[algorithm, os, strutils, tables, times, unittest]
import vm_harness

when not defined(linux):
  echo "[skip] t_libvirt_live_snapshot_restore: Linux host required"
  quit(0)

let domName = getEnv("VMH_LIBVIRT_WARM_DOMAIN")
if domName.len == 0:
  echo "[skip] t_libvirt_live_snapshot_restore: VMH_LIBVIRT_WARM_DOMAIN not " &
       "set. This gate needs a RUNNING, SSH-reachable Linux throwaway " &
       "domain; it does not create one, because provisioning a guest on a " &
       "shared runner host is an operator act. See the header for the full " &
       "variable list and " &
       "docs/per-backend-notes/libvirt-snapshot-benchmarks.md for the " &
       "maintenance-window procedure."
  quit(0)

const ProductionPrefixes = ["garm-", "win-ci-", "l3prod-"]
for p in ProductionPrefixes:
  if domName.startsWith(p):
    echo "[FAIL] t_libvirt_live_snapshot_restore: refusing to run against '" &
         domName & "'. That prefix belongs to the production runner fleet, " &
         "and this gate destroys guest state and restarts the domain. Point " &
         "VMH_LIBVIRT_WARM_DOMAIN at a throwaway."
    quit(1)

let sshUser = (let u = getEnv("VMH_LIBVIRT_WARM_SSH_USER"); if u.len > 0: u else: "root")
let sshKey = getEnv("VMH_LIBVIRT_WARM_SSH_KEY")
let sshPassword = getEnv("VMH_LIBVIRT_WARM_SSH_PASSWORD")
if sshKey.len == 0 and sshPassword.len == 0:
  echo "[skip] t_libvirt_live_snapshot_restore: neither " &
       "VMH_LIBVIRT_WARM_SSH_KEY nor VMH_LIBVIRT_WARM_SSH_PASSWORD is set; " &
       "the gate has no way into the guest."
  quit(0)

let reps = (let r = getEnv("VMH_LIBVIRT_WARM_REPS"); if r.len > 0: parseInt(r) else: 3)

let b = newLibvirtBackend(sshUser = sshUser,
                          sshPassword = sshPassword,
                          sshKeyPath = sshKey,
                          sshGuestOs = goLinux)

if not b.probeAvailability():
  echo "[skip] t_libvirt_live_snapshot_restore: libvirt not reachable at " &
       b.libvirtUri
  quit(0)

if not b.domainExists(domName):
  echo "[skip] t_libvirt_live_snapshot_restore: domain '" & domName &
       "' is not defined on " & b.libvirtUri
  quit(0)

const
  WarmSnap = "wr0-warm"
  ColdSnap = "wr0-cold"
  MarkerPath = "/var/tmp/wr0-marker"
  MarkerText = "WR0-MARKER"

var vm: VmHandle = nil
let noEnv = initTable[string, string]()

proc guest(cmd: string): string =
  ## Run a shell line in the guest, return trimmed stdout.
  let r = b.execInGuest(vm, noEnv, @["sh", "-c", cmd], timeoutSec = 60)
  r.stdout.strip()

proc bootId(): string = guest("cat /proc/sys/kernel/random/boot_id")

proc bringUp(timeoutSec: int = 300) =
  vm = b.revertToBaseline(domName)
  b.startAndAwaitReady(vm, timeoutSec = timeoutSec)

proc msSince(t: float): int = int((epochTime() - t) * 1000.0)

proc p50(xs: seq[int]): int =
  if xs.len == 0: return 0
  var s = xs
  s.sort()
  if s.len mod 2 == 1: s[s.len div 2]
  else: (s[s.len div 2 - 1] + s[s.len div 2]) div 2

proc dropSnapshots() =
  for s in [WarmSnap, ColdSnap]:
    try: b.removeSnapshot(domName, s)
    except CatchableError: discard

suite "t_libvirt_live_snapshot_restore":

  test "the guest comes up and is reachable":
    dropSnapshots()          # residue from an interrupted prior run
    bringUp()
    check bootId().len > 0

  test "a LIVE snapshot restores by RESUMING, not booting":
    let idBefore = bootId()
    discard guest("printf '" & MarkerText & "' > " & MarkerPath)
    check guest("cat " & MarkerPath) == MarkerText

    check b.snapshotRunning(domName, WarmSnap) == WarmSnap
    check WarmSnap in b.listSnapshots(domName)

    # Mutate: remove the marker and start a process that did NOT exist when
    # the snapshot was taken.
    discard guest("rm -f " & MarkerPath)
    discard guest("nohup sleep 9999 >/dev/null 2>&1 & echo started")
    check guest("test -f " & MarkerPath & " && echo yes || echo no") == "no"
    check guest("pgrep -f 'sleep 9999' >/dev/null && echo yes || echo no") ==
      "yes"

    b.restoreSnapshot(domName, WarmSnap)
    b.startAndAwaitReady(vm, timeoutSec = 300)

    # Disk state came back with the snapshot.
    check guest("cat " & MarkerPath) == MarkerText
    # RAM state came back too: the post-snapshot process is gone...
    check guest("pgrep -f 'sleep 9999' >/dev/null && echo yes || echo no") ==
      "no"
    # ...and the kernel was never re-initialised, which is what "resumed"
    # means. This is the assertion the whole milestone turns on.
    check bootId() == idBefore
    check b.domainState(domName) == "running"

  test "NON-VACUITY: a COLD snapshot restore boots instead":
    # Same domain, same restore call, snapshot taken WITHOUT vm state. If
    # this came back with the same boot id, the warm arm above would be
    # proving nothing.
    let idBefore = bootId()
    check b.snapshot(domName, ColdSnap) == ColdSnap
    b.restoreSnapshot(domName, ColdSnap)
    b.startAndAwaitReady(vm, timeoutSec = 300)
    check bootId() != idBefore

  test "restore-to-ready beats cold-boot-to-ready by >= 4x, and meets 10 s":
    # Interleaved so both arms share whatever host load exists.
    var warmMs: seq[int] = @[]
    var coldMs: seq[int] = @[]
    for i in 1 .. reps:
      let w = epochTime()
      b.restoreSnapshot(domName, WarmSnap)
      b.startAndAwaitReady(vm, timeoutSec = 300)
      warmMs.add(msSince(w))

      let c = epochTime()
      b.restoreSnapshot(domName, ColdSnap)
      b.startAndAwaitReady(vm, timeoutSec = 300)
      coldMs.add(msSince(c))

    echo "  warm restore+ready ms: ", warmMs, "  p50=", p50(warmMs)
    echo "  cold restore+boot ms:  ", coldMs, "  p50=", p50(coldMs)
    echo "  ratio (cold/warm): ",
         (if p50(warmMs) > 0: p50(coldMs).float / p50(warmMs).float else: 0.0)
    # Budget: docs/design.md §3.4, "libvirt virsh snapshot-revert <= 10s".
    check p50(warmMs) <= 10_000
    # Ratio: derived from Hyper-V's 36 s / 7.2 s = 5.0x, discounted to 4x.
    check p50(coldMs) >= 4 * p50(warmMs)

  test "teardown removes both snapshots and their RAM images":
    let memPath = b.memoryStatePathFor(domName, WarmSnap)
    dropSnapshots()
    let remaining = b.listSnapshots(domName)
    check WarmSnap notin remaining
    check ColdSnap notin remaining
    check not fileExists(memPath)
