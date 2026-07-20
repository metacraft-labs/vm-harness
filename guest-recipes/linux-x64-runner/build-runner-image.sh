#!/usr/bin/env bash
# build-runner-image.sh — build the `vmh-linux-runner` Incus image.
#
# The Linux analog of the Windows cloudbase-init golden: a small Debian
# system-container image with
#
#   * cloud-init present + enabled (so Incus's `cloud-init.user-data`
#     config key is consumed on first boot — this is the JIT-injection
#     seam the IM1 IncusBackend drives, proven by the IM2 gate),
#   * the GitHub Actions runner staged under /home/runner/actions-runner
#     (the path GARM's Linux install template treats as the CACHED runner:
#     `RUN_HOME="/home/$RunnerUsername/actions-runner"` — when that dir
#     already exists the bootstrap SKIPS the download+extract and uses the
#     baked-in copy) so the per-job bootstrap launches `run.sh --jitconfig`
#     with no gate-time GitHub download,
#   * an unprivileged `runner` user with passwordless sudo (the runner
#     refuses to run as root),
#   * the runner's .NET runtime deps (libicu/libssl/libkrb5/zlib) — the
#     `debian/12/cloud` base already ships them, so no apt is needed.
#
# Base image: a Debian *cloud* variant (has cloud-init). The default base
# alias is `im2-debian-cloud` (pulled during IM0/IM2 prep); if it is absent
# the script copies `images:debian/12/cloud` into it (needs host network —
# available; the CONTAINERS have no external network on this host because
# nixos-fw does not trust incusbr0, which is why the runner tarball is
# downloaded on the HOST and STREAMED in (cat|incus exec tar) rather than
# curled in-guest. It is streamed, NOT `incus file push`ed, because on this
# host `incus file push` corrupts large tarballs (blocker A).
#
# Reproducible + idempotent: safe to re-run. Uses ONLY an alias-scoped
# `im2-bld-<alias>` throwaway container name + the requested runner image
# alias — never touches unrelated host containers/images. Alias scoping lets
# the plain and nested image builders run concurrently without deleting each
# other's build container.
#
# Usage:
#   ./build-runner-image.sh
#   VMH_INCUS_CMD="sudo -n incus" ./build-runner-image.sh
#   VMH_RUNNER_VERSION=2.335.1 ./build-runner-image.sh
#   VMH_RUNNER_TARBALL=/path/to/actions-runner-linux-x64-X.tar.gz ./build-runner-image.sh
#   # FU3 (HR-BAKE): the prod nested-capability image (`incus-nested` class) —
#   # bake BOTH docker (HR1) + qemu/kvm (HR2) under a SIDE alias:
#   VMH_RUNNER_DOCKER=1 VMH_RUNNER_KVM=1 \
#     VMH_RUNNER_ALIAS=vmh-linux-runner-nested ./build-runner-image.sh
#
# Env:
#   VMH_INCUS_CMD       incus invocation        (default: incus)
#   VMH_RUNNER_ALIAS    output image alias       (default: vmh-linux-runner)
#   VMH_CLOUD_BASE      local cloud base alias   (default: im2-debian-cloud)
#   VMH_CLOUD_REMOTE    remote to copy if base
#                       absent                   (default: images:debian/12/cloud)
#   VMH_RUNNER_VERSION  actions runner version   (default: 2.335.1)
#   VMH_RUNNER_TARBALL  pre-downloaded tarball    (default: download to /tmp)
#   VMH_RUNNER_CACHE    in-image runner dir       (default: /home/<user>/actions-runner)
#   VMH_RUNNER_BUILD_CONTAINER
#                       throwaway container name   (default: im2-bld-<alias>)
#   VMH_RUNNER_DOCKER   bake nested Docker (HR1)  (default: off; set =1)
#   VMH_RUNNER_KVM      bake nested KVM (HR2)     (default: off; set =1)
#   VMH_RUNNER_RECIPE_REVISION
#                       image recipe revision property (default: linux-x64-runner-v1)
#   VMH_RUNNER_REPRO    bake the `repro` CLI      (default: ON; set =0 to skip)
#   VMH_REPRO_PIN       reprobuild rev to build   (default: resolved from
#                       repro-portable from       nixos-modules/flake.lock —
#                                                 the single source of truth)
#   VMH_REPRO_BUNDLE    pre-built repro-portable  (default: nix-built on host
#                       self-extractor on host    from the pin)
#   VMH_NIXOS_MODULES_LOCK  path to the pinning   (default: ../../../nixos-modules
#                       nixos-modules flake.lock  /flake.lock relative to script)
#
# REPRO BAKE (HR-REPRO): the ephemeral Linux runner ships the pinned `repro`
# CLI pre-installed on PATH so CI jobs get it for free and reprobuild's
# idempotent `setup-reprobuild` action no-ops. `repro` is distributed to
# NON-nix hosts (this Debian image has no /nix/store) as `repro-portable` — a
# ~234 MB self-extracting `toArx` bundle that, on FIRST run, extracts its whole
# nix closure (~364 MB) under $HOME/.cache and re-exposes it at /nix/store via
# nix-user-chroot (needs unprivileged user namespaces). A cold first run costs
# ~50 s of extraction; a warm run (extracted `dat` already present) is ~4 s and
# does NOT re-extract. Because these runners are EPHEMERAL (fresh image clone
# per job) we must NEVER pay that ~50 s per job, so this script PRE-WARMS the
# extraction AT BAKE TIME as the runner user: the extracted closure lands in
# /home/<user>/.cache/tmpx-<hash> and is baked into the published image, so
# every per-job first run hits the warm cache. The pin is resolved from
# nixos-modules/flake.lock (the reprobuild node rev) so the runner image and the
# nix hosts install byte-identical `repro` from ONE source of truth.
#
# IM4 note: the cache path MUST match GARM's Linux install template, which
# looks for a cached runner at exactly `/home/<RunnerUsername>/actions-runner`
# (RunnerUsername defaults to `runner`). Staging elsewhere (the old
# /opt/actions-runner) made the template's `[ ! -d "$RUN_HOME" ]` test true, so
# GARM re-downloaded + re-extracted the ~200 MB runner into /home/runner every
# job. Baking it at the expected path lets the bootstrap take the cached branch.
set -euo pipefail

