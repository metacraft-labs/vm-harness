#!/usr/bin/env bash
# build-nixos-runner-image.sh — build the `vmh-nixos-runner` Incus image (HR3).
#
# The NixOS analog of guest-recipes/linux-x64-runner/build-runner-image.sh: a
# NixOS system-container image with the custom-runner FORK staged NATIVELY.
#
# On NixOS the nixpkgs-built runner apphosts (nix PT_INTERP + RPATH) run
# UNMODIFIED — no /lib64 patchelf, no soname shims — provided their nix store
# closure is present in the guest store. This recipe:
#
#   * launches a throwaway container from a NixOS base image
#     (`ah-linux-nixos-base` by default — the same NixOS lxc image the sc15
#     containers use),
#   * imports the runner's nix store closure into the guest /nix/store
#     (nix-store --export | incus exec nix-store --import), so the apphost's
#     PT_INTERP/RPATH resolve natively,
#   * stages the fork _layout (or a `nix build .#packages.default` result)
#     under /home/<user>/actions-runner (the GARM cached-runner path),
#   * creates an unprivileged `runner` user with passwordless sudo,
#   * publishes the result as the `vmh-nixos-runner` alias.
#
# This is a SIDE alias — it never overwrites the live `vmh-linux-runner`. Once
# built it can feed `services.garm-incus-runner-host.image.source` (import the
# exported image) for a NixOS-guest runner fleet.
#
# Blocker A: the runner tree + closure are STREAMED in (cat|incus exec tar /
# nix-store --import over a pipe), never `incus file push`ed.
#
# Usage:
#   ./build-nixos-runner-image.sh
#   VMH_INCUS_CMD="sudo -n incus" VMH_RUNNER_LAYOUT=/path/to/_layout ./build-nixos-runner-image.sh
#   VMH_RUNNER_STORE_PATH=$(nix build .#packages.default --print-out-paths) ./build-nixos-runner-image.sh
#
# Env:
#   VMH_INCUS_CMD          incus invocation            (default: incus)
#   VMH_RUNNER_ALIAS       output image alias           (default: vmh-nixos-runner)
#   VMH_NIXOS_BASE         local NixOS base alias        (default: ah-linux-nixos-base)
#   VMH_RUNNER_USER        unprivileged runner user      (default: runner)
#   VMH_RUNNER_CACHE       in-image runner dir           (default: /home/<user>/actions-runner)
#   VMH_RUNNER_LAYOUT      pre-built fork _layout dir    (mutually exclusive with STORE_PATH)
#   VMH_RUNNER_STORE_PATH  nix-built fork store path     (a buildDotnetModule result; its
#                                                         closure is copied wholesale)
set -euo pipefail

INCUS=(${VMH_INCUS_CMD:-incus})
ALIAS="${VMH_RUNNER_ALIAS:-vmh-nixos-runner}"
NIXOS_BASE="${VMH_NIXOS_BASE:-ah-linux-nixos-base}"
RUNNER_USER="${VMH_RUNNER_USER:-runner}"
RUNNER_CACHE="${VMH_RUNNER_CACHE:-/home/${RUNNER_USER}/actions-runner}"
LAYOUT="${VMH_RUNNER_LAYOUT:-}"
STORE_PATH="${VMH_RUNNER_STORE_PATH:-}"
BLD="vmh-bld-nixos-runner"

