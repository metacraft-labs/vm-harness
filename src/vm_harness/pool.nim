## Pool algorithms: `clone-per-task` and `recycle-from-pool-per-task`.
##
## Two ways to serve a stream of tasks from one host. They are not
## interchangeable and the right one is a property of the BACKEND'S STORAGE,
## not of the workload -- see ``docs/pool-algorithms.md`` for the rule, the
## measurements behind it, and the recorded per-backend selections.
##
## The selection is fixed at development time (``defaultAlgorithmFor``) and
## deliberately not probed at runtime: these costs are stable per backend +
## storage driver, so rediscovering them on every host start is waste, and a
## pool that silently changed algorithm would make latency irreproducible.
##
## Both algorithms present the SAME interface -- ``acquire`` gives you a
## task-ready guest, ``release`` returns it -- so a consumer does not branch
## on which is in use:
##
## ```nim
## var pool = newPool(PoolConfig(backend: b, baseline: "golden", size: 4))
## pool.construct()
## let lease = pool.acquire()
## try:
##   discard b.execInGuest(lease.vm, @["build.sh"])
## finally:
##   pool.release(lease)
## ```
##
## WHERE THE COST SITS, which is the whole point of the recycle variant:
## ``release`` does the resetting, not ``acquire``. A member is restored the
## moment its task finishes, so it is already warm when the next task
## arrives and per-task start latency approaches zero. Putting the reset in
## ``acquire`` would move that cost back onto the critical path and give up
## most of the benefit.

import std/[strformat, strutils, times]
import ./types

type
  PoolAlgorithm* = enum
    paClonePerTask = "clone-per-task"
      ## Every task gets an instance that has never existed before.
      ## Isolation is free: there is no prior state to leak.
    paRecycleFromPool = "recycle-from-pool-per-task"
      ## N long-lived members, each restored to ITS OWN baseline between
      ## tasks. Only the state is ephemeral.

  PoolMember* = ref object
    ## One pool slot. Only meaningful under `paRecycleFromPool`.
    name*: string
      ## The backend-level instance name; stable for the member's lifetime.
    baselineSnapshot*: string
      ## This member's OWN baseline checkpoint.
      ##
      ## Per-member, NOT shared, and that is load-bearing rather than
      ## tidiness. A checkpoint that captures RAM captures the machine name
      ## and DHCP lease with it, so N members restored from ONE shared
      ## checkpoint come up as N guests with identical identities --
      ## measured, see the identity-collision section of
      ## ``docs/per-backend-notes/hyperv-snapshot-benchmarks.md``. The pool
      ## is N distinct baselines, not N copies of one.
    vm*: VmHandle
    inUse*: bool

  PoolLease* = ref object
    ## What a consumer holds between ``acquire`` and ``release``.
    vm*: VmHandle
    member*: PoolMember   ## nil under `paClonePerTask` -- nothing to return

  PoolConfig* = object
    backend*: VmBackend
    baseline*: string
      ## The golden every member/instance derives from.
    algorithm*: PoolAlgorithm
    size*: int
      ## Member count. `paRecycleFromPool` only; ignored when cloning.
    readyTimeoutSec*: int
    memberBaselinePrefix*: string
      ## Prefix for per-member checkpoint names. Defaults to `pool-baseline`.
    createMember*: proc(idx: int): VmHandle {.closure.}
      ## How to bring a NEW pool member into existence. Optional; when nil,
      ## construction falls back to ``backend.revertToBaseline(baseline)``.
      ##
      ## It exists because `revertToBaseline` does not mean the same thing on
      ## every backend, and the difference is fatal here rather than
      ## cosmetic:
      ##
      ##   * libvirt / incus -- CREATE an instance (a fresh qcow2 CoW overlay
      ##     over the golden, or a launched container). Calling it N times
      ##     yields N guests, so the fallback is correct.
      ##   * Hyper-V -- RESTORES a checkpoint on ONE fixed VM (`b.vmName`).
      ##     Calling it N times yields the SAME guest N times, so the
      ##     fallback would build a pool of N members that are all one VM:
      ##     leases would alias, and releasing one would reset another's
      ##     running task. Hyper-V must supply this, creating each member
      ##     with Export-VM / Import-VM.
      ##
      ## ``construct`` verifies distinctness regardless, so a backend that
      ## gets this wrong fails loudly instead of producing a pool that looks
      ## full and silently corrupts tasks.

  Pool* = ref object
    cfg*: PoolConfig
    members*: seq[PoolMember]
    constructed*: bool

  PoolError* = object of CatchableError

const
  DefaultReadyTimeoutSec* = 300
  DefaultMemberBaselinePrefix* = "pool-baseline"

