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
    # MEASURED 2026-09-05 on high-mem-server, against the real 16 GiB
    # Windows golden (`golden-win11-cloudbase.qcow2`, 4 vCPU, UEFI/q35 --
    # the production eph-win-x64 shape). The answer is NO, and it is not
    # close. This entry used to say "not measured"; it now says "measured,
    # and recycling does not clear the bar".
    #
    #   restore + resume -> SSH-ready  p50 46.9 s  (n=10, interleaved)
    #                                  p50 35.9 s  (n=5, tools/bench)
    #   cold boot -> SSH-ready         p50 73.7 s  (n=10, same run)
    #                                  p50 59.0 s  (n=5, clean boots)
    #   ratio, same interleaved run    1.57x       (1.26x vs clean boot)
    #
    # The bar was p50 <= 10 s AND >= 4x. Both fail by 3-4x.
    #
    # Read that carefully: recycling is NOT slower. It is modestly faster
    # than the boot it replaces -- 1.57x against the interleaved cold arm,
    # 1.26x against a clean boot. It is just not faster ENOUGH.
    # `paRecycleFromPool` buys a member that carries state across jobs, and
    # a 1.26-1.57x saving does not pay for that isolation risk where a 4x+
    # saving would have. So `paClonePerTask` stays because it cannot be
    # wrong about isolation and the speedup on offer is too small to trade
    # for that -- NOT because it is the faster path.
    #
    # WHY, because the decomposition is what a future implementer needs:
    #
    #   snapshot-revert --running   34.4 s   <- 96% of the cycle
    #   resume -> SSH-ready          1.7 s   <-   5% of the cycle
    #
    # The guest is NOT the problem. 1.7 s back to SSH-ready beats Hyper-V's
    # 5.08 s on the same guest OS. The whole cost is re-reading the 2.61 GiB
    # memory image at ~81 MB/s, against ~668 MB/s for Hyper-V's comparable
    # 3,395 MB image. That ~8x throughput gap is the single thing standing
    # between libvirt and the budget, and it is structural rather than
    # contention: the bench ran at HIGHER host load than the gate (load1
    # 38->71 vs 11->38) and was FASTER, with a tight 27.4-37.4 s spread.
    #
    # The storage properties the algorithm depends on all hold, and were
    # re-confirmed at Windows scale across 20 reverts: a restore rewrites
    # neither the frozen disk nor the memory image (both byte-stable, mtime
    # unchanged to the nanosecond), and each cycle writes only a disposable
    # ~120 MB overlay. So "prepare once, restore many" IS the cheap
    # direction on qcow2 -- it is simply not a fast one.
    #
    # WHAT WOULD JUSTIFY REVISITING: not a re-run of the same benchmark, but
    # a fix to the memory-image reload. Get `snapshot-revert --running`
    # under ~10 s for a 2.6 GiB memstate and the arithmetic inverts, because
    # the resume half already clears the budget with room to spare.
    # Candidates, none of them yet separated: single-threaded incoming
    # migration-from-file, ZFS overhead on the memstate volume, and the
    # QEMU process teardown/re-create that an external-snapshot revert does.
    # Full numbers, host conditions and evidence:
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
