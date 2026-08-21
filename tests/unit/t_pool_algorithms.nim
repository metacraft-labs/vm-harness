## Unit tests for the two pool algorithms.
##
## Driven against the noop backend, so they run on any host with no
## hypervisor. What is under test is the ALGORITHM -- who creates, who
## destroys, who resets, and when -- not any backend's timing.
##
## The properties pinned here are the ones that were expensive to learn and
## are easy to regress into:
##
##   * `release`, not `acquire`, does the resetting. Moving it would put the
##     recycle cost back on the critical path and give up the benefit.
##   * Each member gets its OWN baseline checkpoint. A shared one produces
##     guests with identical machine names and DHCP leases, because a
##     RAM-carrying checkpoint captures identity too.
##   * A recycle pool is built with `snapshotRunning`, so a backend that
##     cannot capture running state fails at CONSTRUCTION rather than
##     degrading silently into a slow cold-boot pool.

import std/[strutils, unittest]
import vm_harness

proc mkPool(alg: PoolAlgorithm, size: int = 2): Pool =
  let b = newNoopBackend()
  var spec = BaselineSpec(name: "golden", guestOs: goLinux, guestArch: gaX86_64)
  b.provisionBaseline(spec)
  var cfg = PoolConfig(backend: b, baseline: "golden", algorithm: alg,
                       size: size, readyTimeoutSec: 5)
  if alg == paRecycleFromPool:
    # Supply distinct members explicitly, the way a real recycle-capable
    # backend does. Without this the helper leans on noop's revertToBaseline,
    # which names instances from epochTime() and so returns colliding names
    # inside one fractional second -- which construct() then (correctly)
    # rejects as aliasing. Testing the algorithm should not depend on the
    # fake backend's clock resolution.
    cfg.createMember = proc(idx: int): VmHandle =
      VmHandle(backend: b, name: "pool-member-" & $idx, baseline: "golden")
  newPool(cfg)

suite "pool: the development-time backend selection":
  test "Hyper-V recycles; measured clone is no better than a cold boot":
    check defaultAlgorithmFor(biHyperv) == paRecycleFromPool

  test "libvirt clones -- forced, because its restore is unimplemented":
    check defaultAlgorithmFor(biLibvirt) == paClonePerTask

  test "incus clones pending the ZFS-vs-dir measurement":
    check defaultAlgorithmFor(biIncus) == paClonePerTask

  test "an unmeasured backend defaults to the isolation-safe algorithm":
    # Wrong about speed is recoverable; wrong about isolation is not.
    check defaultAlgorithmFor(biWsl) == paClonePerTask

suite "pool: configuration is validated before any I/O":
  test "a recycle pool requires a size":
    expect PoolError:
      discard newPool(PoolConfig(backend: newNoopBackend(), baseline: "g",
                                 algorithm: paRecycleFromPool, size: 0))

  test "a baseline is required":
    expect PoolError:
      discard newPool(PoolConfig(backend: newNoopBackend(), baseline: "",
                                 algorithm: paClonePerTask))

  test "acquire before construct is refused rather than half-working":
    let p = mkPool(paClonePerTask)
    expect PoolError:
      discard p.acquire()

suite "clone-per-task":
  test "every acquire derives a FRESH instance rather than reusing one":
    # Asserted at the level the POOL guarantees: each acquire goes back to
    # the backend for a new guest, so the handles are distinct objects and
    # neither is drawn from a member list.
    #
    # Deliberately NOT asserting distinct vm.name here: noop derives names
    # from epochTime(), so two acquires inside the same fractional second
    # collide. That would be testing the fake backend's clock resolution,
    # not the algorithm. Instance distinctness on a real backend is checked
    # by tools/bench/clone_per_task_bench.nim's --assert-creates-instance.
    let p = mkPool(paClonePerTask)
    p.construct()
    let a = p.acquire()
    let b = p.acquire()
    check not a.vm.isNil
    check not b.vm.isNil
    check not (a.vm == b.vm)      # distinct handles, not the same guest reused
    check a.member == nil
    check b.member == nil
    check p.members.len == 0      # nothing was pooled
    p.release(a); p.release(b)

  test "it holds no members -- capacity is bounded by the host, not by size":
    let p = mkPool(paClonePerTask, size = 4)
    p.construct()
    check p.members.len == 0
    check p.freeCount() == 0

  test "a lease carries no member, because there is nothing to return to":
    let p = mkPool(paClonePerTask)
    p.construct()
    let l = p.acquire()
    check l.member == nil
    p.release(l)

