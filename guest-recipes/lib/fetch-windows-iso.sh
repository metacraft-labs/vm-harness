#!/usr/bin/env bash
# fetch-windows-iso.sh — obtain a Microsoft Windows install ISO without a
# browser, by driving Microsoft's own download API through Fido.
#
# WHY THIS EXISTS
#
# Until now both Windows recipes refused to fetch: `fetch-iso.sh` validated
# that an operator-supplied ISO existed and printed manual instructions
# otherwise ("Bring your own; the harness does not host Microsoft media").
# That left a hand-carried artifact in the middle of an otherwise declarative
# pipeline — the reason a second Windows host could not be stood up without a
# human at a browser.
#
# WHY FIDO, AND WHY NOT REIMPLEMENT IT
#
# Microsoft has no stable no-login URL, but it does have an API, and two
# projects drive it: Mido (MIT, used by quickemu) and Fido (GPL-3.0, by
# Rufus's author, who did the original reverse engineering).
#
# Measured 2026-08-20 from win-ci-bare-001:
#
#   * Mido's endpoint — /en-US/api/controls/contentinclude/html?pageId=... —
#     returns HTTP 404. Microsoft retired it; Mido issue #24 has been open
#     about this since 2024-12-26.
#   * Fido's endpoint — /software-download-connector/api/... — returns 200
#     and yields a real link on software.download.prss.microsoft.com.
#
# Reimplementing under MIT was considered and rejected. The connector API is
# gated by an anti-bot handshake (an ov-df.microsoft.com challenge: fetch
# mdt.js, extract `w` and `rticks`, reply with those plus a current epoch)
# BEFORE it will issue links; skipping it yields
# `ErrorSettings.SentinelReject`. That handshake is a deliberately hostile
# moving target, and owning it is precisely what has left Mido broken for
# over a year. Fido is maintained by the person who reverse-engineered it.
#
# LICENSING. Fido is GPL-3.0 and vm-harness is MIT. This script INVOKES it as
# an external tool — the same relationship as calling `gcc` — and never
# vendors, commits, or redistributes its source. Do not check Fido.ps1 into
# this repository.
#
# RATE LIMITING IS NORMAL, NOT AN ERROR
#
# Microsoft rate-limits link generation aggressively. Observed: one success,
# then `Sentinel marked this request as rejected` on every attempt for the
# following ten-plus minutes, triggered by nothing more than a handful of
# probes from one IP. Two consequences shape this script:
#
#   1. A rejection is retried with backoff and, on exhaustion, degrades to
#      the manual instructions — it is never treated as a hard failure.
#   2. **The link is fetched ONCE and cached.** Links are valid ~24h, so a
#      download that dies at 90% must resume against the SAME url rather
#      than ask for a new one. Regenerating on every retry is what turns a
#      transient limit into a permanent one.
#
# Requires: curl, sha256sum, and PowerShell (pwsh or powershell.exe).
#
# Usage:
#   ./fetch-windows-iso.sh --output /storage/iso/Win11_x64.iso
#   ./fetch-windows-iso.sh --arch arm64 --edition Pro --output ...
#
# Environment:
#   VMH_WINDOWS_ISO_SHA256   expected sha256; verified and enforced when set.
#                            When unset the computed digest is written to
#                            <output>.sha256 so the next build can pin it.
#   VMH_FIDO_COMMIT          override the pinned Fido commit (see below).
#   VMH_FIDO_SHA256          override the expected Fido.ps1 digest.
#   VMH_ISO_URL_TTL_HOURS    cached-link lifetime (default 20; Microsoft's
#                            own validity is ~24h, so we expire earlier).

set -euo pipefail

# Fido is pinned by COMMIT, not by branch: `master` is a moving ref, and a
# script that fetches and then executes a moving ref is an unpinned remote
# code dependency. The digest is checked before it is ever run.
FIDO_COMMIT="${VMH_FIDO_COMMIT:-3d47260b8915385c58e20c73e24b36e9a9536f3f}"
FIDO_SHA256="${VMH_FIDO_SHA256:-24c86067fa399d2fd75ef0693a2ec79ca8db162827f808caac03541cbf640c13}"
FIDO_URL="https://raw.githubusercontent.com/pbatard/Fido/${FIDO_COMMIT}/Fido.ps1"

