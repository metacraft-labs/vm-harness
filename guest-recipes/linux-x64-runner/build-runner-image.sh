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

# HR1 (nested Docker): when VMH_RUNNER_DOCKER is set (=1), bake docker/moby +
# fuse-overlayfs into the image so a per-job container launched with the
# provider's `incusSecurityNesting=true` (security.nesting + the
# mknod/setxattr syscall intercepts) can run an UNPRIVILEGED in-guest Docker
# daemon (`docker run` / `docker build`). Off by default ⇒ the live
# `vmh-linux-runner` image is byte-unchanged. Point VMH_RUNNER_ALIAS at a SIDE
# alias (eg vmh-linux-runner-docker) so the live image is never overwritten.
DOCKER="${VMH_RUNNER_DOCKER:-}"
DOCKER_VERSION="${VMH_DOCKER_VERSION:-27.5.1}"
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

# 5b. HR1 — bake docker/moby + fuse-overlayfs for NESTED Docker (opt-in). The
#     per-job container must be launched with the provider's
#     `incusSecurityNesting=true` (security.nesting + mknod/setxattr intercepts)
#     for the daemon to actually run; the storage driver is fuse-overlayfs so an
#     UNPRIVILEGED nested container (which cannot use the kernel overlay2 driver)
#     can still build layered images. `docker run` / `docker build` then work
#     inside the ephemeral runner (proven by the t_incus_nested_docker gate).
if [ -n "$DOCKER" ]; then
  log "HR1: baking docker ${DOCKER_VERSION} + fuse-overlayfs (nested Docker)"

  # (a) Give the build container egress (incusbr0 DHCP does not lease here) so
  #     the apt step for the docker RUNTIME deps (iptables/uidmap/dbus/
  #     fuse-overlayfs) works. Gateway defaults to the incusbr0 host address;
  #     the build IP defaults to host .249 of that /24. Both env-overridable.
  gw="$BUILD_EGRESS_GW"
  if [ -z "$gw" ]; then
    gw="$("${INCUS[@]}" network get "$INCUS_BRIDGE" ipv4.address 2>/dev/null | cut -d/ -f1)"
  fi
  bip="$BUILD_EGRESS_IP"
  if [ -z "$bip" ] && [ -n "$gw" ]; then
    bip="$(printf '%s' "$gw" | awk -F. '{printf "%s.%s.%s.249", $1,$2,$3}')"
  fi
  if [ -z "$gw" ] || [ -z "$bip" ]; then
    echo "[build-runner-image] HR1: could not derive build egress IP/gateway (set VMH_BUILD_EGRESS_IP / VMH_BUILD_EGRESS_GW)" >&2
    exit 1
  fi
  log "HR1: build-container egress ${bip} via ${gw} (dns ${BUILD_EGRESS_DNS})"
  "${INCUS[@]}" exec "$BLD" -- sh -c "
    set -e
    ip addr add ${bip}/24 dev eth0 2>/dev/null || true
    ip link set eth0 up
    ip route replace default via ${gw}
    rm -f /etc/resolv.conf
    printf 'nameserver %s\n' '${BUILD_EGRESS_DNS}' > /etc/resolv.conf
  "

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

  # (f) Undo the build-time egress IP so the published image carries no stray
  #     static address (the provider injects the real per-job IP via cloud-init).
  "${INCUS[@]}" exec "$BLD" -- sh -c "ip addr del ${bip}/24 dev eth0 2>/dev/null || true" || true
fi

# 6. Record the image provenance.
"${INCUS[@]}" exec "$BLD" -- sh -c "
  printf 'vmh-linux-runner: %s (cloud) + actions-runner %s + cloud-init%s\n' \
    '${CLOUD_BASE}' '${RUNNER_VERSION}' \"${DOCKER:+ + docker ${DOCKER_VERSION} (${DOCKER_STORAGE_DRIVER}) [HR1 nested]}\" > /etc/vmh-linux-runner-release
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