INCUS=(${VMH_INCUS_CMD:-incus})
ALIAS="${VMH_RUNNER_ALIAS:-vmh-linux-runner}"
CLOUD_BASE="${VMH_CLOUD_BASE:-im2-debian-cloud}"
CLOUD_REMOTE="${VMH_CLOUD_REMOTE:-images:debian/12/cloud}"
RUNNER_VERSION="${VMH_RUNNER_VERSION:-2.335.1}"
RUNNER_USER="${VMH_RUNNER_USER:-runner}"
# Default to the GARM-expected cached path /home/<user>/actions-runner so the
# per-job bootstrap uses the baked runner instead of re-downloading it.
RUNNER_CACHE="${VMH_RUNNER_CACHE:-/home/${RUNNER_USER}/actions-runner}"
BLD="${VMH_RUNNER_BUILD_CONTAINER:-im2-bld-${ALIAS}}"

# HR1 (nested Docker): when VMH_RUNNER_DOCKER is set (=1), bake docker/moby +
# fuse-overlayfs into the image so a per-job container launched with the
# provider's `incusSecurityNesting=true` (security.nesting + the
# mknod/setxattr syscall intercepts) can run an UNPRIVILEGED in-guest Docker
# daemon (`docker run` / `docker build`). Off by default ⇒ the live
# `vmh-linux-runner` image is byte-unchanged. Point VMH_RUNNER_ALIAS at a SIDE
# alias (eg vmh-linux-runner-docker) so the live image is never overwritten.
DOCKER="${VMH_RUNNER_DOCKER:-}"
DOCKER_VERSION="${VMH_DOCKER_VERSION:-27.5.1}"
# HR2 (nested KVM): when VMH_RUNNER_KVM is set (=1), bake the qemu/kvm
# USERSPACE (qemu-system-x86 + a guest kernel for the boot smoke) into the
# image so a per-job container launched with the provider's
# `incusNestedKvm=true` (security.nesting + a /dev/kvm unix-char device) can run
# `qemu-system-x86_64 -enable-kvm` with HARDWARE acceleration (the nested-VM
# path proven by the t_incus_nested_vm gate). Off by default ⇒ the live image is
# byte-unchanged. Point VMH_RUNNER_ALIAS at a SIDE alias (eg
# vmh-linux-runner-nested) so the live image is never overwritten. KVM shares
# the same egress + apt seam as HR1, so VMH_RUNNER_DOCKER=1 VMH_RUNNER_KVM=1
# bakes BOTH into one image (the `incus-nested` prod class needs both).
KVM="${VMH_RUNNER_KVM:-}"
RECIPE_REVISION="${VMH_RUNNER_RECIPE_REVISION:-linux-x64-runner-v1}"
# HR-REPRO (repro CLI bake): ON by default so the live `vmh-linux-runner` image
# ships `repro` on PATH. Set VMH_RUNNER_REPRO=0 to skip (e.g. to reproduce the
# pre-repro image byte-for-byte). The pin is resolved from nixos-modules'
# flake.lock unless VMH_REPRO_PIN pins a reprobuild rev explicitly; a pre-built
# bundle can be supplied via VMH_REPRO_BUNDLE (host path) to skip the nix build.
REPRO="${VMH_RUNNER_REPRO:-1}"
REPRO_PIN="${VMH_REPRO_PIN:-}"
REPRO_BUNDLE="${VMH_REPRO_BUNDLE:-}"
# nixos-modules is the single source of truth for the reprobuild pin. Default to
# the sibling checkout in this multi-repo workspace (…/infra and …/nixos-modules
# are siblings; this recipe lives at vm-harness/guest-recipes/linux-x64-runner).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXOS_MODULES_LOCK="${VMH_NIXOS_MODULES_LOCK:-${_SCRIPT_DIR}/../../../nixos-modules/flake.lock}"
# Where the self-extractor is installed on PATH inside the image, and the runner
# user's HOME whose .cache the pre-warmed extraction is baked under.
REPRO_BIN="/usr/local/bin/repro"
RUNNER_HOME="/home/${RUNNER_USER}"
# Pre-downloaded docker static bundle on the HOST (containers have egress only
# once a static IP + gateway are configured — see the egress step below); the
# static bundle is STREAMED in (cat|incus exec tar) rather than `incus file
# push`ed, working around blocker A (incus file push corrupts large tarballs).
DOCKER_TARBALL="${VMH_DOCKER_TARBALL:-}"
DOCKER_STORAGE_DRIVER="${VMH_DOCKER_STORAGE_DRIVER:-fuse-overlayfs}"
# incusbr0 DHCP does not lease on this host, so give the build container a
# STATIC egress IP for the docker apt step. Auto-detected from the bridge
# (gateway = the incusbr0 host address; build IP = same /24, host .249) but
# env-overridable.
BUILD_EGRESS_IP="${VMH_BUILD_EGRESS_IP:-}"
BUILD_EGRESS_GW="${VMH_BUILD_EGRESS_GW:-}"
BUILD_EGRESS_DNS="${VMH_BUILD_EGRESS_DNS:-1.1.1.1}"
INCUS_BRIDGE="${VMH_CLOUD_BRIDGE:-incusbr0}"