WIN_VER="11"
ARCH="x64"
EDITION="Pro"
LANG_NAME="English"
RELEASE="Latest"
OUTPUT=""
URL_TTL_HOURS="${VMH_ISO_URL_TTL_HOURS:-20}"
MAX_ATTEMPTS=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --win)      WIN_VER="$2"; shift 2;;
    --arch)     ARCH="$2"; shift 2;;
    --edition)  EDITION="$2"; shift 2;;
    --lang)     LANG_NAME="$2"; shift 2;;
    --release)  RELEASE="$2"; shift 2;;
    --output)   OUTPUT="$2"; shift 2;;
    --help|-h)  sed -n '2,60p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "fetch-windows-iso: unrecognized arg '$1'" >&2; exit 1;;
  esac
done

if [[ -z "${OUTPUT}" ]]; then
  echo "fetch-windows-iso: --output PATH is required" >&2
  exit 1
fi

OUT_DIR="$(dirname -- "${OUTPUT}")"
mkdir -p "${OUT_DIR}"
URL_CACHE="${OUTPUT}.url"
PART="${OUTPUT}.part"

log() { echo "fetch-windows-iso: $*"; }

verify_digest() {
  # $1 = file, $2 = expected. Returns 0 when it matches (or nothing expected).
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [[ -n "${2:-}" && "${got}" != "$2" ]]; then
    echo "  expected ${2}" >&2
    echo "  actual   ${got}" >&2
    return 1
  fi
  echo "${got}"
}

# ---------------------------------------------------------------------------
# 0. Already have it?
# ---------------------------------------------------------------------------
if [[ -f "${OUTPUT}" ]]; then
  if [[ -n "${VMH_WINDOWS_ISO_SHA256:-}" ]]; then
    if verify_digest "${OUTPUT}" "${VMH_WINDOWS_ISO_SHA256}" >/dev/null; then
      log "ISO already present and matches the pinned digest: ${OUTPUT}"
      exit 0
    fi
    log "WARNING: ${OUTPUT} exists but does NOT match VMH_WINDOWS_ISO_SHA256."
    log "         Refusing to overwrite. Move it aside or clear the pin."
    exit 1
  fi
  log "ISO already present (no digest pinned): ${OUTPUT}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Locate PowerShell.
# ---------------------------------------------------------------------------
PS_EXE="$(command -v pwsh || command -v powershell.exe || true)"
if [[ -z "${PS_EXE}" ]]; then
  cat >&2 <<'EOF'
fetch-windows-iso: no PowerShell found (need `pwsh` or `powershell.exe`).

Fido is a PowerShell script. On Linux install PowerShell Core (nixpkgs:
`powershell`), or supply the ISO yourself and point the recipe at it.
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Obtain a download link — from cache when fresh, else via Fido.
# ---------------------------------------------------------------------------
ISO_URL=""
if [[ -f "${URL_CACHE}" ]]; then
  # Reuse a cached link while it is plausibly still valid. This is the
  # difference between "resume a 7 GB download" and "ask Microsoft for a new
  # link and get rejected".
  cache_age_h=$(( ( $(date +%s) - $(date -r "${URL_CACHE}" +%s) ) / 3600 ))
  if (( cache_age_h < URL_TTL_HOURS )); then
    ISO_URL="$(cat "${URL_CACHE}")"
    log "reusing cached download link (${cache_age_h}h old, TTL ${URL_TTL_HOURS}h)"
  else
    log "cached link is ${cache_age_h}h old (TTL ${URL_TTL_HOURS}h) — discarding"
    rm -f "${URL_CACHE}"
    # A stale link means the partial download can no longer be resumed
    # against it; a fresh link is a different signed URL for the same bytes,
    # and curl -C - against it would splice two different responses.
    [[ -f "${PART}" ]] && { log "discarding stale partial download"; rm -f "${PART}"; }
  fi
fi

