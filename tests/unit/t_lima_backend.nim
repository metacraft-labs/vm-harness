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

    test "copyFromGuest of a directory tars in-guest, copies one file, untars on host":
      # Mirrors the copyToGuest directory test in reverse. The shim
      # reports the guest source IS a directory (``test -d`` exit 0),
      # records the in-guest ``tar -cf <tempfile>`` archive step, and
      # for the single-file ``limactl copy`` of that archive out it
      # produces a REAL tar from a staged tree so the host-side
      # ``tar -xf`` reconstructs the directory. We assert both the
      # constructed commands AND the reconstructed tree on disk.
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      # Staged tree the shim tars out: STAGE/payload/file.txt.
      let stage = tmp / "stage"
      createDir(stage / "payload")
      writeFile(stage / "payload" / "file.txt", "hello")
      writeFile(shim,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & log & "'\n" &
        "case \"$1\" in\n" &
        "  shell)\n" &
        "    case \"$*\" in\n" &
        "      *\"'test' '-d'\"*) exit 0 ;;\n" &
        "    esac\n" &
        "    exit 0 ;;\n" &
        "  copy)\n" &
        "    tar -cf \"$4\" -C '" & stage & "' payload\n" &
        "    exit 0 ;;\n" &
        "esac\n" &
        "exit 0\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})

      let b = newLimaBackend(limactlCmd = shim)
      let vm = VmHandle(backend: b, name: "testvm", baseline: "baseline")
      let dest = tmp / "pulled" / "payload"
      b.copyFromGuest(vm, "/opt/payload", dest)

      let logText = readFile(log)
      # Directory detection probe.
      check "'test' '-d'" in logText
      # In-guest archive to a temp .tar FILE (not streamed over stdout).
      check "'tar' '-cf'" in logText
      check "/tmp/vm-harness-pull" in logText
      # The archive is pulled out with a single-file limactl copy — NOT
      # ``limactl copy --recursive`` (the old scp -r path we replaced).
      check "copy --backend=scp" in logText
      check "--recursive" notin logText
      # The tree was reconstructed on the host at <parent>/<base>.
      check dirExists(dest)
      check readFile(dest / "file.txt") == "hello"

    test "copyFromGuest of a single file still uses limactl copy (no tar)":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      # ``test -d`` reports NOT a directory (exit 1) so the file path is
      # taken; every other invocation records and exits 0.
      writeFile(shim,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & log & "'\n" &
        "case \"$1\" in\n" &
        "  shell)\n" &
        "    case \"$*\" in\n" &
        "      *\"'test' '-d'\"*) exit 1 ;;\n" &
        "    esac\n" &
        "    exit 0 ;;\n" &
        "esac\n" &
        "exit 0\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})

      let b = newLimaBackend(limactlCmd = shim)
      let vm = VmHandle(backend: b, name: "testvm", baseline: "baseline")
      b.copyFromGuest(vm, "/etc/hostname", tmp / "hostname")

      let logText = readFile(log)
      # Single FILE keeps the plain (recursive scp-safe) limactl copy.
      check "copy --backend=scp" in logText
      check "--recursive" in logText
      # No tar path for a single file.
      check "'tar' '-cf'" notin logText

    test "provisionScripts bake a provision: block into the generated template":
      # writeTemplateFile is internal; observe its output via the temp
      # .yaml path handed to ``limactl create`` — the shim copies that
      # file aside so we can read the generated YAML.
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      let captured = tmp / "captured.yaml"
      writeFile(shim,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & log & "'\n" &
        "if [ \"$1\" = create ]; then\n" &
        "  for a in \"$@\"; do templ=\"$a\"; done\n" &
        "  cp \"$templ\" '" & captured & "' 2>/dev/null || true\n" &
        "fi\n" &
        "exit 0\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})

      let script = "#!/bin/sh\napt-get update\napt-get install -y ripgrep\n"
      let b = newLimaBackend(limactlCmd = shim,
                             provisionScripts = @[script])
      discard b.revertToBaseline("baseline")

      let yaml = readFile(captured)
      check "\nprovision:\n" in yaml
      check "- mode: system" in yaml
      check "  script: |" in yaml
      # Body lines are indented into the block scalar.
      check "    apt-get install -y ripgrep" in yaml

    test "no provisionScripts leaves the template byte-identical to the default":
      let tmp = createTempDir("vmh-lima-unit-", "")
      defer: removeDir(tmp)
      let log = tmp / "limactl.log"
      let shim = tmp / "limactl"
      let captured = tmp / "captured.yaml"
      writeFile(shim,
        "#!/bin/sh\n" &
        "printf '%s\\n' \"$*\" >> '" & log & "'\n" &
        "if [ \"$1\" = create ]; then\n" &
        "  for a in \"$@\"; do templ=\"$a\"; done\n" &
        "  cp \"$templ\" '" & captured & "' 2>/dev/null || true\n" &
        "fi\n" &
        "exit 0\n")
      setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})

      let b = newLimaBackend(limactlCmd = shim)  # no provision scripts
      discard b.revertToBaseline("baseline")

      let yaml = readFile(captured)
      check "provision:" notin yaml
      # The generated template equals the embedded default verbatim.
      check yaml == DefaultLimaTemplate