log() { echo "[build-runner-image] $*"; }

cleanup() { "${INCUS[@]}" delete --force "$BLD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Build-time egress for the in-container apt steps (base git/xz install below +
# the opt-in HR1/HR2 nested-capability bakes). incusbr0 DHCP does not lease on
# this host, so give the build container a STATIC egress IP. Gateway defaults to
# the incusbr0 host address; the build IP defaults to host .249 of that /24. Both
# env-overridable. Idempotent: the resolved IP is cached in EGRESS_BIP so repeat
# callers are no-ops, and the address is torn down once at the end so the
# published image carries no stray static address (the provider injects the real
# per-job IP via cloud-init).
EGRESS_BIP=""
ensure_build_egress() {
  [ -n "$EGRESS_BIP" ] && return 0
  local gw bip
  gw="$BUILD_EGRESS_GW"
  if [ -z "$gw" ]; then
    gw="$("${INCUS[@]}" network get "$INCUS_BRIDGE" ipv4.address 2>/dev/null | cut -d/ -f1)"
  fi
  bip="$BUILD_EGRESS_IP"
  if [ -z "$bip" ] && [ -n "$gw" ]; then
    bip="$(printf '%s' "$gw" | awk -F. '{printf "%s.%s.%s.249", $1,$2,$3}')"
  fi
  if [ -z "$gw" ] || [ -z "$bip" ]; then
    echo "[build-runner-image] could not derive build egress IP/gateway (set VMH_BUILD_EGRESS_IP / VMH_BUILD_EGRESS_GW)" >&2
    exit 1
  fi
  log "build-container egress ${bip} via ${gw} (dns ${BUILD_EGRESS_DNS})"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    ip addr add ${bip}/24 dev eth0 2>/dev/null || true
    ip link set eth0 up
    ip route replace default via ${gw}
    rm -f /etc/resolv.conf
    printf 'nameserver %s\n' '${BUILD_EGRESS_DNS}' > /etc/resolv.conf
  "
  EGRESS_BIP="$bip"
}
teardown_build_egress() {
  [ -z "$EGRESS_BIP" ] && return 0
  "${INCUS[@]}" exec "$BLD" -- sh -c "ip addr del ${EGRESS_BIP}/24 dev eth0 2>/dev/null || true" || true
  EGRESS_BIP=""
}

# HR-REPRO helpers ────────────────────────────────────────────────────────────
# Resolve the reprobuild rev to build `repro-portable` from. nixos-modules'
# flake.lock is the SINGLE source of truth (its `reprobuild` node rev). An
# explicit VMH_REPRO_PIN overrides it (e.g. to test an unlanded rev). We resolve
# a concrete rev — rather than build `github:…/reprobuild#repro-portable` at a
# floating branch — so the runner image and the nix fleet install byte-identical
# `repro` from the same commit. nixos-modules does NOT re-export repro-portable
# (its mcl-reprobuild module installs the NATIVE package for nix hosts only), so
# we build the `repro-portable` output straight from the reprobuild flake AT the
# rev nixos-modules pins.
resolve_repro_pin() {
  if [ -n "$REPRO_PIN" ]; then
    log "HR-REPRO: using explicit reprobuild pin VMH_REPRO_PIN=${REPRO_PIN}"
    return 0
  fi
  if [ ! -f "$NIXOS_MODULES_LOCK" ]; then
    echo "[build-runner-image] HR-REPRO: nixos-modules flake.lock not found at ${NIXOS_MODULES_LOCK}" >&2
    echo "  (set VMH_NIXOS_MODULES_LOCK to its path, or VMH_REPRO_PIN to a reprobuild rev)" >&2
    exit 1
  fi
  # Pull the reprobuild node's locked rev out of the lock JSON. Prefer python3
  # (present on the host); fall back to a grep/sed extraction.
  if command -v python3 >/dev/null 2>&1; then
    REPRO_PIN="$(python3 - "$NIXOS_MODULES_LOCK" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
node = lock["nodes"]["reprobuild"]["locked"]
assert node["type"] == "github" and node["repo"] == "reprobuild", node
print(node["rev"])
PY
)"
  else
    REPRO_PIN="$(grep -A6 '"reprobuild"' "$NIXOS_MODULES_LOCK" | sed -n 's/.*"rev": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
  fi
  if [ -z "$REPRO_PIN" ]; then
    echo "[build-runner-image] HR-REPRO: could not resolve reprobuild rev from ${NIXOS_MODULES_LOCK}" >&2
    exit 1
  fi
  log "HR-REPRO: resolved reprobuild pin ${REPRO_PIN} from nixos-modules/flake.lock (single source of truth)"
}

