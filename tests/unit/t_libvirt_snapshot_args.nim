## Unit tests for the pure half of the libvirt snapshot surface (campaign
## WR0 — `Warm-Runners-And-Layered-CI-Images`).
##
## No mocks and no libvirt: everything under test here is a pure function of
## text or of the backend's configuration — the `virsh` argv builder, the
## `domblklist` / `snapshot-list` parsers, the memspec escaping rule, and the
## artifact-path convention. They run on any host, which is why they live in
## `tests/unit` rather than behind the host gate.
##
## The argv shapes asserted here were verified against real
## `virsh 11.7.0` on high-mem-server before being frozen into the assertions
## (an offline scratch domain, `virsh ... --print-xml` for the live form) —
## see `docs/per-backend-notes/libvirt-snapshot-benchmarks.md`. Pinning them
## matters because the difference between a snapshot that carries RAM and
## one that does not is a single flag, and getting it wrong produces a
## snapshot that looks fine and then BOOTS on restore instead of resuming.

import std/[strutils, unittest]
import vm_harness

const DomblklistSample = """
 Type   Device   Target   Source
-------------------------------------------------------------
 file   disk     vda      /storage/libvirt/win-warm-0.qcow2
 file   cdrom    sda      /storage/iso/virtio-win.iso
 file   cdrom    sdb      -
"""

suite "libvirt snapshot: domblklist parsing":
  test "rows are parsed, the header and rule are not":
    let devs = parseDomblklistDetails(DomblklistSample)
    check devs.len == 3
    check devs[0].srcType == "file"
    check devs[0].device == "disk"
    check devs[0].target == "vda"
    check devs[0].source == "/storage/libvirt/win-warm-0.qcow2"
    check devs[1].device == "cdrom"
    check devs[1].source == "/storage/iso/virtio-win.iso"

  test "an empty cdrom tray reports no source rather than a literal dash":
    let devs = parseDomblklistDetails(DomblklistSample)
    check devs[2].target == "sdb"
    check devs[2].source == ""

  test "only writable file-backed disks are snapshotable":
    # The cdroms carry SHARED host media (the Windows ISO, virtio-win). The
    # same rule `undefineDomain` follows for --remove-all-storage, and for
    # the same reason: an external snapshot of those would either fail or
    # start writing overlays next to media other domains are reading.
    let snapd = snapshotableDisks(parseDomblklistDetails(DomblklistSample))
    check snapd.len == 1
    check snapd[0].target == "vda"

  test "two domains sharing a writable disk are detected":
    let a = parseDomblklistDetails(DomblklistSample)
    let b = parseDomblklistDetails("""
 Type   Device   Target   Source
-------------------------------------------------------------
 file   disk     vda      /storage/libvirt/win-warm-0.qcow2
""")
    let c = parseDomblklistDetails("""
 Type   Device   Target   Source
-------------------------------------------------------------
 file   disk     vda      /storage/libvirt/win-warm-1.qcow2
 file   cdrom    sda      /storage/iso/virtio-win.iso
""")
    check sharesWritableDisk(a, b)
    # Sharing a read-only ISO is NOT sharing a disk: every runner mounts the
    # same virtio-win.iso and that has never been an identity problem.
    check not sharesWritableDisk(a, c)

suite "libvirt snapshot: snapshot-list parsing":
  test "names come back one per line with blanks dropped":
    check parseSnapshotNames("pool-baseline-0\n\npool-baseline-1\n") ==
      @["pool-baseline-0", "pool-baseline-1"]

  test "no snapshots is an empty seq, not a one-element blank":
    check parseSnapshotNames("\n\n").len == 0

