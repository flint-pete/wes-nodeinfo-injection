#!/usr/bin/env bash
# lib.sh -- shared helpers for the node side-load test scripts (source, don't run).
#
# These scripts side-load the wes-nodeinfo-injection change onto a node BEFORE the
# upstream patches are merged, so we can test pywaggle2 get_node_info() on real
# hardware, then cleanly restore. Modeled on wes-local-cache-manager's
# test-add-node.sh / test-remove-node.sh, but this change MUTATES existing WES
# machinery (the wes-identity ConfigMap + the scheduler) rather than deploying a
# standalone DaemonSet -- so "remove" means RESTORE, not delete.
#
# Run these ON the node (sudo kubectl required on H00F), or set KUBECTL to a remote
# wrapper. All backups land in ./.node-backup/ (gitignored) so remove/restore works
# even in a fresh shell.
set -euo pipefail

KUBECTL="${KUBECTL:-sudo kubectl}"
NS_DEFAULT="default"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.node-backup}"
WAGGLE_CONFIG_DIR="${WAGGLE_CONFIG_DIR:-/etc/waggle}"
IDENTITY_CM="wes-identity"
SCHED_DEPLOY="wes-plugin-scheduler"
TEST_POD="wes-nodeinfo-test"

log()   { printf '\033[1;36m[nodeinfo-test]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

kc() { $KUBECTL "$@"; }

need() { command -v "${1%% *}" >/dev/null 2>&1 || fatal "missing required tool: $1"; }

ensure_backup_dir() { mkdir -p "$BACKUP_DIR"; }

# Back up a resource to yaml ONCE (never overwrite a prior backup -> safe re-run).
backup_resource() {  # $1=kind $2=name [$3=ns]
  local kind="$1" name="$2" ns="${3:-$NS_DEFAULT}"
  local f="$BACKUP_DIR/${kind}_${name}.yaml"
  ensure_backup_dir
  if [ -e "$f" ]; then
    warn "backup already exists ($f) -- keeping the ORIGINAL, not re-backing-up."
    return 0
  fi
  if kc -n "$ns" get "$kind" "$name" -o yaml > "$f" 2>/dev/null; then
    log "backed up $kind/$name -> $f"
  else
    warn "$kind/$name not present to back up (fresh create expected)"
    echo "__ABSENT__" > "$f"   # marker: restore = delete
  fi
}

restore_resource() {  # $1=kind $2=name [$3=ns]
  local kind="$1" name="$2" ns="${3:-$NS_DEFAULT}"
  local f="$BACKUP_DIR/${kind}_${name}.yaml"
  [ -e "$f" ] || { warn "no backup for $kind/$name -- nothing to restore"; return 0; }
  if grep -q '^__ABSENT__$' "$f"; then
    log "original $kind/$name was absent -> deleting the test one"
    kc -n "$ns" delete "$kind" "$name" --ignore-not-found >/dev/null
  else
    log "restoring $kind/$name from backup"
    kc -n "$ns" apply -f "$f" >/dev/null
  fi
  rm -f "$f"
}

node_vsn() { awk '{print toupper($0)}' "$WAGGLE_CONFIG_DIR/vsn" 2>/dev/null || echo "?"; }
