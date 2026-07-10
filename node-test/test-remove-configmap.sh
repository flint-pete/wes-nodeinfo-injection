#!/usr/bin/env bash
# test-remove-configmap.sh -- TIER 1 teardown. Restores the original wes-identity
# ConfigMap from backup and deletes the test pod. Safe to run repeatedly.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
need "$KUBECTL"

log "deleting test pod $TEST_POD"
kc delete pod "$TEST_POD" --ignore-not-found >/dev/null

restore_resource configmap "$IDENTITY_CM"
log "Tier 1 reverted: wes-identity restored, test pod removed."