suite "libvirt snapshot: artifact paths and spec escaping":
  test "the memory-state path is keyed on BOTH domain and snapshot":
    # Load-bearing: a RAM image carries the guest's machine name and DHCP
    # lease. Two domains that shared one memstate path would restore into
    # one identity -- the collision measured on Hyper-V
    # (WIN-EDC8DG9PTDT / 172.27.94.244 on two guests at once).
    let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    check b.memoryStatePathFor("win-warm-0", "pool-baseline-0") ==
      "/storage/libvirt/win-warm-0.pool-baseline-0.memstate"
    check b.memoryStatePathFor("win-warm-1", "pool-baseline-0") !=
      b.memoryStatePathFor("win-warm-0", "pool-baseline-0")
    check b.memoryStatePathFor("win-warm-0", "pool-baseline-1") !=
      b.memoryStatePathFor("win-warm-0", "pool-baseline-0")

  test "snapshotStateDir overrides the image pool for snapshot artifacts":
    # A warm Windows member's RAM image is the guest's whole memory; an
    # operator may want it off the golden's volume.
    let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt",
                              snapshotStateDir = "/fast-nvme/warm")
    check b.effectiveSnapshotStateDir == "/fast-nvme/warm"
    check b.memoryStatePathFor("m", "s") == "/fast-nvme/warm/m.s.memstate"
    check b.snapshotDiskPathFor("m", "s", "vda") ==
      "/fast-nvme/warm/m.s.vda.qcow2"

  test "an unset snapshotStateDir falls back to the image pool":
    let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
    check b.effectiveSnapshotStateDir == "/storage/libvirt"

  test "commas in a spec value are doubled, per virsh(1)":
    check escapeVirshSpec("/pool/a,b.qcow2") == "/pool/a,,b.qcow2"
    check escapeVirshSpec("/pool/plain.qcow2") == "/pool/plain.qcow2"

suite "libvirt snapshot: snapshot-create-as argv":
  let b = newLibvirtBackend(imagePoolDir = "/storage/libvirt")
  let devs = parseDomblklistDetails(DomblklistSample)

  test "the HOT form carries --live and an external memspec":
    # This is the whole point of the milestone: --live plus an external
    # memory image is what captures RAM, and capturing RAM is what makes a
    # restore resume rather than boot.
    let argv = b.buildSnapshotCreateArgs("win-warm-0", "warm", devs,
                                         live = true)
    check argv[0] == "snapshot-create-as"
    check "--live" in argv
    check "--memspec" in argv
    check "file=/storage/libvirt/win-warm-0.warm.memstate,snapshot=external" in
      argv
    # --disk-only would mean "no vm state" and silently give up the resume.
    check "--disk-only" notin argv
    check "--atomic" in argv

  test "the COLD form is --disk-only and carries no memory state":
    let argv = b.buildSnapshotCreateArgs("win-warm-0", "cold", devs,
                                         live = false)
    check "--disk-only" in argv
    check "--live" notin argv
    check "--memspec" notin argv

  test "writable disks get an external overlay; shared media gets snapshot=no":
    let argv = b.buildSnapshotCreateArgs("win-warm-0", "warm", devs,
                                         live = true)
    check "vda,snapshot=external,file=/storage/libvirt/win-warm-0.warm.vda.qcow2" in
      argv
    # Explicit rather than implicit: libvirt would otherwise try to snapshot
    # the shared install ISOs attached as cdroms.
    check "sda,snapshot=no" in argv
    check "sdb,snapshot=no" in argv
    var diskspecCount = 0
    for a in argv:
      if a == "--diskspec": inc diskspecCount
    check diskspecCount == 3

  test "the domain and snapshot names are passed as flags, not positionally":
    # A snapshot name is caller-supplied; passing it positionally would let
    # a name beginning with '-' be read as a virsh flag.
    let argv = b.buildSnapshotCreateArgs("win-warm-0", "warm", devs,
                                         live = true)
    let dIdx = argv.find("--domain")
    let nIdx = argv.find("--name")
    check dIdx >= 0 and argv[dIdx + 1] == "win-warm-0"
    check nIdx >= 0 and argv[nIdx + 1] == "warm"

  test "a domain with no writable disk yields no external diskspec":
    let cdOnly = parseDomblklistDetails("""
 Type   Device   Target   Source
-------------------------------------------------------------
 file   cdrom    sda      /storage/iso/virtio-win.iso
""")
    check snapshotableDisks(cdOnly).len == 0
    let argv = b.buildSnapshotCreateArgs("d", "s", cdOnly, live = true)
    check "sda,snapshot=no" in argv
    for a in argv:
      check not a.contains("snapshot=external,file=")