if [[ -z "${ISO_URL}" ]]; then
  FIDO_LOCAL="${OUT_DIR}/.fido-${FIDO_COMMIT:0:12}.ps1"
  if [[ ! -f "${FIDO_LOCAL}" ]]; then
    log "fetching Fido @ ${FIDO_COMMIT:0:12}"
    curl -sL --fail --proto '=https' --tlsv1.2 -o "${FIDO_LOCAL}" "${FIDO_URL}" || {
      echo "fetch-windows-iso: could not download Fido from ${FIDO_URL}" >&2
      exit 1
    }
  fi
  if ! verify_digest "${FIDO_LOCAL}" "${FIDO_SHA256}" >/dev/null; then
    rm -f "${FIDO_LOCAL}"
    cat >&2 <<EOF
fetch-windows-iso: Fido.ps1 digest mismatch — REFUSING TO RUN IT.

This script downloads and executes Fido, so the digest is the only thing
standing between a compromised or substituted upstream and code execution
on this host. A mismatch means the pinned commit no longer serves the
bytes we expect. Do not "fix" this by updating VMH_FIDO_SHA256 without
first establishing why it changed.
EOF
    exit 1
  fi

  attempt=1
  backoff=30
  while (( attempt <= MAX_ATTEMPTS )); do
    log "requesting a download link (attempt ${attempt}/${MAX_ATTEMPTS})"
    set +e
    raw="$("${PS_EXE}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
             -File "${FIDO_LOCAL}" \
             -Win "${WIN_VER}" -Rel "${RELEASE}" -Ed "${EDITION}" \
             -Lang "${LANG_NAME}" -Arch "${ARCH}" -GetUrl 2>&1)"
    set -e
    candidate="$(printf '%s\n' "${raw}" | tr -d '\r' | grep -E '^https://' | tail -1 || true)"
    if [[ -n "${candidate}" ]]; then
      ISO_URL="${candidate}"
      printf '%s\n' "${ISO_URL}" > "${URL_CACHE}"
      log "got a link (cached at ${URL_CACHE})"
      break
    fi
    # Rate limiting is the expected failure, not an exceptional one.
    if printf '%s' "${raw}" | grep -qi 'sentinel'; then
      log "Microsoft rate-limited the request (Sentinel). Backing off ${backoff}s."
    else
      log "no link returned: $(printf '%s' "${raw}" | tr -d '\r' | tail -1)"
    fi
    (( attempt++ ))
    if (( attempt <= MAX_ATTEMPTS )); then
      sleep "${backoff}"
      backoff=$(( backoff * 2 ))
    fi
  done
fi

if [[ -z "${ISO_URL}" ]]; then
  cat >&2 <<EOF

fetch-windows-iso: could not obtain a download link after ${MAX_ATTEMPTS} attempts.

This is usually Microsoft's rate limiter rather than a broken script; it
clears on its own, historically in tens of minutes. Either re-run later, or
supply the ISO by hand:

  1. Open https://www.microsoft.com/software-download/windows${WIN_VER}
  2. Download the multi-edition ${ARCH} ISO.
  3. Save it as ${OUTPUT}
  4. Re-run the recipe.

EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Download, resumably.
# ---------------------------------------------------------------------------
log "downloading to ${PART}"
curl -L --fail --proto '=https' --tlsv1.2 \
     --retry 5 --retry-delay 10 --retry-connrefused \
     -C - --progress-bar \
     -o "${PART}" "${ISO_URL}"

mv -f "${PART}" "${OUTPUT}"

# ---------------------------------------------------------------------------
# 4. Digest: enforce a pin when given, otherwise record one.
# ---------------------------------------------------------------------------
if [[ -n "${VMH_WINDOWS_ISO_SHA256:-}" ]]; then
  if ! digest="$(verify_digest "${OUTPUT}" "${VMH_WINDOWS_ISO_SHA256}")"; then
    echo "fetch-windows-iso: digest mismatch — the download is NOT what was pinned." >&2
    exit 1
  fi
  log "digest matches the pin: ${digest}"
else
  digest="$(verify_digest "${OUTPUT}" "")"
  printf '%s  %s\n' "${digest}" "$(basename -- "${OUTPUT}")" > "${OUTPUT}.sha256"
  log "digest recorded at ${OUTPUT}.sha256: ${digest}"
  log "PIN IT: export VMH_WINDOWS_ISO_SHA256=${digest}"
  log "        Microsoft serves a rolling 'latest', so an unpinned fetch is"
  log "        not reproducible — two hosts built weeks apart get different media."
fi

log "done: ${OUTPUT}"
