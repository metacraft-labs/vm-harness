## t_vmharness_incus_ephemeral_run (campaign IM1 gate).
##
## Proves the Incus per-job EPHEMERAL container reset against REAL Incus:
## each job gets a FRESH container launched from the base image, is probed
## via ``incus exec``, then destroyed (``incus delete --force``) leaving NO
## residue. This is the container analog of the libvirt
## ``t_vmharness_libvirt_ephemeral_run`` gate — fast, no ``/dev/kvm``
## needed. It is the primitive the GARM provider's CreateInstance/
## DeleteInstance map onto (wired in a later milestone).
##
## What it asserts (all against a genuinely launched container, NOT a
## noop/mock):
##
##   (a) PROBE — a fresh per-job container reaches Running and an in-guest
##       ``incus exec`` probe succeeds AND the container is genuinely
##       fresh: a sentinel marker file the harness writes into run 1 is
##       ABSENT at launch (asserted below in the independence check).
##   (b) NO RESIDUE — after ``stopAndCleanup(deleteVm=true)`` there is NO
##       residual container (``incus list`` clean of the job name) AND NO
##       residual ``container/<name>`` storage volume on the pool. The base
##       image is untouched.
##   (c) TWO-RUN INDEPENDENCE — a marker file written INTO the guest in run
##       1 is ABSENT in run 2's fresh container. Run 2 is a brand-new
##       container launched from the untouched base image, so no state
##       bleeds across per-job clones.
##
## The base image is the small ``vmh-base`` (Debian 12) pinned in the local
## image store during IM0 (``incus image copy images:debian/12 local:
## --alias vmh-base``). The image alias is taken from ``VMH_INCUS_BASE``
## (default ``vmh-base``). Socket access: the CLI talks to
## ``/var/lib/incus/unix.socket`` (group ``incus-admin``). In a session that
## pre-dates the group grant, export ``VMH_INCUS_CMD="sudo -n incus"`` (the
## ``-n`` makes sudo fail fast instead of blocking on a password prompt). The
## test self-skips cleanly when Incus isn't usable or the base image is
## absent.
##
## Run (from a vm-harness checkout on a Linux host with Incus):
##   export VMH_INCUS_CMD="sudo -n incus"   # only if group not yet active
##   nim r --hints:off tests/e2e/t_vmharness_incus_ephemeral_run.nim

import std/[os, strutils, tables, unittest]
import vm_harness

when not defined(linux):
  echo "[skip] t_vmharness_incus_ephemeral_run: Linux host required"
  quit(0)

let baseImage =
  block:
    let e = getEnv("VMH_INCUS_BASE")
    if e.len > 0: e else: "vmh-base"

proc newTestBackend(): IncusBackend =
  ## Honours VMH_INCUS_CMD (resolved inside newIncusBackend) so the gate
  ## can run under ``sudo incus`` in a session that pre-dates the
  ## incus-admin group grant.
  newIncusBackend(baseImage = baseImage)

const
  MarkerPath = "/root/vmh-run-marker"
  MarkerText = "DIRTIED-BY-RUN-1"

proc markerPresent(b: IncusBackend, vm: VmHandle): bool =
  ## True iff the sentinel marker file exists in the guest.
  let r = b.execInGuest(vm, initTable[string, string](),
                        @["test", "-f", MarkerPath], timeoutSec = 30)
  r.exitCode == 0

suite "t_vmharness_incus_ephemeral_run":
  let b = newTestBackend()

  test "incus is usable + base image present (else skip)":
    if not b.probeAvailability():
      echo "[skip] incus daemon not reachable via the configured command " &
           "(set VMH_INCUS_CMD=\"sudo -n incus\" if the incus-admin group is " &
           "not active in this session)"
      skip()
    else:
      check b.probeAvailability()
      # provisionBaseline verifies the base image is present; a missing
      # image raises, which we surface as a skip (IM0 must pull it first).
      var ok = true
      try:
        b.provisionBaseline(BaselineSpec(sourceImage: baseImage,
                                         guestOs: goLinux))
      except CatchableError:
        ok = false
      if not ok:
        echo "[skip] base image '" & baseImage & "' absent; pull it first " &
             "(`incus image copy images:debian/12 local: --alias " &
             baseImage & "`)"
        skip()
      else:
        check ok

  test "per-job container launches, probes, tears down with no residue, " &
       "two runs are independent":
    if not b.probeAvailability():
      echo "[skip] incus not usable"
      skip()
    else:
      var haveImage = true
      try:
        b.provisionBaseline(BaselineSpec(sourceImage: baseImage,
                                         guestOs: goLinux))
      except CatchableError:
        haveImage = false
      if not haveImage:
        echo "[skip] base image '" & baseImage & "' absent"
        skip()
      else:
        let job1 = "vmh-incus-eph-run1"
        let job2 = "vmh-incus-eph-run2"

        # Pre-clean any residue from a crashed prior run.
        for j in [job1, job2]:
          if b.containerExists(j):
            discard b.deleteContainer(j)

        # ---- RUN 1 ---------------------------------------------------
        var vm1 = b.provisionEphemeralClone(
          EphemeralIncusSpec(name: job1, baseImage: baseImage))
        var out1exit = -99
        var run1Fresh = false
        try:
          b.startAndAwaitReady(vm1, 60)
          # (a) PROBE succeeds on a genuinely launched container.
          let probe = b.execInGuest(vm1, initTable[string, string](),
                                    @["echo", "probe-ok"], timeoutSec = 30)
          out1exit = probe.exitCode
          check probe.exitCode == 0
          check "probe-ok" in probe.stdout
          # The container is genuinely FRESH: the sentinel from a prior
          # run must NOT already be present in run 1.
          run1Fresh = not markerPresent(b, vm1)
          check run1Fresh
          # Now DIRTY the guest: write the marker file. If any state bled
          # into run 2, run 2 would observe this file.
          let w = b.execInGuest(vm1, initTable[string, string](),
                                @["sh", "-c",
                                  "echo " & MarkerText & " > " & MarkerPath],
                                timeoutSec = 30)
          check w.exitCode == 0
          check markerPresent(b, vm1)
        finally:
          b.stopAndCleanup(vm1, deleteVm = true)

        # (b) NO RESIDUE after teardown.
        check (not b.containerExists(job1))
        check (job1 notin b.listContainerNames())
        check (not b.storageVolumeExists(job1))

        # ---- RUN 2 (independence) ------------------------------------
        var vm2 = b.provisionEphemeralClone(
          EphemeralIncusSpec(name: job2, baseImage: baseImage))
        try:
          b.startAndAwaitReady(vm2, 60)
          let probe2 = b.execInGuest(vm2, initTable[string, string](),
                                     @["echo", "probe-ok-2"], timeoutSec = 30)
          check probe2.exitCode == 0
          check "probe-ok-2" in probe2.stdout
          # (c) Run 2's fresh container must NOT carry run 1's marker.
          check (not markerPresent(b, vm2))
        finally:
          b.stopAndCleanup(vm2, deleteVm = true)

        # Run 2 also leaves no residue.
        check (not b.containerExists(job2))
        check (not b.storageVolumeExists(job2))
