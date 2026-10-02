#!/usr/bin/env bash
# test-add-scheduler.sh -- TIER 2 (higher blast radius: replaces the control-plane
# scheduler). Builds edge-scheduler WITH patch 0002 applied, side-loads it into k3s
# containerd (podman build + k3s ctr import; the test image is never published),
# and points the wes-plugin-scheduler Deployment at the side-loaded image. Then ANY
# normally-scheduled plugin (no envFrom in its own spec) gets wes-identity injected.
#
# PREREQ: run Tier 1's test-add-configmap.sh FIRST so wes-identity actually carries
# the 5 vars -- otherwise the scheduler injects an envFrom to a CM without gps/mobility.
#
# Revert with test-remove-scheduler.sh (restores the original Deployment image).
# Run ON the node. Requires: sudo podman, k3s, git, network access to docker.io, and
# kubectl via $KUBECTL (see lib.sh). No host Go: Go compiles inside the container.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
REPO="$(cd "$HERE/.." && pwd)"

need "$KUBECTL"; need podman; need git
TAG="${TAG:-localhost/edge-scheduler:nodeinfo-test}"
K3S_TAG="docker.io/library/edge-scheduler:nodeinfo-test"
SRC="${SCHEDULER_SRC:-$REPO/.upstream/edge-scheduler}"

[ -d "$SRC" ] || fatal "edge-scheduler source not found at $SRC (see README: populate .upstream/)"

# 0a. pre-flight: confirm the scheduler Deployment name is what we expect on THIS node.
# Node deployments can vary (wes-plugin-scheduler vs edge-scheduler vs ...); fail fast
# with the actual candidates rather than mid-rollout on a name mismatch.
if ! kc -n "$NS_DEFAULT" get deployment "$SCHED_DEPLOY" >/dev/null 2>&1; then
  warn "Deployment '$SCHED_DEPLOY' not found in ns '$NS_DEFAULT'. Scheduler-like deployments here:"
  kc -n "$NS_DEFAULT" get deployments -o name 2>/dev/null | grep -iE 'sched' >&2 || \
    kc -n "$NS_DEFAULT" get deployments -o name >&2
  fatal "set SCHED_DEPLOY to the correct name (edit lib.sh or export SCHED_DEPLOY=...) and re-run."
fi
log "scheduler Deployment confirmed: $SCHED_DEPLOY"

# 0. sanity: is patch 0002 actually applied in $SRC? (grep for our marker)
if ! grep -q 'wes-identity' "$SRC/pkg/nodescheduler/resourcemanager.go"; then
  fatal "patch 0002 not applied in $SRC -- run: git -C $SRC apply $REPO/patches/0002-*.patch"
fi
log "patch 0002 confirmed present in scheduler source"

# 1. build the patched scheduler image natively (podman; RUN works on-node).
# Notes learned on H00F: (a) build needs root here (sudo podman); (b) this node's
# /etc/containers/registries.conf defines no unqualified-search registries, so the
# Dockerfile's bare `FROM waggle/plugin-base` won't resolve -- fully-qualify it to
# docker.io in a throwaway Dockerfile so we never dirty the packaged (patched) one;
# (c) the multi-stage Dockerfile compiles Go INSIDE the container, so no host Go is
# needed, but it DOES require --build-arg TARGETARCH and VERSION.
ARCH="$(uname -m)"; case "$ARCH" in aarch64|arm64) TARGETARCH=arm64;; x86_64|amd64) TARGETARCH=amd64;; *) fatal "unsupported arch $ARCH";; esac
log "building $TAG (podman, native, TARGETARCH=$TARGETARCH) ..."
(
  cd "$SRC"
  sed 's|^FROM waggle/plugin-base|FROM docker.io/waggle/plugin-base|' Dockerfile > Dockerfile.nodeinfo-build
  trap 'rm -f Dockerfile.nodeinfo-build' EXIT
  sudo podman build -f Dockerfile.nodeinfo-build \
    --build-arg TARGETARCH="$TARGETARCH" --build-arg VERSION=nodeinfo-test \
    -t "$TAG" .
) || fatal "podman build failed"

# 2. import into k3s containerd (separate store from podman)
log "importing image into k3s containerd ..."
sudo podman save "$TAG" | sudo k3s ctr images import - >/dev/null
sudo k3s ctr images tag "$TAG" "$K3S_TAG" 2>/dev/null || true

# 3. back up + patch the scheduler Deployment to the side-loaded image
backup_resource deployment "$SCHED_DEPLOY"
log "pointing $SCHED_DEPLOY at $K3S_TAG (imagePullPolicy=IfNotPresent)"
kc -n "$NS_DEFAULT" set image "deployment/$SCHED_DEPLOY" "*=$K3S_TAG"
kc -n "$NS_DEFAULT" patch "deployment/$SCHED_DEPLOY" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null

log "waiting for scheduler rollout ..."
if ! kc -n "$NS_DEFAULT" rollout status "deployment/$SCHED_DEPLOY" --timeout=120s; then
  warn "rollout did not go Ready -- REVERTING to avoid a stalled control plane"
  restore_resource deployment "$SCHED_DEPLOY"
  fatal "scheduler rollout failed; reverted."
fi
log "patched scheduler is running."
echo "-------------------------------------------------------------"
log "now run an SES job on this node (sesctl, via the cloud). pluginctl pods do NOT"
log "count: pluginctl builds its pods itself. Scheduler pods live in namespace ses:"
log "  $KUBECTL get pods -n ses"
log "  $KUBECTL get pod -n ses <plugin> -o jsonpath='{.spec.containers[0].envFrom}'"
log "when done:  ./test-remove-scheduler.sh"
