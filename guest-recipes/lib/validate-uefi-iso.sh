#!/usr/bin/env bash
# validate-uefi-iso.sh — shared helper sourced by the Windows recipe
# fetch-iso.sh scripts to fail fast on a BIOS-only install ISO.
#
# WHY THIS EXISTS
# ---------------
# The libvirt Win11 domain (and the UTM/qemu virt Win11-on-ARM domain)
# is UEFI-only: it boots OVMF/AAVMF and expects the install media to
# carry a UEFI (EFI) El Torito boot record. A BIOS-only ISO — one whose
# only El Torito boot image has platform BIOS — boots to nothing: OVMF
# finds no bootable UEFI option and silently drops to the UEFI shell,
# and virt-install then sits on `--wait` for ~90 minutes before timing
# out with no actionable cause. This exact failure mode is documented in
# src/vm_harness/backends/libvirt.nim's provisionBaseline qcow2 branch.
#
# This helper detects the condition up front. A good Win11 ISO reports an
# El Torito image with platform EFI/UEFI (an efisys.bin boot image); a
# BIOS-only ISO reports only platform BIOS.
#
# PUBLIC API
# ----------
#   uefi_report_indicates_uefi [REPORT]
#       Pure decision function. Reads an El Torito report (from $1 if
#       given, otherwise stdin) produced by `xorriso -report_el_torito`
#       (plain or as_mkisofs form) or an isoinfo/iso-info dump. Returns 0
#       when the report indicates a UEFI (EFI) El Torito boot image, 1
#       otherwise. No side effects — this is what the unit test exercises.
#
#   validate_uefi_iso ISO_PATH [LABEL]
#       Inspect ISO_PATH with the best available tool (prefer xorriso,
#       fall back to isoinfo/iso-info) and hard-fail (return 1) with an
#       actionable message when the ISO has no UEFI El Torito record. When
#       NO inspection tool is installed, prints a WARNING and returns 0
#       (validation skipped — missing tooling is never a hard failure).
#       LABEL defaults to ISO_PATH and is used in messages.

# ---------------------------------------------------------------------------
# Pure decision function — unit-testable, no I/O beyond reading its input.
uefi_report_indicates_uefi() {
  local report
  if [ "$#" -gt 0 ]; then
    report="$1"
  else
    report="$(cat)"
  fi

  # Strategy 1 — `xorriso -indev <iso> -report_el_torito plain`.
  # Each boot image is printed as an "El Torito boot img" line whose
  # "Pltf" (platform) column is BIOS or UEFI. A UEFI-bootable ISO has at
  # least one UEFI image; a BIOS-only ISO only ever shows BIOS. Example:
  #   El Torito boot img :   1  BIOS  y   none  0x0000  0x00  8      27
  #   El Torito boot img :   2  UEFI  y   none  0x0000  0x00  5760   34
  if printf '%s\n' "$report" \
       | grep -Eiq 'el[ -]?torito[ -]?boot[ -]?img.*[[:space:]]UEFI([[:space:]]|$)'; then
    return 0
  fi

  # Strategy 2 — `xorriso -indev <iso> -report_el_torito as_mkisofs`.
  # An EFI El Torito image is emitted as a `-eltorito-alt-boot` section
  # carrying an EFI boot image (`-e <img>` / `--efi-boot <img>`) or an
  # explicit EFI platform selector. None of these tokens appear for a
  # BIOS-only ISO. Example:
  #   -eltorito-boot boot/etfsboot.com -no-emul-boot ...
  #   -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot
  if printf '%s\n' "$report" \
       | grep -Eq '(^|[[:space:]])-eltorito-alt-boot([[:space:]]|$)'; then
    if printf '%s\n' "$report" \
         | grep -Eiq '(^|[[:space:]])(-e|--efi-boot)[[:space:]]|-eltorito-platform[[:space:]]+(0xef|efi|uefi)|efi[^[:space:]]*\.(bin|img|efi)'; then
      return 0
    fi
  fi

  # Strategy 3 — generic textual fallback (isoinfo/iso-info or an xorriso
  # form that spells out the platform). Accept only an El Torito record
  # that explicitly names a UEFI/EFI platform, so a stray "efi" token in
  # some unrelated field can't produce a false accept.
  if printf '%s\n' "$report" \
       | grep -Eiq 'el[ -]?torito[^[:cntrl:]]*platform[^[:cntrl:]]*\b(uefi|efi)\b|platform[[:space:]]*id[^[:cntrl:]]*0xef'; then
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Driver — inspect a real ISO and hard-fail on a BIOS-only image.
validate_uefi_iso() {
  local iso="$1"
  local label="${2:-$1}"
  local report="" tool=""

  if command -v xorriso >/dev/null 2>&1; then
    tool="xorriso"
    report="$(xorriso -indev "$iso" -report_el_torito plain 2>/dev/null || true)"
    if [ -z "$report" ]; then
      report="$(xorriso -indev "$iso" -report_el_torito as_mkisofs 2>/dev/null || true)"
    fi
  elif command -v isoinfo >/dev/null 2>&1; then
    tool="isoinfo"
    report="$(isoinfo -d -i "$iso" 2>/dev/null || true)"
  elif command -v iso-info >/dev/null 2>&1; then
    tool="iso-info"
    report="$(iso-info "$iso" 2>/dev/null || true)"
  fi

  if [ -z "$tool" ]; then
    echo "validate-uefi-iso: WARNING — no ISO inspection tool" \
         "(xorriso/isoinfo/iso-info) found on PATH; skipping the UEFI" \
         "El Torito validation of ${label}." >&2
    echo "validate-uefi-iso: install xorriso (it is provided by the" \
         "vm-harness dev shell) to enable this check." >&2
    return 0
  fi

  if uefi_report_indicates_uefi "$report"; then
    echo "validate-uefi-iso: OK — ${label} carries a UEFI (EFI) El Torito" \
         "boot record (detected via ${tool})."
    return 0
  fi

  cat >&2 <<EOF
validate-uefi-iso: ERROR — ${label} has no UEFI (EFI) El Torito boot
record — this ISO is BIOS-boot only and will NOT boot the UEFI q35/virt
Win11 domain (OVMF drops to the UEFI shell, and virt-install then stalls
on --wait for ~90 minutes with no clear cause).

Supply a UEFI-bootable Windows 11 ISO instead — a stock Microsoft ISO
downloaded from microsoft.com carries both BIOS and UEFI El Torito boot
records and works out of the box. (Detected via ${tool}.)
EOF
  return 1
}
