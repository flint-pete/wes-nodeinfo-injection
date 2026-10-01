#!/usr/bin/env bash
# test-remove-scheduler.sh -- TIER 2 teardown. Restores the original
# wes-plugin-scheduler Deployment (reverting to the original image recorded in the
# backup by test-add-scheduler.sh) and
# waits for it to come back healthy. Leaves the side-loaded image in containerd
# (harmless; k3s ignores it once unreferenced). Safe to run repeatedly.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
need "$KUBECTL"

restore_resource deployment "$SCHED_DEPLOY"
log "waiting for original scheduler to roll back healthy ..."
kc -n "$NS_DEFAULT" rollout status "deployment/$SCHED_DEPLOY" --timeout=120s \
  || warn "rollback rollout not confirmed -- check: $KUBECTL -n $NS_DEFAULT get pods -l app=$SCHED_DEPLOY"
log "Tier 2 reverted: scheduler restored to its original image."
log "(the side-loaded test image remains in k3s containerd; prune with: sudo k3s ctr images rm docker.io/library/edge-scheduler:nodeinfo-test)"
