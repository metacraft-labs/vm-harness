# guest-linux-tpm — a minimal, fast-booting Linux guest that reports what
# it can see of a virtual TPM, for the `qemu-boot` vTPM gate
# (`tests/integration/t_guest_sees_tpm_device.nim`).
#
# *Why a real Linux guest.* The synthetic 512-byte BIOS boot sector in
# `src/vm_harness/boot_smoke.nim` is enough to prove the serial-expect
# engine works, but it runs in 16-bit real mode and cannot reach the TPM
# TIS MMIO window at 0xFED40000, let alone open `/dev/tpm0`. A vTPM that
# has never been observed from inside a guest is not evidence that the
# backend attached one. So the gate needs a guest that really runs the
# kernel's TPM driver stack.
#
# *Why this shape rather than an OS image.* Everything here is a direct
# kernel boot: a stock nixpkgs `bzImage` plus a busybox initramfs. There
# is no disk, no bootloader, no partition table and no install step, so
# the guest reaches its `/init` in about a second under KVM and the whole
# artifact is a few tens of MiB. `nix/golden-linux-tiny.nix` already uses
# exactly this shape for the libvirt ephemeral-reset gate; this is its
# sibling with a different `/init`.
#
# *Why the kernel needs no TPM modules.* `tpm`, `tpm_tis_core` and
# `tpm_tis` are BUILT IN to the nixpkgs kernel (they appear in
# `modules.builtin`, not as `.ko` files), and QEMU's `-device tpm-tis`
# publishes the device through the ACPI tables QEMU generates itself.
# So the guest finds the TPM with no `insmod` at all — which is also why
# the negative polarity is trustworthy: when no TPM device is attached
# there is nothing the initramfs could have failed to load.
#
# The bundle produced here is two files plus a manifest under $out:
#
#   * ``kernel``       — a stock nixpkgs bzImage.
#   * ``initramfs.gz`` — a busybox initramfs whose ``/init`` prints the
#                        markers below to ttyS0 and powers off.
#   * ``manifest.env`` — the markers and cmdline the consumer asserts on,
#                        so the test does not hard-code them twice.
#
# Markers, in the order `/init` emits them:
#
#   VMH-TPM-PROBE-START
#   VMH-TPM-DEVICE=present | VMH-TPM-DEVICE=absent
#   VMH-TPM-SYSFS-VERSION-MAJOR=<n>            (only when present)
#   VMH-TPM2-GETCAP-FAMILY=<hex response>      (only when present)
#   VMH-TPM-PROBE-DONE
#
# The `GETCAP` line is the load-bearing one. It is not a sysfs readout:
# `/init` opens `/dev/tpm0` read-write on one file descriptor, writes a
# 22-byte TPM2_GetCapability(TPM_CAP_TPM_PROPERTIES,
# TPM_PT_FAMILY_INDICATOR) command, reads the response on the SAME file
# description (the kernel's TPM chardev discards a response if the fd is
# closed in between) and hex-dumps it. A TPM 2.0 answers with the ASCII
# family indicator "2.0\0" = `322e3000`, so the marker carries a value
# that only a real, running, responding TPM 2.0 can produce.

{ pkgs }:

