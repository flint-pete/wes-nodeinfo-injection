#!/usr/bin/env bash
# install-pluginctl-nodeinfo.sh -- TIER 1b (low blast radius: installs ONE user-owned
# file; touches no WES object). Installs a PATCHED pluginctl next to the stock one, so
# pods you launch by hand get `envFrom: wes-identity` -- the same 5 WAGGLE_NODE_* vars
# (VSN, node id, GPS lat/lon, mobility) that SES jobs get from the Tier 2 scheduler.
#
# Why: the stock /usr/bin/pluginctl builds pods CLIENT-SIDE with its own (unpatched)
# pod builder, so `pluginctl run` pods never see wes-identity, even with Tier 2
# installed. Patch 0002 lives in pod-builder code that pluginctl shares with the
# scheduler, so the patched edge-scheduler image already contains a patched
# pluginctl (/app/pluginctl-linux-arm64). This script copies it out.
#
# Needs only Tier 1 (the wes-identity ConfigMap). Does NOT need the Tier 2 scheduler
# Deployment change. If the ConfigMap is missing, pods still start (optional: true).
#
#   ./install-pluginctl-nodeinfo.sh            # build image if absent, install
#   FORCE_BUILD=1 ./install-pluginctl-nodeinfo.sh
#   DEST=/usr/local/bin/pluginctl-nodeinfo ./install-pluginctl-nodeinfo.sh  # (sudo install)
#
# Use it exactly like pluginctl (same flags, still needs sudo for `run`):
#   sudo ~/bin/pluginctl-nodeinfo run --name ... --selector zone=core ... <image> -- ...
# Uninstall: rm ~/bin/pluginctl-nodeinfo   (the stock /usr/bin/pluginctl is never touched)
# Run ON the node. Requires: sudo podman (to build/read the image), git, network to docker.io.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
REPO="$(cd "$HERE/.." && pwd)"

need podman
TAG="${TAG:-localhost/edge-scheduler:nodeinfo-test}"
SRC="${SCHEDULER_SRC:-$REPO/.upstream/edge-scheduler}"
DEST="${DEST:-$HOME/bin/pluginctl-nodeinfo}"
INNER="/app/pluginctl-linux-arm64"
[ "$(uname -m)" = "x86_64" ] && INNER="/app/pluginctl-linux-amd64"

# 1. the patched image: reuse the Tier 2 build if it exists, else build it.
if [ -n "${FORCE_BUILD:-}" ] || ! sudo podman image exists "$TAG"; then
  build_patched_scheduler_image "$SRC" "$TAG"
else
  log "reusing existing image $TAG (FORCE_BUILD=1 to rebuild)"
fi

# 2. copy the patched pluginctl out of the image (no container is started).
mkdir -p "$(dirname "$DEST")"
cid="$(sudo podman create "$TAG")"
trap 'sudo podman rm "$cid" >/dev/null 2>&1 || true' EXIT
sudo podman cp "$cid:$INNER" "$DEST" || fatal "could not copy $INNER out of $TAG"
sudo chown "$(id -u):$(id -g)" "$DEST" 2>/dev/null || true
chmod 0755 "$DEST"

# 3. verify: it runs on the host, and it carries the patch (stock binary does not).
"$DEST" run --help >/dev/null 2>&1 || fatal "$DEST does not run on this host"
grep -q wes-identity "$DEST" || fatal "$DEST does not contain the wes-identity patch"
log "installed patched pluginctl -> $DEST"
if ! kc -n "$NS_DEFAULT" get configmap "$IDENTITY_CM" -o jsonpath='{.data.WAGGLE_NODE_GPS_LAT}' 2>/dev/null | grep -q .; then
  warn "wes-identity has no GPS vars yet -- run ./test-add-configmap.sh (Tier 1) first"
fi
echo "-------------------------------------------------------------"
log "launch plugins with:  sudo $DEST run ... (same flags as pluginctl)"
log "verify a pod:  $KUBECTL get pod <name> -o jsonpath='{.spec.containers[0].envFrom}'"
log "     -> [{\"configMapRef\":{\"name\":\"wes-identity\",\"optional\":true}}]"
log "uninstall:  rm $DEST"
