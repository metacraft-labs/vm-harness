## unit_vm_harness_lima_backend — LimaBackend command-construction tests.
##
## Mock policy (per design.md §9.1): NO backend mock. These are the
## sanctioned "shell shim" style — a real ``limactl`` stand-in binary on
## disk that records its argv and exits 0 — driven through the real
## ``osproc`` code path. We assert the *commands vm-harness constructs*,
## not any faked behavior:
##
##  1. ``revertToBaseline`` threads a pinned ``--source-image`` /
##     template into its per-gate ``limactl create`` when
##     ``baselineSourceImage`` is set, and falls back to the embedded
##     ``DefaultLimaTemplate`` (a temp ``.yaml`` file) when it is empty.
##  2. ``copyToGuest`` of a DIRECTORY builds a tar-stream pipeline
##     (in-guest ``tar -xf - -C <parent>``) instead of ``limactl copy
##     --recursive``; a single FILE still uses ``limactl copy``.
##
## POSIX-only: the shim is a ``/bin/sh`` script. On non-POSIX hosts the
## suite is a no-op (the deterministic catalog runs on Nix Linux/macOS).

import std/[os, strutils, tempfiles, unittest]
import vm_harness/backends/lima
import vm_harness/types

proc writeShim(path, logPath: string) =
  ## A fake ``limactl`` that appends its whole argv (one line per
  ## invocation) to ``logPath`` and exits 0.
  writeFile(path, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" & logPath & "'\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc createLine(logText: string): string =
  ## Return the recorded ``limactl create ...`` invocation line.
  for line in logText.splitLines():
    if line.startsWith("create "):
      return line
  return ""

when defined(posix):
  suite "LimaBackend command construction":

    test "revert threads a pinned source-image into limactl create":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      writeShim(shim, log)

      let b = newLimaBackend(
        limactlCmd = shim,
        sourceImage = "template:ubuntu-24.04")
      discard b.revertToBaseline("baseline")

      let create = createLine(readFile(log))
      check create.len > 0
      check "template:ubuntu-24.04" in create
      # The embedded-template temp file must NOT be used when pinned.
      check ".yaml" notin create

    test "revert falls back to the embedded template when unpinned":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      writeShim(shim, log)

      let b = newLimaBackend(limactlCmd = shim)  # no source image
      discard b.revertToBaseline("baseline")

      let create = createLine(readFile(log))
      check create.len > 0
      # Embedded template is materialized to a temp .yaml path, not a
      # source-image / template: reference.
      check ".yaml" in create
      check "template:" notin create

    test "copyToGuest of a directory builds a tar-stream, not copy -r":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      writeShim(shim, log)
      # Real source directory with content, so host `tar` succeeds.
      let srcDir = tmp / "payload"
      createDir(srcDir)
      writeFile(srcDir / "file.txt", "hello")

      let b = newLimaBackend(limactlCmd = shim)
      let vm = VmHandle(backend: b, name: "testvm", baseline: "baseline")
      b.copyToGuest(vm, srcDir, "/opt/payload")

      let logText = readFile(log)
      # In-guest extraction goes through `limactl shell ... tar -xf - -C`.
      check "'tar' '-xf' '-' '-C'" in logText
      # It must NOT fall back to scp -r.
      check "--recursive" notin logText
      check "copy" notin logText

    test "copyToGuest of a single file still uses limactl copy":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      writeShim(shim, log)
      let srcFile = tmp / "payload.txt"
      writeFile(srcFile, "hello")

      let b = newLimaBackend(limactlCmd = shim)
      let vm = VmHandle(backend: b, name: "testvm", baseline: "baseline")
      b.copyToGuest(vm, srcFile, "/tmp/payload.txt")

      let logText = readFile(log)
      check "copy --backend=scp" in logText
      # A single file is not tar-streamed.
      check "'tar' '-xf'" notin logText
