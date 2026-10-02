#!/usr/bin/env bash
# lib.sh -- shared helpers for the node side-load test scripts (source, don't run).
#
# These scripts side-load the wes-nodeinfo-injection change onto a node BEFORE the
# upstream patches are merged, so we can test the pywaggle2 reader (read_node_info()) on real
# hardware, then cleanly restore. Modeled on wes-local-cache-manager's
# test-add-node.sh / test-remove-node.sh, but this change MUTATES existing WES
# machinery (the wes-identity ConfigMap + the scheduler) rather than deploying a
# standalone DaemonSet -- so "remove" means RESTORE, not delete.
#
# Run these ON the node, or set KUBECTL to a remote wrapper. Default KUBECTL is
# `sudo kubectl` if a kubectl binary is on PATH, else `sudo k3s kubectl` if k3s is
# (a Thor/k3s node may have only the k3s binary). All backups land in
# ./.node-backup/ (gitignored) so remove/restore works even in a fresh shell.
set -euo pipefail

if [ -z "${KUBECTL:-}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL="sudo kubectl"
  elif command -v k3s >/dev/null 2>&1; then
    KUBECTL="sudo k3s kubectl"
  else
    KUBECTL="sudo kubectl"   # `need "$KUBECTL"` will report what's missing
  fi
fi
NS_DEFAULT="default"
BACKUP_DIR="${BACKUP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.node-backup}"
WAGGLE_CONFIG_DIR="${WAGGLE_CONFIG_DIR:-/etc/waggle}"
IDENTITY_CM="wes-identity"
SCHED_DEPLOY="${SCHED_DEPLOY:-wes-plugin-scheduler}"
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
  # Only a genuine NotFound may be recorded as __ABSENT__ (restore would then DELETE
  # the object). Any other failure -- no cluster access, wrong kubeconfig, kubectl
  # missing -- must abort, or teardown would delete a real wes-identity/scheduler.
  local err rc=0
  err="$(kc -n "$ns" get "$kind" "$name" -o yaml 2>&1 >"$f")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "backed up $kind/$name -> $f"
  elif printf '%s' "$err" | grep -qE '\(NotFound\)|"'"$name"'" not found'; then
    warn "$kind/$name not present to back up (fresh create expected)"
    echo "__ABSENT__" > "$f"   # marker: restore = delete
  else
    rm -f "$f"
    fatal "could not read $kind/$name to back it up (kubectl: ${err:-exit $rc}). Refusing to continue: recording it as absent would make restore DELETE it. Check cluster access, e.g. KUBECTL=\"sudo k3s kubectl\"."
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
    # NOTE: `kubectl apply -f backup.yaml` does a 3-way strategic merge keyed on
    # last-applied-configuration + resourceVersion. When the live object was mutated
    # by a NON-apply op (our `create configmap ... | apply` regen bumps the RV and the
    # data), the backup's stale resourceVersion makes apply fail with a Conflict and
    # the object is NOT restored (observed on H00F, Gate 1). So DON'T apply the raw
    # backup. Strip the volatile metadata (resourceVersion/uid/creationTimestamp) and
    # `kubectl replace` for an imperative full-object overwrite; fall back to
    # delete+create if replace can't reconcile (e.g. immutable field drift).
    # Build the restore payload FROM THE BACKUP (source of truth), not the live object.
    local payload
    payload="$(jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.status,
                       .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' \
                 <(kc_yaml2json "$f") 2>/dev/null)"
    if [ -z "$payload" ] || [ "$payload" = "null" ]; then
      warn "could not parse backup $f as json -- trying raw apply as last resort"
      kc -n "$ns" apply -f "$f" >/dev/null || { warn "restore FAILED for $kind/$name -- backup KEPT at $f"; return 1; }
    elif ! printf '%s' "$payload" | kc -n "$ns" replace -f - >/dev/null 2>&1; then
      warn "replace failed -> delete+recreate $kind/$name"
      kc -n "$ns" delete "$kind" "$name" --ignore-not-found >/dev/null
      printf '%s' "$payload" | kc -n "$ns" create -f - >/dev/null \
        || { warn "restore FAILED for $kind/$name -- backup KEPT at $f"; return 1; }
    fi
  fi
  rm -f "$f"
}

# Convert a kubectl-dumped YAML backup to JSON (we always dump -o yaml). Uses python3
# if present (always on these nodes), else assumes the file is already JSON.
kc_yaml2json() {  # $1 = path to yaml
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
  else
    cat "$1"
  fi
}

node_vsn() { awk '{print toupper($0)}' "$WAGGLE_CONFIG_DIR/vsn" 2>/dev/null || echo "?"; }

# Build the PATCHED edge-scheduler image (patch 0002) with podman, natively.
# Shared by test-add-scheduler.sh (Tier 2) and install-pluginctl-nodeinfo.sh (Tier 1b):
# one build produces BOTH the patched scheduler daemon and a patched pluginctl.
# Notes learned on H00F: (a) build needs root here (sudo podman); (b) this node's
# /etc/containers/registries.conf defines no unqualified-search registries, so the
# Dockerfile's bare `FROM waggle/plugin-base` won't resolve -- fully-qualify it to
# docker.io in a throwaway Dockerfile so we never dirty the packaged (patched) one;
# (c) the multi-stage Dockerfile compiles Go INSIDE the container, so no host Go is
# needed, but it DOES require --build-arg TARGETARCH and VERSION.
build_patched_scheduler_image() {  # $1=source dir  $2=image tag
  local src="$1" tag="$2" arch targetarch
  [ -d "$src" ] || fatal "edge-scheduler source not found at $src (see README: populate .upstream/)"
  grep -q 'wes-identity' "$src/pkg/nodescheduler/resourcemanager.go" \
    || fatal "patch 0002 not applied in $src -- run: git -C $src apply \"\$(realpath ../patches/0002-edge-scheduler-envfrom-wes-identity.patch)\""
  log "patch 0002 confirmed present in scheduler source"
  arch="$(uname -m)"
  case "$arch" in aarch64|arm64) targetarch=arm64;; x86_64|amd64) targetarch=amd64;; *) fatal "unsupported arch $arch";; esac
  log "building $tag (podman, native, TARGETARCH=$targetarch) ..."
  (
    cd "$src"
    sed 's|^FROM waggle/plugin-base|FROM docker.io/waggle/plugin-base|' Dockerfile > Dockerfile.nodeinfo-build
    trap 'rm -f Dockerfile.nodeinfo-build' EXIT
    sudo podman build -f Dockerfile.nodeinfo-build \
      --build-arg TARGETARCH="$targetarch" --build-arg VERSION=nodeinfo-test \
      -t "$tag" .
  ) || fatal "podman build failed"
}