# Build the self-extracting `repro-portable` bundle on the HOST (the build
# CONTAINER has no reliable egress and no nix). Sets REPRO_BUNDLE to the built
# path unless one was supplied. The bundle is the reprobuild flake's
# `packages.<system>.repro-portable` (a ~234 MB toArx executable).
build_repro_bundle() {
  if [ -n "$REPRO_BUNDLE" ] && [ -f "$REPRO_BUNDLE" ]; then
    log "HR-REPRO: using pre-built repro-portable bundle: $REPRO_BUNDLE"
    return 0
  fi
  if ! command -v nix >/dev/null 2>&1; then
    echo "[build-runner-image] HR-REPRO: nix not found on the host — cannot build repro-portable." >&2
    echo "  Supply a pre-built bundle via VMH_REPRO_BUNDLE=/path/to/repro-portable, or set" >&2
    echo "  VMH_RUNNER_REPRO=0 to skip the repro bake." >&2
    exit 1
  fi
  local flakeref="github:metacraft-labs/reprobuild/${REPRO_PIN}#repro-portable"
  log "HR-REPRO: building ${flakeref} on the host (this is the ~234 MB toArx bundle; slow on a cold cache)"
  REPRO_BUNDLE="$(nix build --no-link --print-out-paths \
    --extra-experimental-features 'nix-command flakes' \
    "$flakeref")"
  if [ -z "$REPRO_BUNDLE" ] || [ ! -f "$REPRO_BUNDLE" ]; then
    echo "[build-runner-image] HR-REPRO: nix build did not produce a bundle file (got: '${REPRO_BUNDLE}')" >&2
    exit 1
  fi
  log "HR-REPRO: built repro-portable at $REPRO_BUNDLE ($(du -h "$REPRO_BUNDLE" | cut -f1))"
}

# 0. Ensure a local cloud base image exists (cloud-init present). If not,
#    copy it from the remote (host has network).
if ! "${INCUS[@]}" image info "$CLOUD_BASE" >/dev/null 2>&1; then
  log "cloud base '$CLOUD_BASE' absent; copying $CLOUD_REMOTE -> local:$CLOUD_BASE"
  "${INCUS[@]}" image copy "$CLOUD_REMOTE" local: --alias "$CLOUD_BASE"
fi

# 1. Obtain the runner tarball on the HOST (containers have no egress here).
if [ -n "${VMH_RUNNER_TARBALL:-}" ] && [ -f "${VMH_RUNNER_TARBALL}" ]; then
  TARBALL="${VMH_RUNNER_TARBALL}"
  log "using pre-downloaded runner tarball: $TARBALL"
else
  TARBALL="/tmp/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  if [ ! -f "$TARBALL" ]; then
    URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    log "downloading runner ${RUNNER_VERSION} on the host: $URL"
    curl --retry 5 --retry-delay 3 --retry-connrefused -fL -o "$TARBALL" "$URL"
  fi
  log "runner tarball: $TARBALL"
fi

