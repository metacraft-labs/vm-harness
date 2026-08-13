## Unit tests for the qemu-windows-arm ephemeral disk provisioning: qcow2
## backing overlay (default), whole-file clone fallback, disk-path selection,
## and the per-instance liveness lock that ``prune`` relies on.
##
## These exercise real ``qemu-img`` (from the Nix dev env) against a tiny
## synthetic baseline; they never boot QEMU.

import std/[os, osproc, strutils, tempfiles, unittest]
import vm_harness

let qemuImgPath = findExe("qemu-img")

proc makeBaseline(dir: string) =
  ## A minimal baseline: a real (tiny) qcow2 golden, a firmware vars file,
  ## and a seeded TPM directory.
  createDir(dir)
  let r = execCmdEx(qemuImgPath & " create -f qcow2 " &
                    quoteShell(dir / QwaBaseDiskName) & " 16M")
  doAssert r.exitCode == 0, "qemu-img create baseline failed: " & r.output
  writeFile(dir / "QEMU_EFI_VARS.fd", "fake-uefi-vars")
  createDir(dir / "tpm")
  writeFile(dir / "tpm" / "tpm2-00.permall", "fake-tpm-state")

suite "qemu-windows-arm ephemeral disk: overlay mode":
  test "createEphemeralOverlay makes a thin overlay backed by the golden":
    if qemuImgPath.len == 0:
      skip()
    else:
      let img = qemuImgPath
      let root = createTempDir("vmh-overlay-", "")
      defer: removeDir(root)
      let base = root / "baseline"
      let inst = root / "inst"
      makeBaseline(base)

      createEphemeralOverlay(base, inst, img)

      check fileExists(inst / QwaOverlayDiskName)
      # The golden itself is never copied into the instance.
      check not fileExists(inst / QwaBaseDiskName)
      # Firmware + TPM are cloned per-instance.
      check fileExists(inst / "QEMU_EFI_VARS.fd")
      check fileExists(inst / "tpm" / "tpm2-00.permall")

      # The overlay's backing file must point at the golden.
      let info = execCmdEx(img & " info " & quoteShell(inst / QwaOverlayDiskName))
      check info.exitCode == 0
      check (base / QwaBaseDiskName) in info.output

      # The overlay is metadata-only (a fresh qcow2 with a backing file is a
      # few hundred KB regardless of the golden's virtual size) — proof that
      # the golden was referenced, not copied.
      check getFileSize(inst / QwaOverlayDiskName) < 1_048_576

  test "qwaDiskImagePath prefers the overlay, falls back to the base disk":
    let root = createTempDir("vmh-diskpath-", "")
    defer: removeDir(root)
    createDir(root)
    # No disk files yet → falls back to the base name.
    check qwaDiskImagePath(root) == root / QwaBaseDiskName
    writeFile(root / QwaBaseDiskName, "x")
    check qwaDiskImagePath(root) == root / QwaBaseDiskName
    writeFile(root / QwaOverlayDiskName, "y")
    check qwaDiskImagePath(root) == root / QwaOverlayDiskName

  test "buildQemuWindowsArmArgs boots from the overlay when present":
    let root = createTempDir("vmh-args-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / QwaBaseDiskName, "x")
    writeFile(root / QwaOverlayDiskName, "y")
    let args = buildQemuWindowsArmArgs(root, 2223, 2, 4096)
    let joined = args.join(" ")
    check (root / QwaOverlayDiskName) in joined
    check (root / QwaBaseDiskName & ",format=qcow2") notin joined

  test "clone mode copies a full independent windows.qcow2 (no overlay)":
    if qemuImgPath.len == 0:
      skip()
    else:
      let root = createTempDir("vmh-clone-", "")
      defer: removeDir(root)
      let base = root / "baseline"
      let inst = root / "inst"
      makeBaseline(base)
      createEphemeralCopy(base, inst)
      check fileExists(inst / QwaBaseDiskName)
      check not fileExists(inst / QwaOverlayDiskName)
      check fileExists(inst / "QEMU_EFI_VARS.fd")

suite "qemu-windows-arm per-instance liveness lock":
  test "a held lock reports the owner alive; releasing reports it dead":
    when defined(posix):
      let root = createTempDir("vmh-lock-", "")
      defer: removeDir(root)
      let b = newQemuWindowsArmBackend()
      let name = "repro-vm-qemu-windows-arm-1700000000000-4242"
      let vmDir = ephemeralDirFor(root, name)
      createDir(vmDir)
      b.acquireInstanceLock(name, vmDir)
      check fileExists(qwaInstanceLockPath(vmDir))
      check instanceDirOwnerAlive(vmDir)     # we hold it
      b.releaseInstanceLock(name)
      check not instanceDirOwnerAlive(vmDir)  # nobody holds it now
    else:
      skip()

  test "legacy dir without a lock falls back to the PID in the name":
    let root = createTempDir("vmh-legacy-", "")
    defer: removeDir(root)
    # A definitely-dead PID (very large) → owner dead.
    let deadDir = ephemeralDirFor(root, "repro-vm-qemu-windows-arm-1700000000000-2147480000")
    createDir(deadDir)
    check not instanceDirOwnerAlive(deadDir)
    # Our own PID → owner alive.
    let liveDir = ephemeralDirFor(root, "repro-vm-qemu-windows-arm-1700000000000-" & $getCurrentProcessId())
    createDir(liveDir)
    check instanceDirOwnerAlive(liveDir)