proc defaultAlgorithmFor*(backend: BackendId): PoolAlgorithm =
  ## The development-time selection, from measurement. Changing an entry
  ## here is an architectural decision and wants numbers behind it --
  ## ``tools/bench/clone_per_task_bench.nim`` and
  ## ``tools/bench/snapshot_revert_bench.nim`` produce the comparable pair.
  case backend
  of biHyperv:
    # Measured 2026-08-21 on win-ci-bare-001: clone is a real file copy
    # (Export+Import ~50 s, so clone-per-task 35.9 s is no better than the
    # 36 s cold boot it replaces), while restoring a checkpoint that carries
    # RAM resumes in ~5 s. Not a marginal call.
    paRecycleFromPool
  of biLibvirt:
    # NO LONGER FORCED, but still not measured -- and the honest answer to
    # that pair is "leave it alone".
    #
    # What changed (campaign WR0, 2026-09-05): snapshot / snapshotRunning /
    # restoreSnapshot / listSnapshots / removeSnapshot are implemented, as
    # EXTERNAL virsh snapshots, so `paRecycleFromPool` would now at least
    # RUN here. Two of the properties the algorithm depends on were
    # measured on high-mem-server against real libvirt 11.7 and hold:
    # restoring does not rewrite the saved state (two restores left the
    # frozen disk byte-identical, mtime unchanged -- so "prepare once,
    # restore many" is the cheap direction), and each restore's write is a
    # fresh disposable overlay, not a copy of the guest.
    #
    # What did NOT change: nobody has timed restore-to-ready against
    # boot-to-ready on a libvirt guest. Hyper-V's 36 s -> 7.2 s is an
    # ANALOGY (different hypervisor, VHDX not qcow2), and libvirt's cost
    # profile genuinely differs -- cloning here is already O(1), a qcow2
    # CoW overlay over the golden, so the recycle win is only the skipped
    # BOOT, not an avoided file copy the way it was on Hyper-V.
    #
    # Flipping on an analogy would put every libvirt Pool -- Linux guests
    # included, where a boot costs ~1-2 s and recycling buys nothing --
    # onto a path that has never run against a live guest. So: keep
    # `paClonePerTask`, which cannot be wrong about isolation.
    #
    # WHAT WOULD JUSTIFY THE FLIP, precisely: run
    # `tests/e2e/t_libvirt_live_snapshot_restore.nim` (or the
    # tools/bench pair) on the Windows golden in a maintenance window; flip
    # when restore-to-ready p50 <= 10 s AND >= 4x faster than
    # boot-to-ready in the same run. Procedure and thresholds:
    # `docs/per-backend-notes/libvirt-snapshot-benchmarks.md`.
    paClonePerTask
  of biIncus:
    # UNDECIDED upstream, defaulted conservatively. A container has no boot
    # to skip (~1 s to start), so recycling buys isolation rather than
    # speed; and the default storage pool is the `dir` driver, where
    # snapshot/restore are FULL RECURSIVE COPIES whose cost scales with
    # rootfs size -- plausibly worse than delete-and-relaunch. On ZFS both
    # become metadata-only and the answer may flip. Re-measure when the ZFS
    # driver lands; the bar to beat is delete-and-relaunch, not cold boot.
    paClonePerTask
  else:
    # Anything without measured numbers gets the algorithm that cannot be
    # wrong about isolation, only about speed.
    paClonePerTask

proc newPool*(cfg: PoolConfig): Pool =
  ## Build a pool descriptor. Does no I/O -- call ``construct`` for that.
  var c = cfg
  if c.readyTimeoutSec <= 0: c.readyTimeoutSec = DefaultReadyTimeoutSec
  if c.memberBaselinePrefix.len == 0:
    c.memberBaselinePrefix = DefaultMemberBaselinePrefix
  if c.baseline.len == 0:
    raise newException(PoolError, "PoolConfig.baseline is required")
  if c.backend.isNil:
    raise newException(PoolError, "PoolConfig.backend is required")
  if c.algorithm == paRecycleFromPool and c.size < 1:
    raise newException(PoolError,
      "recycle-from-pool-per-task needs size >= 1 (got " & $c.size & ")")
  Pool(cfg: c, members: @[], constructed: false)

proc memberBaselineName(p: Pool, idx: int): string =
  &"{p.cfg.memberBaselinePrefix}-{idx}"

