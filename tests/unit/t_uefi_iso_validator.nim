## Unit test for the pure El Torito UEFI-detection logic in
## ``guest-recipes/lib/validate-uefi-iso.sh``.
##
## MOCK JUSTIFICATION (per repo policy): no mocks. This test exercises
## the REAL shell function ``uefi_report_indicates_uefi`` by sourcing the
## actual library and piping representative ``xorriso -report_el_torito``
## output into it — the same code path fetch-iso.sh runs. We cannot ship
## real multi-GB Windows ISOs, so we feed the tool's *report text* (the
## proven signal: a UEFI ISO shows an El Torito image with platform
## EFI/UEFI, a BIOS-only ISO shows only platform BIOS) and assert the
## accept/reject decision. The sample reports below are transcribed from
## real xorriso output shapes for a stock Win11 ISO (BIOS+UEFI) vs a
## BIOS-only ISO. No process spawning is mocked (real ``bash`` runs).

import std/[os, osproc, streams, unittest]

# Locate the repo root (walk up until guest-recipes/ appears) so the test
# runs regardless of the invoking cwd.
proc repoRoot(): string =
  var d = currentSourcePath().parentDir
  for _ in 0 .. 6:
    if dirExists(d / "guest-recipes"):
      return d
    d = d.parentDir
  raise newException(IOError, "could not locate repo root from " &
    currentSourcePath())

let libPath = repoRoot() / "guest-recipes" / "lib" / "validate-uefi-iso.sh"

## Run ``uefi_report_indicates_uefi`` against a report on stdin; return
## the shell exit code (0 == accept/UEFI present, 1 == reject/BIOS-only).
proc decide(report: string): int =
  let script = ". '" & libPath & "'; uefi_report_indicates_uefi"
  let p = startProcess("bash", args = @["-c", script],
                       options = {poUsePath, poStdErrToStdOut})
  let s = p.inputStream
  s.write(report)
  s.close()
  result = p.waitForExit()
  p.close()

# --- Sample reports -------------------------------------------------------

# A stock Win11 ISO: `xorriso -indev win11.iso -report_el_torito plain`.
# Two El Torito boot images — one BIOS, one UEFI.
const Win11PlainBiosPlusUefi = """
El Torito catalog  : 20  2
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00  8             27
El Torito boot img :   2  UEFI  y   none  0x0000  0x00  5760          35
"""

# A BIOS-only ISO in the same `plain` form — only a BIOS boot image.
const BiosOnlyPlain = """
El Torito catalog  : 20  1
El Torito images   :   N  Pltf  B   Emul  Ld_seg  Hdpt  Ldsiz         LBA
El Torito boot img :   1  BIOS  y   none  0x0000  0x00  4             27
"""

# The `as_mkisofs` form for a Win11 ISO: a `-eltorito-alt-boot` section
# carrying the EFI boot image (efisys.bin) via `-e`.
const Win11AsMkisofs = """
-V 'CCCOMA_X64FRE_EN-US_DV9'
-boot-load-size 8 -no-emul-boot -boot-info-table
-eltorito-boot boot/etfsboot.com
-eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot
"""

# The `as_mkisofs` form for a BIOS-only ISO: a single legacy boot image,
# no `-eltorito-alt-boot`, no EFI image.
const BiosOnlyAsMkisofs = """
-V 'SOME_BIOS_ONLY_ISO'
-boot-load-size 4 -no-emul-boot -boot-info-table
-eltorito-boot isolinux/isolinux.bin
"""

# An isoinfo/iso-info style dump that names the EFI platform explicitly.
const IsoinfoUefiPlatform = """
El Torito VD version 1 found, boot catalog is in sector 20
Platform Id 0xEF (UEFI)
Bootoff 23 0x17
"""

suite "UEFI El Torito ISO validator (pure shell decision)":
  test "the validator library exists and is sourceable":
    check fileExists(libPath)

  test "ACCEPT: Win11 plain report with a UEFI boot image":
    check decide(Win11PlainBiosPlusUefi) == 0

  test "REJECT: BIOS-only plain report (no UEFI boot image)":
    check decide(BiosOnlyPlain) == 1

  test "ACCEPT: Win11 as_mkisofs report with -eltorito-alt-boot + EFI image":
    check decide(Win11AsMkisofs) == 0

  test "REJECT: BIOS-only as_mkisofs report (no alt-boot / EFI image)":
    check decide(BiosOnlyAsMkisofs) == 1

  test "ACCEPT: isoinfo dump naming the EFI (0xEF) platform":
    check decide(IsoinfoUefiPlatform) == 0

  test "REJECT: empty report":
    check decide("") == 1
