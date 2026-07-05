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
# downloaded on the HOST and `incus file push`ed in rather than curled
# in-guest).
#
# Reproducible + idempotent: safe to re-run. Uses ONLY the `im2-bld-runner`
# throwaway container name + the `vmh-linux-runner` alias — never touches
# unrelated host containers/images.
#
# Usage:
#   ./build-runner-image.sh
#   VMH_INCUS_CMD="sudo -n incus" ./build-runner-image.sh
#   VMH_RUNNER_VERSION=2.335.1 ./build-runner-image.sh
#   VMH_RUNNER_TARBALL=/path/to/actions-runner-linux-x64-X.tar.gz ./build-runner-image.sh
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
BLD="im2-bld-runner"

log() { echo "[build-runner-image] $*"; }

cleanup() { "${INCUS[@]}" delete --force "$BLD" >/dev/null 2>&1 || true; }
trap cleanup EXIT

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

# 4. Create the unprivileged runner user with passwordless sudo.
log "creating '${RUNNER_USER}' user with passwordless sudo"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
  id ${RUNNER_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${RUNNER_USER}
  echo '${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${RUNNER_USER}
  chmod 440 /etc/sudoers.d/90-${RUNNER_USER}
"

# 5. Stage the actions-runner into the image cache (push from host; extract).
log "staging actions runner ${RUNNER_VERSION} into ${RUNNER_CACHE}"
"${INCUS[@]}" exec "$BLD" -- sh -c "rm -rf '${RUNNER_CACHE}'; mkdir -p '${RUNNER_CACHE}'"
"${INCUS[@]}" file push "$TARBALL" "$BLD/tmp/runner.tar.gz"
"${INCUS[@]}" exec "$BLD" -- sh -c "
  set -e
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

# 6. Record the image provenance.
"${INCUS[@]}" exec "$BLD" -- sh -c "
  printf 'vmh-linux-runner: %s (cloud) + actions-runner %s + cloud-init\n' \
    '${CLOUD_BASE}' '${RUNNER_VERSION}' > /etc/vmh-linux-runner-release
"

# 7. Stop + publish as the runner image alias (replace any prior copy).
log "stopping container + publishing image alias '$ALIAS'"
"${INCUS[@]}" stop "$BLD"
"${INCUS[@]}" image delete "$ALIAS" >/dev/null 2>&1 || true
"${INCUS[@]}" publish "$BLD" --alias "$ALIAS" \
  --public=false \
  description="vmh linux runner: ${CLOUD_BASE} + actions-runner ${RUNNER_VERSION} + cloud-init"

log "done: image '$ALIAS' built"
"${INCUS[@]}" image list "$ALIAS"