log() { echo "[build-nixos-runner-image] $*"; }
cleanup() { "${INCUS[@]}" delete --force "$BLD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

command -v nix-store >/dev/null 2>&1 || { echo "nix-store required (to seed the guest closure)" >&2; exit 1; }
"${INCUS[@]}" image info "$NIXOS_BASE" >/dev/null 2>&1 || { echo "NixOS base '$NIXOS_BASE' absent" >&2; exit 1; }

# 0. Resolve the runner tree to stage + the store roots whose closure we import.
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"; cleanup' EXIT
declare -a ROOTS=()
if [ -n "$STORE_PATH" ]; then
  log "staging nix-built fork from store path: $STORE_PATH"
  # buildDotnetModule lays the runner under $out/lib/<pname>; fall back to $out.
  src="$STORE_PATH/lib/metacraft-actions-runner"; [ -d "$src" ] || src="$STORE_PATH"
  cp -r "$src" "$STAGE/tree"; chmod -R u+w "$STAGE/tree"
  ROOTS+=("$STORE_PATH")
elif [ -n "$LAYOUT" ] && [ -d "$LAYOUT" ]; then
  log "staging fork _layout: $LAYOUT"
  bin="$LAYOUT/bin"; [ -e "$bin/Runner.HybridRpc" ] || bin="$(ls -d "$LAYOUT"/bin.* 2>/dev/null | head -1)"
  ext="$LAYOUT/externals"; [ -d "$ext" ] || ext="$(ls -d "$LAYOUT"/externals.* 2>/dev/null | head -1)"
  [ -e "$bin/Runner.HybridRpc" ] || { echo "no Runner.HybridRpc in $LAYOUT" >&2; exit 1; }
  mkdir -p "$STAGE/tree"
  for f in run.sh config.sh env.sh run-helper.sh.template safe_sleep.sh; do
    cp -a "$LAYOUT/$f" "$STAGE/tree/" 2>/dev/null || true
  done
  cp -a "$bin" "$STAGE/tree/bin"
  [ -n "$ext" ] && [ -d "$ext" ] && cp -a "$ext" "$STAGE/tree/externals"
  rm -rf "$STAGE/tree/_diag" "$STAGE/tree/_work" "$STAGE/tree/bin/_diag"
  # the store paths the native apphost references (PT_INTERP + RPATH)
  mapfile -t ROOTS < <(
    { patchelf --print-interpreter "$STAGE/tree/bin/Runner.Listener"
      patchelf --print-rpath "$STAGE/tree/bin/Runner.Listener" | tr ':' '\n'; } \
    | grep -oE '/nix/store/[^/]+' | sort -u )
else
  echo "set VMH_RUNNER_LAYOUT or VMH_RUNNER_STORE_PATH" >&2; exit 1
fi
[ "${#ROOTS[@]}" -gt 0 ] || { echo "no nix store roots to import (apphost has no nix refs?)" >&2; exit 1; }

# 1. Launch a throwaway build container off the NixOS base.
log "launching throwaway build container '$BLD' from $NIXOS_BASE"
"${INCUS[@]}" delete --force "$BLD" >/dev/null 2>&1 || true
"${INCUS[@]}" launch "$NIXOS_BASE" "$BLD"
for _ in $(seq 1 90); do "${INCUS[@]}" exec "$BLD" -- true 2>/dev/null && break; sleep 1; done

# 2. Import the runner closure into the guest store (streamed).
log "importing runner nix closure (${#ROOTS[@]} roots) into $BLD:/nix/store"
nix-store --export $(nix-store -qR "${ROOTS[@]}" | sort -u) \
  | "${INCUS[@]}" exec "$BLD" -- sh -c 'nix-store --import >/dev/null'

# 3. Create the unprivileged runner user with passwordless sudo.
log "creating '${RUNNER_USER}' user"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  getent group ${RUNNER_USER} >/dev/null 2>&1 || groupadd ${RUNNER_USER} 2>/dev/null || true
  id ${RUNNER_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${RUNNER_USER}
  echo '${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${RUNNER_USER} 2>/dev/null || true
  chmod 440 /etc/sudoers.d/90-${RUNNER_USER} 2>/dev/null || true
"

# 4. Stage the runner tree (streamed; blocker-A-safe) + re-assert ownership.
log "staging runner tree into ${RUNNER_CACHE}"
"${INCUS[@]}" exec "$BLD" -- sh -c "rm -rf '${RUNNER_CACHE}'; mkdir -p '${RUNNER_CACHE}'"
( cd "$STAGE/tree" && tar cz . ) | "${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  tar xz -C '${RUNNER_CACHE}'
  rm -rf '${RUNNER_CACHE}/_diag' '${RUNNER_CACHE}/_work'
  chown -R ${RUNNER_USER} '${RUNNER_CACHE}'
"

# 5. Smoke: the UNMODIFIED nix-native apphost runs on the NixOS guest.
log "smoke: Runner.Listener --version (nix-native apphost on NixOS)"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  cd '${RUNNER_CACHE}' && DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 ./bin/Runner.Listener --version
"

# 6. Record provenance + publish the SIDE alias.
"${INCUS[@]}" exec "$BLD" -- sh -c "printf 'vmh-nixos-runner: %s + fork actions-runner (nix-native)\n' '${NIXOS_BASE}' > /etc/vmh-nixos-runner-release || true"
log "stopping + publishing image alias '$ALIAS'"
"${INCUS[@]}" stop "$BLD"
"${INCUS[@]}" image delete "$ALIAS" >/dev/null 2>&1 || true
"${INCUS[@]}" publish "$BLD" --alias "$ALIAS" --public=false \
  description="vmh nixos runner: ${NIXOS_BASE} + fork actions-runner (nix-native)"
log "done: image '$ALIAS' built"
"${INCUS[@]}" image list "$ALIAS"
