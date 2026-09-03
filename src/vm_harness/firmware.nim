## Shared UEFI (OVMF / edk2) firmware resolution.
##
## Two backends need the same answer to "where is OVMF on this host?":
## ``backends/libvirt.nim`` hands the pair to ``virt-install``'s
## ``--boot loader=…,nvram.template=…``, and ``backends/qemu_boot.nim``
## hands it to QEMU's ``-drive if=pflash`` pair. Keeping one
## implementation means a host-layout fix (a new distro path, a new
## nixpkgs store layout) lands once instead of drifting between the two.
##
## Resolution order, highest precedence first:
##
## 1. An explicit caller-supplied pair (the libvirt backend reads it
##    from ``BootMediaSpec.extra["uefiLoader"|"uefiNvramTemplate"]``;
##    the QEMU backend from the same keys).
## 2. ``$VMH_OVMF_CODE`` / ``$VMH_OVMF_VARS``.
## 3. Conventional distro locations, including the NixOS libvirtd
##    ``/run/libvirt/nix-ovmf`` drop-in.
## 4. On Linux only, the newest ``/nix/store/*-OVMF-*-fd/FV/`` pair.
##
## A *partial* pair is always an error rather than a silent fallback:
## booting UEFI with someone else's NVRAM template is how a gate ends up
## asserting against firmware it did not intend to test.

import std/[algorithm, os, sequtils, strutils]

type
  OvmfPair* = tuple[loader, nvram: string]
    ## ``loader`` is the read-only OVMF code image; ``nvram`` is the
    ## *template* for the writable variable store. Callers that need a
    ## writable store must copy ``nvram`` per VM — never hand the
    ## template itself to QEMU as a writable pflash drive.

const
  OvmfLoaderEnvVar* = "VMH_OVMF_CODE"
  OvmfNvramEnvVar* = "VMH_OVMF_VARS"

  OvmfConventionalPairs* = [
    # NixOS libvirtd assembles this directory from the OVMF package. The
    # x86_64 code image is paired with the *i386* variable template —
    # that is edk2's own naming, not a mistake.
    ("/run/libvirt/nix-ovmf/edk2-x86_64-code.fd",
     "/run/libvirt/nix-ovmf/edk2-i386-vars.fd"),
    ("/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd"),
    ("/usr/share/edk2/ovmf/OVMF_CODE.fd",
     "/usr/share/edk2/ovmf/OVMF_VARS.fd"),
    ("/usr/share/edk2/x64/OVMF_CODE.fd",
     "/usr/share/edk2/x64/OVMF_VARS.fd"),
  ]

proc acceptOvmfPair*(loader, nvram: string): bool =
  ## ``true`` when both halves are present and exist on disk; ``false``
  ## when both are empty ("nothing configured at this precedence
  ## level"). Raises when exactly one half is supplied, or when a
  ## supplied path does not exist.
  if loader.len == 0 and nvram.len == 0:
    return false
  if loader.len == 0 or nvram.len == 0:
    raise newException(ValueError,
      "UEFI boot requires both a loader and an NVRAM template")
  if not fileExists(loader):
    raise newException(IOError, "UEFI loader does not exist: " & loader)
  if not fileExists(nvram):
    raise newException(IOError,
      "UEFI NVRAM template does not exist: " & nvram)
  true

proc resolveOvmfPair*(explicitLoader = "", explicitNvram = ""): OvmfPair =
  ## Resolve the (code, vars-template) pair per the order documented in
  ## this module's header. Returns ``("", "")`` when nothing was found,
  ## which lets a caller that has its own fallback (virt-install's
  ## native firmware descriptors) take it.
  if acceptOvmfPair(explicitLoader, explicitNvram):
    return (explicitLoader, explicitNvram)

  let envLoader = getEnv(OvmfLoaderEnvVar)
  let envNvram = getEnv(OvmfNvramEnvVar)
  if acceptOvmfPair(envLoader, envNvram):
    return (envLoader, envNvram)

  for pair in OvmfConventionalPairs:
    if fileExists(pair[0]) and fileExists(pair[1]):
      return pair

  when defined(linux):
    var nixLoaders = toSeq(
      walkPattern("/nix/store/*-OVMF-*-fd/FV/OVMF_CODE.fd"))
    nixLoaders.sort()
    for loader in nixLoaders.reversed():
      let nvram = loader.parentDir / "OVMF_VARS.fd"
      if fileExists(nvram):
        return (loader, nvram)

  ("", "")

proc describeOvmfSearch*(): string =
  ## Human-readable remediation text for "no OVMF found". Used in the
  ## error a boot gate reports, so the failure names the fix instead of
  ## just the symptom.
  var lines = @[
    "No OVMF/edk2 firmware pair was found on this host.",
    "Set " & OvmfLoaderEnvVar & " and " & OvmfNvramEnvVar &
      " to an explicit pair, or install OVMF (it is in the reprobuild " &
      "and vm-harness dev shells as pkgs.OVMF.fd).",
    "Locations searched:"]
  for pair in OvmfConventionalPairs:
    lines.add("  - " & pair[0] & " + " & pair[1])
  when defined(linux):
    lines.add("  - /nix/store/*-OVMF-*-fd/FV/OVMF_{CODE,VARS}.fd")
  lines.join("\n")