# 2. Launch a throwaway build container off the cloud base.
log "launching throwaway build container '$BLD' from $CLOUD_BASE"
"${INCUS[@]}" delete --force "$BLD" >/dev/null 2>&1 || true
"${INCUS[@]}" launch "$CLOUD_BASE" "$BLD"

# Wait for the container to be exec-ready.
for _ in $(seq 1 60); do
  if "${INCUS[@]}" exec "$BLD" -- true 2>/dev/null; then break; fi
  sleep 1
done

# 3. Verify the .NET runtime deps the runner needs are present in the base
#    (the cloud image ships them). liblttng-ust1 is optional (LTTng tracing).
log "checking runner runtime dependencies in the base image"
"${INCUS[@]}" exec "$BLD" -- sh -c '
  miss=""
  for p in libicu72 libssl3 zlib1g libkrb5-3; do
    dpkg -s "$p" >/dev/null 2>&1 || miss="$miss $p"
  done
  if [ -n "$miss" ]; then
    echo "[build-runner-image] MISSING runtime deps:$miss" >&2
    echo "  (the runner may fail to start; base image needs these preinstalled)" >&2
    exit 1
  fi
  echo "[build-runner-image] runtime deps present (libicu72 libssl3 zlib1g libkrb5-3)"
'

# 3b. Bake the CI baseline tools every job needs regardless of flavor. The
#     Debian cloud base ships neither `git` nor `xz`, but:
#       * the shared `setup-dev-env` action clones cross-repo siblings with
#         `git` BEFORE any per-flavor toolchain (nix / reprobuild) is installed
#         — a missing `git` makes that clone-siblings step exit 127 (the whole
#         reason the CIP-5 incus jobs went red);
#       * `xz` is needed to unpack the Nix installer's `.xz` payload for the
#         `nix` flavor;
#       * `ca-certificates` keeps the authenticated github HTTPS clones valid.
#     apt needs egress, which incusbr0 does not lease; bring up the shared
#     static build IP for the install (idempotent — the HR1/HR2 bakes reuse it).
log "installing CI baseline tools (git, xz-utils, ca-certificates)"
ensure_build_egress
"${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends git xz-utils ca-certificates
  command -v git
  command -v xz
"