let
  # A static busybox: no shared-library resolution inside the initramfs.
  busybox = pkgs.pkgsStatic.busybox;

  # A stock nixpkgs kernel. Only $out/bzImage is used — the TPM driver
  # stack is builtin, and there is no disk, so no module tree is needed.
  kernelPkg = pkgs.linuxPackages.kernel;
  kernelVersion = kernelPkg.modDirVersion;

  kernelCmdline = "console=ttyS0 panic=1 loglevel=3";

  # TPM2_GetCapability(TPM_CAP_TPM_PROPERTIES, TPM_PT_FAMILY_INDICATOR, 1),
  # byte for byte:
  #
  #   8001              tag        = TPM_ST_NO_SESSIONS
  #   00000016          commandSize = 22
  #   0000017a          commandCode = TPM_CC_GetCapability
  #   00000006          capability  = TPM_CAP_TPM_PROPERTIES
  #   00000100          property    = TPM_PT_FAMILY_INDICATOR
  #   00000001          propertyCount
  #
  # Written as `\` + exactly three octal digits per byte. That padding
  # matters: busybox's printf consumes a backslash plus AT MOST three
  # octal digits and counts the leading zero as one of them, so the
  # `\0ddd` spelling POSIX documents emits `\020` followed by a literal
  # '0' here. Three digits with no `\0` prefix is unambiguous for both.
  getCapFamilyOctal =
    "\\200\\001\\000\\000\\000\\026"
    + "\\000\\000\\001\\172"
    + "\\000\\000\\000\\006"
    + "\\000\\000\\001\\000"
    + "\\000\\000\\000\\001";

  # The guest ``/init``. Intentionally tiny and dependency-free.
  initScript = pkgs.writeText "guest-linux-tpm-init" ''
    #!/bin/busybox sh
    /bin/busybox mkdir -p /proc /sys /dev
    /bin/busybox mount -t proc proc /proc
    /bin/busybox mount -t sysfs sys /sys
    /bin/busybox mount -t devtmpfs dev /dev 2>/dev/null
    echo "VMH-TPM-PROBE-START" > /dev/console

    # The TPM chardev is registered during driver probe, which has
    # already happened by the time /init runs on this kernel; the wait
    # bounds a slow probe rather than papering over an absent device.
    # It is short on purpose: the ABSENT case must not cost seconds.
    tries=0
    while [ ! -c /dev/tpm0 ] && [ $tries -lt 20 ]; do
      /bin/busybox sleep 0.1
      tries=$((tries + 1))
    done

    if [ -c /dev/tpm0 ]; then
      echo "VMH-TPM-DEVICE=present" > /dev/console
      major=$(/bin/busybox cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)
      echo "VMH-TPM-SYSFS-VERSION-MAJOR=$major" > /dev/console
      # One file description for the whole command/response exchange.
      exec 3<> /dev/tpm0
      /bin/busybox printf '${getCapFamilyOctal}' >&3
      # The kernel's TPM chardev dispatches the command from a work queue
      # and its read() returns 0 — not EAGAIN, not a block — until the
      # response has landed. So poll rather than assume.
      resp=""
      n=0
      while [ -z "$resp" ] && [ $n -lt 50 ]; do
        resp=$(/bin/busybox dd bs=4096 count=1 <&3 2>/dev/null \
               | /bin/busybox od -An -v -tx1 \
               | /bin/busybox tr -d ' \n')
        [ -n "$resp" ] && break
        /bin/busybox sleep 0.1
        n=$((n + 1))
      done
      exec 3>&-
      echo "VMH-TPM2-GETCAP-FAMILY=$resp" > /dev/console
    else
      echo "VMH-TPM-DEVICE=absent" > /dev/console
    fi

    echo "VMH-TPM-PROBE-DONE" > /dev/console
    /bin/busybox poweroff -f
  '';

  applets = [
    "sh"
    "mount"
    "mkdir"
    "cat"
    "dd"
    "od"
    "tr"
    "printf"
    "sleep"
    "sync"
    "poweroff"
    "ln"
  ];
in
pkgs.runCommand "guest-linux-tpm"
  {
    nativeBuildInputs = [
      pkgs.cpio
      pkgs.gzip
    ];
    inherit kernelVersion kernelCmdline;
  }
  ''
    mkdir -p $out

    # ---- kernel ------------------------------------------------------
    cp ${kernelPkg}/bzImage $out/kernel

    # ---- initramfs ---------------------------------------------------
    root=$(mktemp -d)
    mkdir -p $root/bin $root/dev $root/proc $root/sys
    cp ${busybox}/bin/busybox $root/bin/busybox
    chmod +w $root/bin/busybox
    for a in ${pkgs.lib.concatStringsSep " " applets}; do
      ln -sf busybox $root/bin/$a
    done

    cp ${initScript} $root/init
    chmod +x $root/init

    ( cd $root && find . -print0 | \
        cpio --null -o -H newc --quiet | gzip -9 ) > $out/initramfs.gz

    # Record what the consumer asserts on, so the markers are not
    # hard-coded independently on both sides.
    cat > $out/manifest.env <<EOF
    GUEST_KERNEL_CMDLINE=${kernelCmdline}
    GUEST_KERNEL_VERSION=${kernelVersion}
    GUEST_MARKER_START=VMH-TPM-PROBE-START
    GUEST_MARKER_PRESENT=VMH-TPM-DEVICE=present
    GUEST_MARKER_ABSENT=VMH-TPM-DEVICE=absent
    GUEST_MARKER_DONE=VMH-TPM-PROBE-DONE
    EOF
  ''
