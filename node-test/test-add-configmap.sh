#!/usr/bin/env bash
# test-add-configmap.sh -- TIER 1 (safe, reversible, no scheduler change).
#
# Regenerates the wes-identity ConfigMap WITH the 3 new node vars (gps_lat/lon +
# mobility) from THIS node's real manifest, then launches a test pod that mounts it
# via explicit envFrom and runs the pywaggle2 reader -> proves the ConfigMap->env->
# pywaggle2 chain on real hardware. Reverts with test-remove-configmap.sh.
#
# Blast radius: only the wes-identity ConfigMap (backed up first) + one test pod.
# Existing plugins are UNAFFECTED (they don't consume wes-identity until the
# scheduler change, Tier 2). Run ON the node.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
REPO="$(cd "$HERE/.." && pwd)"

need "$KUBECTL"; need jq; need awk

log "node VSN: $(node_vsn)  (config dir: $WAGGLE_CONFIG_DIR)"

# 1. back up the current wes-identity ConfigMap
backup_resource configmap "$IDENTITY_CM"

# 2. regenerate wes-identity.env from the real node manifest (the Part A change)
tmpenv="$(mktemp)"; trap 'rm -f "$tmpenv"' EXIT
WAGGLE_CONFIG_DIR="$WAGGLE_CONFIG_DIR" bash "$REPO/gen-wes-identity.sh" > "$tmpenv"
log "generated wes-identity.env:"; sed 's/^/    /' "$tmpenv"

# 3. apply it as the wes-identity ConfigMap (server-side replace, keeps name/labels)
kc create configmap "$IDENTITY_CM" --from-env-file="$tmpenv" \
   --dry-run=client -o yaml | kc apply -f - >/dev/null
log "wes-identity ConfigMap updated with 5 node vars"

# 4. launch the test pod (explicit envFrom: wes-identity; no scheduler change needed)
kc delete pod "$TEST_POD" --ignore-not-found >/dev/null
kc apply -f "$HERE/test-plugin-pod.yaml" >/dev/null
log "waiting for $TEST_POD to finish..."
# The pod is restartPolicy:Never and prints+exits in ~1s, so it may never report
# Ready=True (it races straight to Succeeded). Wait for a TERMINAL phase instead:
# Succeeded is the happy path; if it Failed we still want the logs to see why.
# `kubectl wait` needs a positive jsonpath match, so race Succeeded vs Failed and
# fall back to a short poll if the image is still pulling.
if ! kc wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$TEST_POD" --timeout=90s >/dev/null 2>&1; then
  kc wait --for=jsonpath='{.status.phase}'=Failed pod/"$TEST_POD" --timeout=5s >/dev/null 2>&1 || true
  phase="$(kc get pod "$TEST_POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo '?')"
  [ "$phase" = "Failed" ] && warn "$TEST_POD ended in Failed phase -- logs below should show why"
  [ "$phase" = "Pending" ] && warn "$TEST_POD still Pending after 90s (image pull?) -- logs may be empty"
fi

echo "-------------------------------------------------------------"
log "pywaggle2 read_node_info() ON THIS NODE:"
kc logs "$TEST_POD" 2>&1 | sed 's/^/    /' || warn "no logs yet (pod may still be pulling)"
echo "-------------------------------------------------------------"
log "verify the NodeInfo above shows THIS node's real vsn + lat/lon."
log "when done:  ./test-remove-configmap.sh"