proc construct*(p: Pool) =
  ## Pay the pool-construction cost.
  ##
  ## `paClonePerTask`: nothing to do; instances are made per task.
  ##
  ## `paRecycleFromPool`: for each member, derive an instance from the
  ## golden, bring it up so it acquires its OWN identity, and checkpoint
  ## that as the member's baseline. This is the expensive part and it is
  ## paid once -- nobody is waiting on it.
  if p.constructed: return
  case p.cfg.algorithm
  of paClonePerTask:
    p.constructed = true
  of paRecycleFromPool:
    for i in 0 ..< p.cfg.size:
      let vm =
        if p.cfg.createMember != nil: p.cfg.createMember(i)
        else: p.cfg.backend.revertToBaseline(p.cfg.baseline)

      # Distinctness is checked, not trusted. A backend whose
      # revertToBaseline RESETS one long-lived VM (Hyper-V) hands back the
      # same guest every time; without this the pool would report N members,
      # hand out N leases that all alias one guest, and releasing one would
      # reset another's running task. Failing here beats corrupting tasks.
      for prior in p.members:
        if prior.name == vm.name:
          raise newException(PoolError,
            "pool member " & $i & " is the SAME instance as an earlier " &
            "member (" & vm.name & "). This backend's revertToBaseline " &
            "resets one long-lived guest rather than creating new ones, so " &
            "it cannot build a pool -- supply PoolConfig.createMember.")

      p.cfg.backend.startAndAwaitReady(vm, timeoutSec = p.cfg.readyTimeoutSec)
      let snapName = p.memberBaselineName(i)
      # snapshotRunning, not snapshot: capturing the RUNNING state is what
      # lets a restore resume instead of boot, and that difference is the
      # entire reason to prefer this algorithm. A backend without it raises
      # here, at construction, rather than silently degrading to a slow
      # cold-boot pool that looks like it is working.
      discard p.cfg.backend.snapshotRunning(vm.name, snapName)
      p.members.add(PoolMember(name: vm.name, baselineSnapshot: snapName,
                               vm: vm, inUse: false))
    p.constructed = true

proc acquire*(p: Pool): PoolLease =
  ## Obtain a task-ready guest.
  if not p.constructed:
    raise newException(PoolError, "pool.construct() has not been called")
  case p.cfg.algorithm
  of paClonePerTask:
    let vm = p.cfg.backend.revertToBaseline(p.cfg.baseline)
    p.cfg.backend.startAndAwaitReady(vm, timeoutSec = p.cfg.readyTimeoutSec)
    PoolLease(vm: vm, member: nil)
  of paRecycleFromPool:
    for m in p.members:
      if not m.inUse:
        m.inUse = true
        # No reset here on purpose -- release() already restored this member
        # when its previous task finished, so it is warm and ready NOW. That
        # is what keeps the recycle cost off the critical path.
        return PoolLease(vm: m.vm, member: m)
    raise newException(PoolError,
      "no free pool member (size=" & $p.cfg.size & ", all in use)")

proc release*(p: Pool, lease: PoolLease) =
  ## Return a guest.
  ##
  ## `paClonePerTask`: destroy it. Isolation comes from the instance ceasing
  ## to exist.
  ##
  ## `paRecycleFromPool`: restore the member to its own baseline and bring it
  ## back up, so it is warm before the next task asks for it. Isolation comes
  ## from the restore discarding everything the task wrote -- verified rather
  ## than assumed; see the residue check in the hyperv benchmarks note.
  if lease.isNil: return
  case p.cfg.algorithm
  of paClonePerTask:
    p.cfg.backend.stopAndCleanup(lease.vm, deleteVm = true)
  of paRecycleFromPool:
    let m = lease.member
    if m.isNil:
      raise newException(PoolError,
        "recycle pool released a lease with no member")
    p.cfg.backend.restoreSnapshot(m.name, m.baselineSnapshot)
    p.cfg.backend.startAndAwaitReady(m.vm, timeoutSec = p.cfg.readyTimeoutSec)
    m.inUse = false

proc teardown*(p: Pool) =
  ## Release pool-held resources. Idempotent; best-effort per member so one
  ## wedged instance cannot strand the rest.
  if p.cfg.algorithm == paRecycleFromPool:
    for m in p.members:
      try:
        p.cfg.backend.removeSnapshot(m.name, m.baselineSnapshot)
      except CatchableError: discard
      try:
        p.cfg.backend.stopAndCleanup(m.vm, deleteVm = true)
      except CatchableError: discard
  p.members = @[]
  p.constructed = false

proc freeCount*(p: Pool): int =
  ## Members not currently leased. Always 0 for `paClonePerTask`, which has
  ## no members and is bounded by the host instead.
  for m in p.members:
    if not m.inUse: inc result

proc describe*(p: Pool): string =
  &"{p.cfg.algorithm} baseline={p.cfg.baseline} " &
  &"members={p.members.len} free={p.freeCount()}"
