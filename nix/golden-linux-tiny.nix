# golden-linux-tiny — a minimal, fast-booting Linux golden image for the
# libvirt per-job ephemeral-reset gate (`t_vmharness_libvirt_ephemeral_run`,
# campaign M2).
#
# This is deliberately NOT the 81 GiB Windows golden. The per-job
# CoW-clone / boot / teardown primitive in the libvirt backend is
# OS-agnostic; the gate only needs a golden that:
#
#   * boots on real KVM in ~1-2 s (no full OS install),
#   * emits an observable boot marker on the serial console (so the
#     harness can prove a genuinely fresh boot happened), and
#   * carries a byte marker on its disk that the guest can READ and then
#     over-write, so two consecutive per-job clones can be proven
#     independent (a stamp written by run 1 is absent in run 2 because
#     each run gets a fresh CoW overlay backed by the pristine golden).
#
# The bundle produced here is three files under $out:
#
#   * ``kernel``        — a stock nixpkgs bzImage.
#   * ``initramfs.gz``  — a busybox initramfs whose ``/init`` loads the
#                          virtio-blk driver stack, reads the on-disk
#                          marker, stamps the (overlay) disk, prints
#                          markers to ttyS0, and powers off.
#   * ``golden.qcow2``  — a tiny qcow2 whose first sector holds the
#                          pristine baseline marker
#                          (``GOLDEN-BASELINE-PRISTINE``).
#
# The libvirt backend clones ``golden.qcow2`` into a per-job CoW overlay
# (``qemu-img create -f qcow2 -b golden -F qcow2 overlay``), defines a
# transient domain that direct-kernel-boots ``kernel`` + ``initramfs.gz``
# against the overlay, boots it on KVM, harvests the serial marker, then
# tears the domain + overlay down leaving no residue.

{ pkgs }:

let
  # A static busybox: no shared-library resolution inside the initramfs.
  busybox = pkgs.pkgsStatic.busybox;

  # A stock nixpkgs kernel + its module tree. virtio_blk is a module in
  # the default nixpkgs kernel, so the initramfs bundles the small
  # virtio module chain and insmods it before touching the disk.
  kernelPkg = pkgs.linuxPackages.kernel;
  # The nixpkgs kernel splits its module tree into a separate ``modules``
  # output (``$out`` carries only bzImage + System.map).
  kernelModules = kernelPkg.modules or kernelPkg;
  kernelVersion = kernelPkg.modDirVersion;

  # The pristine on-disk baseline marker. Read by the guest; a per-run
  # stamp over-writes it in the CoW overlay only.
  baselineMarker = "GOLDEN-BASELINE-PRISTINE";

  # The guest ``/init``. Kept intentionally tiny and dependency-free.
  initScript = pkgs.writeText "golden-init" ''
    #!/bin/busybox sh
    /bin/busybox mkdir -p /proc /sys /dev
    /bin/busybox mount -t proc proc /proc
    /bin/busybox mount -t sysfs sys /sys
    /bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
    echo "GOLDEN-INIT-START" > /dev/console
    # Load order matters: virtio_ring is a hard dependency of virtio (and
    # of virtio_pci) on modern kernels, so it must go in first.
    for ko in virtio_ring virtio virtio_pci_modern_dev \
              virtio_pci_legacy_dev virtio_pci virtio_blk; do
      /bin/busybox insmod /lib/mods/$ko.ko >/dev/null 2>&1
    done
    # Give the virtio-blk probe a moment to register /dev/vda.
    tries=0
    while [ ! -b /dev/vda ] && [ $tries -lt 50 ]; do
      /bin/busybox sleep 0.1
      tries=$((tries + 1))
    done
    if [ -b /dev/vda ]; then
      MARK=$(/bin/busybox dd if=/dev/vda bs=64 count=1 2>/dev/null | \
             /bin/busybox tr -d '\000')
      echo "MARKER-READ=[$MARK]" > /dev/console
      # Stamp THIS overlay so a state-bleed across per-job clones would
      # surface as a non-pristine MARKER-READ on a subsequent boot of the
      # same disk. A fresh CoW overlay never sees this stamp.
      printf 'DIRTIED-BY-RUN' | \
        /bin/busybox dd of=/dev/vda bs=1 seek=0 conv=notrunc 2>/dev/null
      /bin/busybox sync
      echo "GOLDEN-STAMPED" > /dev/console
    else
      echo "NO-DISK" > /dev/console
    fi
    echo "GOLDEN-INIT-DONE" > /dev/console
    /bin/busybox poweroff -f
  '';

  applets = [
    "sh"
    "mount"
    "insmod"
    "dd"
    "tr"
    "sleep"
    "poweroff"
    "mkdir"
    "sync"
    "cat"
    "ln"
  ];
in
pkgs.runCommand "golden-linux-tiny"
  {
    nativeBuildInputs = [
      pkgs.cpio
      pkgs.gzip
      pkgs.xz
      pkgs.qemu
    ];
    inherit baselineMarker kernelVersion;
  }
  ''
    mkdir -p $out

    # ---- kernel ------------------------------------------------------
    cp ${kernelPkg}/bzImage $out/kernel

    # ---- initramfs ---------------------------------------------------
    root=$(mktemp -d)
    mkdir -p $root/bin $root/dev $root/proc $root/sys $root/lib/mods
    cp ${busybox}/bin/busybox $root/bin/busybox
    chmod +w $root/bin/busybox
    for a in ${pkgs.lib.concatStringsSep " " applets}; do
      ln -sf busybox $root/bin/$a
    done

    modroot=${kernelModules}/lib/modules/${kernelVersion}/kernel
    for m in drivers/virtio/virtio \
             drivers/virtio/virtio_ring \
             drivers/virtio/virtio_pci_modern_dev \
             drivers/virtio/virtio_pci_legacy_dev \
             drivers/virtio/virtio_pci \
             drivers/block/virtio_blk; do
      src="$modroot/$m.ko"
      if [ -f "$src.xz" ]; then
        xz -dc "$src.xz" > "$root/lib/mods/$(basename $m).ko"
      elif [ -f "$src.zst" ]; then
        ${pkgs.zstd}/bin/zstd -dc "$src.zst" > "$root/lib/mods/$(basename $m).ko"
      elif [ -f "$src" ]; then
        cp "$src" "$root/lib/mods/$(basename $m).ko"
      else
        echo "missing module: $m" >&2; exit 1
      fi
    done

    cp ${initScript} $root/init
    chmod +x $root/init

    ( cd $root && find . -print0 | \
        cpio --null -o -H newc --quiet | gzip -9 ) > $out/initramfs.gz

    # ---- golden qcow2 ------------------------------------------------
    # A tiny raw disk whose first bytes hold the pristine baseline
    # marker, converted to qcow2 (so the backend's CoW-overlay
    # `qemu-img create -b` path applies unchanged).
    raw=$(mktemp)
    qemu-img create -f raw "$raw" 16M >/dev/null
    printf '%s' "$baselineMarker" | dd of="$raw" bs=1 seek=0 conv=notrunc \
      2>/dev/null
    qemu-img convert -f raw -O qcow2 "$raw" $out/golden.qcow2
    rm -f "$raw"

    # Record the marker + kernel cmdline the backend/test rely on so the
    # consumer doesn't have to hard-code them.
    cat > $out/manifest.env <<EOF
    GOLDEN_BASELINE_MARKER=$baselineMarker
    GOLDEN_KERNEL_CMDLINE=console=ttyS0 quiet panic=1
    GOLDEN_KERNEL_VERSION=${kernelVersion}
    EOF
  ''