suite "recycle-from-pool-per-task":
  test "construct creates exactly `size` members, all free":
    let p = mkPool(paRecycleFromPool, size = 3)
    p.construct()
    check p.members.len == 3
    check p.freeCount() == 3

  test "each member gets its OWN baseline checkpoint, never a shared one":
    # A RAM-carrying checkpoint captures the machine name and DHCP lease, so
    # N members restored from ONE checkpoint collide. This is the guard.
    let p = mkPool(paRecycleFromPool, size = 3)
    p.construct()
    var seen: seq[string] = @[]
    for m in p.members:
      check m.baselineSnapshot.len > 0
      check m.baselineSnapshot notin seen
      seen.add(m.baselineSnapshot)
    check seen.len == 3

  test "acquire takes a member and release returns it":
    let p = mkPool(paRecycleFromPool, size = 2)
    p.construct()
    let l = p.acquire()
    check p.freeCount() == 1
    check l.member != nil
    check l.member.inUse
    p.release(l)
    check p.freeCount() == 2
    check not l.member.inUse

  test "exhausting the pool is an error, not an unbounded queue":
    let p = mkPool(paRecycleFromPool, size = 1)
    p.construct()
    let l = p.acquire()
    expect PoolError:
      discard p.acquire()
    p.release(l)

  test "a released member is reusable, and keeps its identity":
    # The member's instance name must NOT change across a recycle -- that
    # stability is what makes per-member baselines meaningful.
    let p = mkPool(paRecycleFromPool, size = 1)
    p.construct()
    let first = p.acquire()
    let nameBefore = first.vm.name
    p.release(first)
    let second = p.acquire()
    check second.vm.name == nameBefore
    check second.member == first.member
    p.release(second)

  test "construct is idempotent -- it does not double the pool":
    let p = mkPool(paRecycleFromPool, size = 2)
    p.construct()
    p.construct()
    check p.members.len == 2

  test "teardown empties the pool and un-constructs it":
    let p = mkPool(paRecycleFromPool, size = 2)
    p.construct()
    p.teardown()
    check p.members.len == 0
    check not p.constructed
    expect PoolError:
      discard p.acquire()

suite "pool: describe is legible enough to log":
  test "names the algorithm and the free count":
    let p = mkPool(paRecycleFromPool, size = 2)
    p.construct()
    let d = p.describe()
    check "recycle-from-pool-per-task" in d
    check "free=2" in d

suite "pool: a backend that cannot create members fails loudly":
  test "aliased members are refused rather than silently pooled":
    # Reproduces the Hyper-V shape: revertToBaseline resets ONE long-lived
    # guest, so every call returns the same instance. Without the guard the
    # pool would report N members that all alias one VM, and releasing one
    # would reset another's running task.
    let b = newNoopBackend()
    var spec = BaselineSpec(name: "golden", guestOs: goLinux, guestArch: gaX86_64)
    b.provisionBaseline(spec)
    let shared = VmHandle(backend: b, name: "the-one-and-only-vm",
                          baseline: "golden")
    let p = newPool(PoolConfig(
      backend: b, baseline: "golden", algorithm: paRecycleFromPool,
      size: 3, readyTimeoutSec: 5,
      createMember: proc(idx: int): VmHandle = shared))
    expect PoolError:
      p.construct()

  test "createMember is used when supplied, and distinct members pass":
    let b = newNoopBackend()
    var spec = BaselineSpec(name: "golden", guestOs: goLinux, guestArch: gaX86_64)
    b.provisionBaseline(spec)
    var made = 0
    let p = newPool(PoolConfig(
      backend: b, baseline: "golden", algorithm: paRecycleFromPool,
      size: 3, readyTimeoutSec: 5,
      createMember: proc(idx: int): VmHandle =
        inc made
        VmHandle(backend: b, name: "member-" & $idx, baseline: "golden")))
    p.construct()
    check made == 3
    check p.members.len == 3
    check p.members[0].name == "member-0"
    check p.members[2].name == "member-2"
