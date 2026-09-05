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
##                             defined, whose guest has SSH reachable on the
##                             libvirt network. Its state is destroyed by
##                             this test.
##   VMH_LIBVIRT_WARM_GUEST_OS      `linux` (default) or `windows`
##   VMH_LIBVIRT_WARM_SSH_USER      guest login (default: root)
##   VMH_LIBVIRT_WARM_SSH_KEY       private key path, or
##   VMH_LIBVIRT_WARM_SSH_PASSWORD  password (needs sshpass)
##   VMH_LIBVIRT_WARM_REPS          timing reps per arm (default 3; the
##                                  campaign's gate wants 10)
##   VMH_LIBVIRT_WARM_STATE_DIR     snapshot artifact dir (default: the
##                                  image pool)
##   LIBVIRT_DEFAULT_URI            e.g. qemu:///session
##
## GUEST OS. The resume-not-boot witness is a value that a kernel/OS can
## only carry across a RAM restore and never across a boot:
##
##   * Linux   — `/proc/sys/kernel/random/boot_id`, regenerated per boot.
##   * Windows — `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`,
##     the substitution named in
##     `docs/per-backend-notes/libvirt-snapshot-benchmarks.md`, since the
##     WR0 headline has to be taken on the real Windows golden and Windows
##     has no boot id.
##
## In BOTH cases the witness is corroborated by a process that was started
## AFTER the snapshot and must be absent again after the restore: a boot
## would also clear it, so it is the boot-witness that carries the claim,
## and the process is what rules out "the restore did nothing at all".
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

let guestOsName = (let g = getEnv("VMH_LIBVIRT_WARM_GUEST_OS");
                   if g.len > 0: g.toLowerAscii() else: "linux")
if guestOsName notin ["linux", "windows"]:
  echo "[FAIL] t_libvirt_live_snapshot_restore: VMH_LIBVIRT_WARM_GUEST_OS " &
       "must be 'linux' or 'windows'; got '" & guestOsName & "'."
  quit(1)
let isWindows = guestOsName == "windows"
let stateDir = getEnv("VMH_LIBVIRT_WARM_STATE_DIR")

let b = newLibvirtBackend(snapshotStateDir = stateDir,
                          sshUser = sshUser,
                          sshPassword = sshPassword,
                          sshKeyPath = sshKey,
                          sshGuestOs = (if isWindows: goWindows else: goLinux))

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
  LinuxMarker = "/var/tmp/wr0-marker"
  WindowsMarker = "C:\\wr0-marker.txt"
  MarkerText = "WR0-MARKER"
  ## The sentinel's distinguishing substring. Matched against the process
  ## command line on both guests, so one constant covers both arms.
  SentinelTag = "9999"

var vm: VmHandle = nil
let noEnv = initTable[string, string]()

proc sh(cmd: string): string =
  ## Run a POSIX shell line in a Linux guest, return trimmed stdout.
  let r = b.execInGuest(vm, noEnv, @["sh", "-c", cmd], timeoutSec = 60)
  r.stdout.strip()

proc ps(script: string): string =
  ## Run a PowerShell line in a Windows guest, return trimmed stdout.
  ##
  ## The payload must contain NO double quotes: the Windows guest's OpenSSH
  ## login shell is cmd.exe and ``formatSshCommand`` wraps each argv element
  ## in double quotes, which cmd does not let the payload re-enter. Every
  ## string literal below is therefore single-quoted PowerShell.
  let r = b.execInGuest(vm, noEnv,
                        @["powershell", "-NoProfile", "-NonInteractive",
                          "-Command", script], timeoutSec = 120)
  r.stdout.strip()

proc bootWitness(): string =
  ## The value that survives a RESUME and cannot survive a BOOT. See the
  ## header's "GUEST OS" note for why each is the right witness.
  if isWindows:
    ps("(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')")
  else:
    sh("cat /proc/sys/kernel/random/boot_id")

proc writeMarker() =
  if isWindows:
    discard ps("Set-Content -LiteralPath " & WindowsMarker & " -Value " &
               MarkerText & " -NoNewline")
  else:
    discard sh("printf '" & MarkerText & "' > " & LinuxMarker)

proc readMarker(): string =
  if isWindows:
    ps("if (Test-Path " & WindowsMarker & ") { (Get-Content -Raw " &
       WindowsMarker & ").Trim() }")
  else:
    sh("cat " & LinuxMarker)

proc removeMarker() =
  if isWindows:
    discard ps("Remove-Item -LiteralPath " & WindowsMarker &
               " -Force -ErrorAction SilentlyContinue")
  else:
    discard sh("rm -f " & LinuxMarker)