# 4. Create the unprivileged runner user with passwordless sudo.
log "creating '${RUNNER_USER}' user with passwordless sudo"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  id ${RUNNER_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${RUNNER_USER}
  echo '${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${RUNNER_USER}
  chmod 440 /etc/sudoers.d/90-${RUNNER_USER}
"

# 5. Stage the actions-runner into the image cache. The tarball is STREAMED in
#    (cat|incus exec tar) rather than `incus file push`ed: on this host
#    `incus file push` corrupts large (~200 MB) locally-built tarballs (blocker
#    A — the same failure mode the HR1 docker bundle hits below), so the runner
#    tree would extract truncated/garbled and the apphost would fail to load.
#    Streaming through `incus exec` is byte-exact.
log "staging actions runner ${RUNNER_VERSION} into ${RUNNER_CACHE} (streamed; blocker-A workaround)"
"${INCUS[@]}" exec "$BLD" -- sh -c "rm -rf '${RUNNER_CACHE}'; mkdir -p '${RUNNER_CACHE}'"
cat "$TARBALL" | "${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  cat > /tmp/runner.tar.gz
  tar xzf /tmp/runner.tar.gz -C '${RUNNER_CACHE}'
  rm -f /tmp/runner.tar.gz
  chown -R ${RUNNER_USER}:${RUNNER_USER} '${RUNNER_CACHE}'
  test -x '${RUNNER_CACHE}/run.sh'
  test -x '${RUNNER_CACHE}/config.sh'
"
# Sanity: the runner binary must load with the base deps.
log "smoke: Runner.Listener --version"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  cd '${RUNNER_CACHE}' && DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 ./bin/Runner.Listener --version
"

# IM4 CRITICAL: the runner SERVICE runs as the unprivileged '${RUNNER_USER}'
# user, and GARM's cached-runner bootstrap path does NOT chown the runner dir
# (unlike the download path — it assumes a cached tree is already runner-owned).
# The smoke test above ran as ROOT and created a root:root '_diag' log dir; a
# runner-user listener then fails with "Access to the path .../_diag/…' is
# denied" and NEVER picks up jobs. Remove the root-owned runtime dirs and
# re-assert runner ownership so the baked tree is 100% writable by the service.
log "clearing root-owned runtime dirs + re-asserting ${RUNNER_USER} ownership"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  rm -rf '${RUNNER_CACHE}/_diag' '${RUNNER_CACHE}/_work'
  chown -R ${RUNNER_USER}:${RUNNER_USER} '${RUNNER_CACHE}'
"

# 5a-REPRO. HR-REPRO — bake the pinned `repro` CLI onto PATH + PRE-WARM its
#     extraction so per-job first-run is fast. Default-ON (VMH_RUNNER_REPRO=1);
#     set VMH_RUNNER_REPRO=0 to reproduce the pre-repro image. See the header
#     for the full rationale (ephemeral runners must not pay the ~50 s cold
#     extraction per job).
if [ "$REPRO" != "0" ]; then
  resolve_repro_pin
  build_repro_bundle

  # (a0) The toArx self-extractor decompresses its embedded closure with bzip2
  #     (the `dat` payload is BZh/bzip2 — verified on the built bundle) plus tar.
  #     `tar` + `gzip` ship in the Debian cloud base but `bzip2` does NOT, so the
  #     FIRST run would die with "tar (grandchild): bzip2: Cannot exec". Install
  #     it (tiny). Egress is already up from step 3b's baseline install;
  #     ensure_build_egress is idempotent so this is a no-op then.
  log "HR-REPRO: installing bzip2 (the toArx extractor's decompressor)"
  ensure_build_egress
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    command -v bzip2 >/dev/null 2>&1 || {
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends bzip2
    }
    command -v bzip2
  "

  # (a) Enable unprivileged user namespaces in the image. The toArx bundle runs
  #     nix-user-chroot, which needs unprivileged userns to map the extracted
  #     store to /nix/store. Debian 12 enables this by default, but the legacy
  #     `kernel.unprivileged_userns_clone` knob (present on Debian/Ubuntu
  #     kernels) can be flipped off by hardening; assert it =1 via a sysctl
  #     drop-in so the image is robust regardless of host defaults. The
  #     mainline `user.max_user_namespaces` is also raised in case it was
  #     zeroed. `sysctl -p` is best-effort: on a kernel WITHOUT the legacy knob
  #     (e.g. this is a container whose /proc lacks it) writing it errors
  #     harmlessly and the mainline default already permits userns.
  log "HR-REPRO: enabling unprivileged user namespaces (sysctl drop-in) for nix-user-chroot"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    cat > /etc/sysctl.d/99-repro-userns.conf <<'EOF'
# repro-portable (toArx / nix-user-chroot) needs unprivileged user namespaces.
kernel.unprivileged_userns_clone = 1
user.max_user_namespaces = 28633
EOF
    sysctl -p /etc/sysctl.d/99-repro-userns.conf >/dev/null 2>&1 || true
  "

  # (b) Install the self-extractor on PATH. STREAMED in (cat|incus exec) rather
  #     than `incus file push`ed — the same blocker-A workaround the ~200 MB
  #     runner tarball uses (incus file push corrupts large files on this host).
  log "HR-REPRO: installing repro-portable to ${REPRO_BIN} (streamed; blocker-A workaround)"
  cat "$REPRO_BUNDLE" | "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    cat > '${REPRO_BIN}'
    chmod 0755 '${REPRO_BIN}'
    test -x '${REPRO_BIN}'
  "

  # (c) PRE-WARM the extraction AS THE RUNNER USER so the extracted closure is
  #     baked under /home/<user>/.cache/tmpx-<hash> — the deterministic shared
  #     dir the toArx launcher reuses (shared=true ⇒ it re-uses an existing
  #     `dat` and NEVER re-extracts). Running as the runner user (not root) is
  #     essential: the launcher keys the cache dir off $HOME, and the per-job
  #     runner runs as this user, so the warm cache must live in THIS user's
  #     HOME. `sudo -u` gives a clean login-ish env; we set HOME explicitly so
  #     the cache lands in the right place even under a minimal env. A first
  #     invocation extracts (~50 s); we assert it prints the version.
  log "HR-REPRO: pre-warming repro extraction as '${RUNNER_USER}' (baking the ~364 MB closure into the image)"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    install -d -o '${RUNNER_USER}' -g '${RUNNER_USER}' '${RUNNER_HOME}/.cache'
    sudo -u '${RUNNER_USER}' -H env HOME='${RUNNER_HOME}' '${REPRO_BIN}' --version
  "

  # (d) VERIFY the warm cache persists AND is reused (no re-extraction) by a
  #     second run: capture the extracted `dat` mtime, run again, assert the
  #     mtime is unchanged (⇒ the closure was not re-unpacked). This is the
  #     property that makes per-job first-run fast.
  log "HR-REPRO: verifying warm-cache reuse (second run must not re-extract)"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    cache_dat=\$(find '${RUNNER_HOME}/.cache' -maxdepth 2 -type d -name dat 2>/dev/null | head -1)
    if [ -z \"\$cache_dat\" ]; then
      echo '[build-runner-image] HR-REPRO: extracted cache dir not found after pre-warm' >&2
      exit 1
    fi
    before=\$(stat -c %Y \"\$cache_dat\")
    sudo -u '${RUNNER_USER}' -H env HOME='${RUNNER_HOME}' '${REPRO_BIN}' --version >/dev/null
    after=\$(stat -c %Y \"\$cache_dat\")
    if [ \"\$before\" != \"\$after\" ]; then
      echo \"[build-runner-image] HR-REPRO: cache dat mtime changed (\$before -> \$after) — re-extraction happened, pre-warm did NOT persist\" >&2
      exit 1
    fi
    # Belt-and-braces: the whole tree must be runner-owned (pre-warm ran as the
    # runner user, but assert it so a per-job listener never hits a perm error).
    chown -R '${RUNNER_USER}:${RUNNER_USER}' '${RUNNER_HOME}/.cache'
    echo \"[build-runner-image] HR-REPRO: warm cache reused (dat mtime stable at \$after); repro is fast per-job\"
  "
fi

# 5b. HR1/HR2 — build-time egress for the nested-capability apt steps (opt-in).
#     Both the HR1 docker bake and the HR2 kvm bake below need Debian packages
#     from the network. The base git/xz install (step 3b) already brought up the
#     shared static egress IP; `ensure_build_egress` is idempotent so this is a
#     no-op then and a first-time setup only if 3b somehow did not run.
if [ -n "$DOCKER" ] || [ -n "$KVM" ]; then
  ensure_build_egress
  bip="$EGRESS_BIP"
fi

# 5c. HR1 — bake docker/moby + fuse-overlayfs for NESTED Docker (opt-in). The
#     per-job container must be launched with the provider's
#     `incusSecurityNesting=true` (security.nesting + mknod/setxattr intercepts)
#     for the daemon to actually run; the storage driver is fuse-overlayfs so an
#     UNPRIVILEGED nested container (which cannot use the kernel overlay2 driver)
#     can still build layered images. `docker run` / `docker build` then work
#     inside the ephemeral runner (proven by the t_incus_nested_docker gate).
if [ -n "$DOCKER" ]; then
  log "HR1: baking docker ${DOCKER_VERSION} + fuse-overlayfs (nested Docker)"

  # (b) Runtime deps from Debian (small): iptables (docker bridge NAT), uidmap
  #     (rootless helpers), dbus, and fuse-overlayfs (the unprivileged storage
  #     driver + its /dev/fuse mount helper).
  log "HR1: apt-get install docker runtime deps"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq iptables uidmap dbus fuse-overlayfs
  "

  # (c) Docker static binaries. STREAMED in (cat|incus exec tar), NOT `incus
  #     file push`ed — the latter corrupts large locally-built tarballs on this
  #     host (blocker A). Downloaded on the HOST if not pre-supplied.
  if [ -z "$DOCKER_TARBALL" ] || [ ! -f "$DOCKER_TARBALL" ]; then
    DOCKER_TARBALL="/tmp/docker-${DOCKER_VERSION}.tgz"
    if [ ! -f "$DOCKER_TARBALL" ]; then
      durl="https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
      log "HR1: downloading docker static bundle on the host: $durl"
      curl --retry 5 --retry-delay 3 --retry-connrefused -fL -o "$DOCKER_TARBALL" "$durl"
    fi
  fi
  log "HR1: streaming docker static bundle into /usr/local/bin (blocker-A workaround)"
  cat "$DOCKER_TARBALL" | "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    cat > /tmp/docker.tgz
    tar xzf /tmp/docker.tgz -C /usr/local/bin --strip-components=1
    rm -f /tmp/docker.tgz
    test -x /usr/local/bin/dockerd && test -x /usr/local/bin/docker
  "

  # (d) daemon.json (fuse-overlayfs driver) + a docker group the runner joins +
  #     a systemd service/socket so dockerd is up on first boot of a per-job
  #     container. The socket is group-owned by `docker` so the runner user can
  #     reach it without sudo (GitHub Actions' docker steps expect this).
  log "HR1: writing daemon.json (${DOCKER_STORAGE_DRIVER}) + docker.service/socket + docker group"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    getent group docker >/dev/null 2>&1 || groupadd docker
    usermod -aG docker '${RUNNER_USER}'
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  \"storage-driver\": \"${DOCKER_STORAGE_DRIVER}\",
  \"iptables\": true
}
EOF
    cat > /etc/systemd/system/docker.socket <<EOF
[Unit]
Description=Docker Socket for the API
[Socket]
ListenStream=/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker
[Install]
WantedBy=sockets.target
EOF
    cat > /etc/systemd/system/docker.service <<EOF
[Unit]
Description=Docker Application Container Engine (static, HR1 nested)
After=network-online.target docker.socket
Wants=network-online.target
Requires=docker.socket
[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP \\\$MAINPID
LimitNOFILE=1048576
Delegate=yes
KillMode=process
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime (static, HR1 nested)
After=network.target
[Service]
ExecStart=/usr/local/bin/containerd
Restart=always
Delegate=yes
KillMode=process
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable containerd.service docker.socket docker.service >/dev/null 2>&1 || true
  "

  # (e) Smoke: dockerd starts + selects the expected storage driver (offline —
  #     no image pull here; the gate does the online docker run/build).
  log "HR1: smoke — dockerd starts with ${DOCKER_STORAGE_DRIVER}"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    /usr/local/bin/containerd >/var/log/containerd.log 2>&1 &
    /usr/local/bin/dockerd >/var/log/dockerd.log 2>&1 &
    for i in \$(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
    sd=\$(docker info 2>/dev/null | sed -n 's/^ Storage Driver: //p')
    echo \"[build-runner-image] HR1 dockerd storage driver: \$sd\"
    test \"\$sd\" = \"${DOCKER_STORAGE_DRIVER}\"
    kill %1 %2 2>/dev/null || true
  "
fi

# 5d. HR2 — bake the qemu/kvm USERSPACE for NESTED KVM (opt-in). The per-job
#     container must be launched with the provider's `incusNestedKvm=true`
#     (security.nesting + a /dev/kvm unix-char device) for acceleration to be
#     available; this step installs `qemu-system-x86` + a guest kernel so an
#     in-guest `qemu-system-x86_64 -enable-kvm` boots a HW-accelerated VM (proven
#     by the t_incus_nested_vm gate). Pure apt — no static bundle, no systemd
#     unit (qemu is invoked ad hoc by the job, not a daemon). The host must
#     itself expose /dev/kvm with nested virt enabled (kvm_intel/amd.nested=Y).
if [ -n "$KVM" ]; then
  log "HR2: baking qemu-system-x86 + guest kernel (nested KVM)"

  # (a) qemu-system-x86 (the -enable-kvm accelerator) + linux-image-cloud-amd64
  #     (a tiny guest kernel for the boot smoke / the gate's boot proof) +
  #     python3 (the gate probes /dev/kvm via a python ioctl; harmless to bake).
  log "HR2: apt-get install qemu-system-x86 + guest kernel"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends qemu-system-x86 linux-image-cloud-amd64 python3
    getent group kvm >/dev/null 2>&1 || groupadd kvm
    usermod -aG kvm '${RUNNER_USER}'
  "

  # (b) Smoke: qemu is present + reports a version (offline — the actual
  #     -enable-kvm boot needs /dev/kvm, which the BUILD container does not have;
  #     the t_incus_nested_vm gate does the real accelerated boot in a per-job
  #     container that the provider attaches /dev/kvm to).
  log "HR2: smoke — qemu-system-x86_64 --version + guest kernel present"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    qemu-system-x86_64 --version | head -1
    ls -1 /boot/vmlinuz-* >/dev/null 2>&1 || { echo '[build-runner-image] HR2: no guest kernel staged in /boot' >&2; exit 1; }
  "
fi

# 5e. Undo the shared build-time egress IP so the published image carries no
#     stray static address (the provider injects the real per-job IP via
#     cloud-init). Always runs now — step 3b's baseline git/xz install brings
#     egress up on every build, not just the nested-capability bakes.
teardown_build_egress

# 6. Record the image provenance.
REPRO_PROV=""
if [ "$REPRO" != "0" ]; then
  REPRO_PROV=" + repro-portable [HR-REPRO pin ${REPRO_PIN}]"
fi
"${INCUS[@]}" exec "$BLD" -- sh -c "
  printf 'vmh-linux-runner: %s (cloud) + actions-runner %s + cloud-init%s%s%s\n' \
    '${CLOUD_BASE}' '${RUNNER_VERSION}' \"${DOCKER:+ + docker ${DOCKER_VERSION} (${DOCKER_STORAGE_DRIVER}) [HR1 nested]}\" \"${KVM:+ + qemu-system-x86 [HR2 nested-kvm]}\" \"${REPRO_PROV}\" > /etc/vmh-linux-runner-release
"

# 7. Stop + publish as the runner image alias (replace any prior copy).
log "stopping container + publishing image alias '$ALIAS'"
"${INCUS[@]}" stop "$BLD"
"${INCUS[@]}" image delete "$ALIAS" >/dev/null 2>&1 || true
"${INCUS[@]}" publish "$BLD" --alias "$ALIAS" \
  --public=false \
  description="vmh linux runner: ${CLOUD_BASE} + actions-runner ${RUNNER_VERSION} + cloud-init"
"${INCUS[@]}" image set-property "$ALIAS" vmh.recipe_revision "$RECIPE_REVISION"

log "done: image '$ALIAS' built"
"${INCUS[@]}" image list "$ALIAS"
