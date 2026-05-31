#!/bin/sh
# vm-harness Tier-1 in-guest POSIX runner.
#
# Generic primitives only — exec a command, install/uninstall an argv-trace
# shim, write rows to RESULT.txt, finalize with the DONE sentinel. Project-
# specific orchestration (reprobuild gates, AH test commands) lives in the
# consumer's repo, NOT here.
#
# Used by the WSL, Tart-Linux, Tart-macOS, libvirt-Linux, and Lima backends.
#
# Subcommand surface (mirrored by windows.ps1):
#
#   exec <output-dir> [--env KEY=VAL ...] -- <cmd...>
#     Runs <cmd>, captures stdout+stderr to <output-dir>/02-<basename>-run.txt
#     with the exit code recorded in a leading header.
#
#   install-trace-shim <real-binary> <log-path>
#     Replaces the named binary with a wrapper that records argv to
#     <log-path>, then exec's the original via .real backup.
#
#   uninstall-trace-shim <real-binary>
#     Restores the original binary.
#
#   write-result <output-dir> <step-name> <status> [elapsed_ms]
#     Appends a step row to <output-dir>/RESULT.txt.
#
#   finalize <output-dir> <verdict>
#     Writes the verdict row and creates the DONE sentinel.

set -eu

VM_HARNESS_SHIM_TEMPLATE='#!/bin/sh
printf "%s\t%s\n" "$(date +%s%N 2>/dev/null || date +%s)" "$0 $*" >> "@TRACE_LOG_PATH@"
exec "@REAL_BIN_PATH@" "$@"
'

usage() {
  cat >&2 <<EOF
Usage: $0 <subcommand> [args]
Subcommands:
  exec <output-dir> [--env KEY=VAL ...] -- <cmd...>
  install-trace-shim <real-binary> <log-path>
  uninstall-trace-shim <real-binary>
  write-result <output-dir> <step-name> <status> [elapsed_ms]
  finalize <output-dir> <verdict>
EOF
  exit 2
}

safe_name() {
  # Sanitize argv0 basename for use as a file name.
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Resolve which binary on PATH owns <name>, while skipping any directory
# that already holds our shim wrapper (so re-runs don't recurse).
find_real_binary() {
  name="$1"
  # Prefer the canonical /usr/bin path; fall back to PATH lookup.
  for cand in "/usr/bin/$name" "/usr/local/bin/$name" "/opt/bin/$name"; do
    if [ -x "$cand" ] && [ ! -e "$cand.real" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  PATH_BIN=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$PATH_BIN" ]; then
    printf '%s' "$PATH_BIN"
    return 0
  fi
  return 1
}

cmd_exec() {
  if [ "$#" -lt 1 ]; then usage; fi
  outdir="$1"; shift
  mkdir -p "$outdir"
  env_args=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        shift
        env_args="$env_args $1"
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  if [ "$#" -lt 1 ]; then
    echo "exec: no command provided" >&2
    exit 2
  fi
  base=$(safe_name "$(basename "$1")")
  outfile="$outdir/02-${base}-run.txt"
  i=1
  while [ -e "$outfile" ]; do
    outfile="$outdir/02-${base}-${i}-run.txt"
    i=$((i + 1))
  done
  start_ns=$(date +%s%N 2>/dev/null || echo 0)
  {
    printf '# cmd:'
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
  } > "$outfile"
  # shellcheck disable=SC2086
  if [ -n "$env_args" ]; then
    /usr/bin/env $env_args "$@" >> "$outfile" 2>&1 || rc=$?
  else
    "$@" >> "$outfile" 2>&1 || rc=$?
  fi
  rc=${rc:-0}
  end_ns=$(date +%s%N 2>/dev/null || echo 0)
  if [ "$start_ns" -ne 0 ] && [ "$end_ns" -ne 0 ]; then
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  else
    elapsed_ms=-1
  fi
  printf '# exit_code: %s\n# elapsed_ms: %s\n' "$rc" "$elapsed_ms" >> "$outfile"
  exit "$rc"
}

cmd_install_trace_shim() {
  if [ "$#" -lt 2 ]; then usage; fi
  name="$1"; logpath="$2"
  real=$(find_real_binary "$name") || {
    echo "install-trace-shim: cannot find $name on PATH" >&2
    exit 1
  }
  if [ ! -e "$real.real" ]; then
    cp -p "$real" "$real.real"
  fi
  tmp="${real}.shim.tmp.$$"
  printf '%s' "$VM_HARNESS_SHIM_TEMPLATE" |
    sed "s#@TRACE_LOG_PATH@#$logpath#g; s#@REAL_BIN_PATH@#${real}.real#g" \
      > "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$real"
  # Ensure log path is writable before first invocation.
  : > "$logpath" 2>/dev/null || true
}

cmd_uninstall_trace_shim() {
  if [ "$#" -lt 1 ]; then usage; fi
  name="$1"
  # Try the same set of canonical locations as install.
  for cand in "/usr/bin/$name" "/usr/local/bin/$name" "/opt/bin/$name"; do
    if [ -e "$cand.real" ]; then
      mv -f "$cand.real" "$cand"
      return 0
    fi
  done
  # Last resort: rely on PATH and check for a sibling .real.
  PATH_BIN=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$PATH_BIN" ] && [ -e "$PATH_BIN.real" ]; then
    mv -f "$PATH_BIN.real" "$PATH_BIN"
    return 0
  fi
  # No shim to uninstall; treat as success (idempotent).
  return 0
}

cmd_write_result() {
  if [ "$#" -lt 3 ]; then usage; fi
  outdir="$1"; step="$2"; status="$3"; elapsed="${4:-}"
  mkdir -p "$outdir"
  if [ -n "$elapsed" ]; then
    printf 'step: %s  status: %s  elapsed_ms: %s\n' "$step" "$status" "$elapsed" \
      >> "$outdir/RESULT.txt"
  else
    printf 'step: %s  status: %s\n' "$step" "$status" >> "$outdir/RESULT.txt"
  fi
}

cmd_finalize() {
  if [ "$#" -lt 2 ]; then usage; fi
  outdir="$1"; verdict="$2"
  mkdir -p "$outdir"
  printf 'verdict: %s\n' "$verdict" >> "$outdir/RESULT.txt"
  printf '%s\n' "$verdict" > "$outdir/DONE"
}

if [ "$#" -lt 1 ]; then usage; fi
sub="$1"; shift
case "$sub" in
  exec) cmd_exec "$@" ;;
  install-trace-shim) cmd_install_trace_shim "$@" ;;
  uninstall-trace-shim) cmd_uninstall_trace_shim "$@" ;;
  write-result) cmd_write_result "$@" ;;
  finalize) cmd_finalize "$@" ;;
  *) usage ;;
esac