proc markerPresent(): string =
  if isWindows:
    ps("if (Test-Path " & WindowsMarker & ") { 'yes' } else { 'no' }")
  else:
    sh("test -f " & LinuxMarker & " && echo yes || echo no")

proc startSentinel(): string =
  ## Start a process that did NOT exist when the snapshot was taken, and
  ## return ITS PID.
  ##
  ## The PID is returned — rather than the sentinel being re-found later by
  ## its command line — because a command-line search SELF-MATCHES. The
  ## query carries the pattern it is searching for in its own argv, so it
  ## finds itself and answers "yes" forever, on both guests: on Windows
  ## ``Get-CimInstance Win32_Process`` enumerates the very ``powershell.exe``
  ## running the ``Where-Object`` filter, and on Linux ``pgrep -f 'sleep N'``
  ## matches the ``sh -c`` that invoked it (pgrep excludes only itself, not
  ## its parent). Either way the post-restore assertion would be vacuous —
  ## it could never observe the sentinel's absence.
  ##
  ## Holding the PID on the HOST side dodges that completely: the identity
  ## lives in this process's memory, so it survives the guest being rolled
  ## back and cannot be reconstructed by anything running inside the guest.
  ##
  ## On Windows the process is created through ``Win32_Process.Create``
  ## rather than ``Start-Process``. Windows OpenSSH puts the session's
  ## descendants in a job object and kills the job when the connection
  ## closes, so a ``Start-Process`` child does NOT outlive the exec that
  ## spawned it — it dies before the snapshot is even taken, and the
  ## "sentinel is alive" precondition fails. ``Win32_Process.Create`` is
  ## serviced by the WMI provider host, so the new process is parented
  ## outside the SSH job and survives. (The Linux ``nohup`` + ``&`` has
  ## no equivalent problem.)
  if isWindows:
    ps("$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create " &
       "-Arguments @{ CommandLine = 'powershell -NoProfile -Command " &
       "Start-Sleep -Seconds " & SentinelTag & "' }; $r.ProcessId")
  else:
    sh("nohup sleep " & SentinelTag & " >/dev/null 2>&1 & echo $!")

proc sentinelRunning(pid: string): string =
  ## Is the process this exact PID named still alive? The command line is
  ## re-checked for a process looked up BY PID, which cannot self-match, so
  ## a recycled PID belonging to some unrelated process reads as "no".
  if pid.len == 0: return "no"
  if isWindows:
    ps("$p = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | " &
       "Where-Object { $_.ProcessId -eq " & pid & " }; " &
       "if ($p -and $p.CommandLine -like '*Start-Sleep*') { 'yes' } " &
       "else { 'no' }")
  else:
    sh("grep -qs sleep /proc/" & pid & "/comm && echo yes || echo no")

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
    let w = bootWitness()
    echo "  boot witness (", guestOsName, "): ", w
    check w.len > 0

  test "a LIVE snapshot restores by RESUMING, not booting":
    let idBefore = bootWitness()
    writeMarker()
    check readMarker() == MarkerText

    check b.snapshotRunning(domName, WarmSnap) == WarmSnap
    check WarmSnap in b.listSnapshots(domName)

    # Mutate: remove the marker and start a process that did NOT exist when
    # the snapshot was taken.
    removeMarker()
    let sentinelPid = startSentinel()
    echo "  sentinel pid (started AFTER the snapshot): ", sentinelPid
    check sentinelPid.len > 0
    check markerPresent() == "no"
    check sentinelRunning(sentinelPid) == "yes"

    b.restoreSnapshot(domName, WarmSnap)
    b.startAndAwaitReady(vm, timeoutSec = 300)

    # Disk state came back with the snapshot.
    check readMarker() == MarkerText
    # RAM state came back too: the post-snapshot process is gone...
    check sentinelRunning(sentinelPid) == "no"
    # ...and the OS was never re-initialised, which is what "resumed"
    # means. This is the assertion the whole milestone turns on.
    let idAfter = bootWitness()
    echo "  boot witness before/after warm restore: ", idBefore, " / ", idAfter
    check idAfter == idBefore
    check b.domainState(domName) == "running"

  test "NON-VACUITY: a COLD snapshot restore boots instead":
    # Same domain, same restore call, snapshot taken WITHOUT vm state. If
    # this came back with the same witness, the warm arm above would be
    # proving nothing.
    let idBefore = bootWitness()
    check b.snapshot(domName, ColdSnap) == ColdSnap
    b.restoreSnapshot(domName, ColdSnap)
    b.startAndAwaitReady(vm, timeoutSec = 300)
    let idAfter = bootWitness()
    echo "  boot witness before/after cold restore: ", idBefore, " / ", idAfter
    check idAfter != idBefore

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
