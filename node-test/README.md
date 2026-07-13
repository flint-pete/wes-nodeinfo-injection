# node-test/ — side-load the change onto a real node

Install the change on a node, test pywaggle2 `get_node_info()` on real hardware, then
cleanly restore. The change MUTATES existing WES machinery (the `wes-identity`
ConfigMap + the scheduler), so **remove == restore-from-backup**, not delete.

Run these ON the node (`sudo kubectl`). Backups go to `.node-backup/` (gitignored) so
teardown works from a fresh shell; re-running `add` never clobbers an existing backup.

## Tier 1 — ConfigMap only (safe, seconds to revert, no scheduler change)

Tests Part A + the entire pywaggle2 read path without replacing any system binary.
Existing plugins are untouched (they don't consume `wes-identity` until Tier 2).

```bash
./test-add-configmap.sh      # backup wes-identity; regenerate w/ 5 vars from THIS
                             # node's manifest; launch a pod that reads it via explicit
                             # envFrom and prints the pywaggle2 NodeInfo
# ... inspect: real vsn + lat/lon for this node ...
./test-remove-configmap.sh   # restore original wes-identity; delete the pod
```

## Tier 2 — patched scheduler (control-plane; proves fleet-wide auto-injection)

Proves the scheduler auto-injects `envFrom: wes-identity` into EVERY plugin. Run Tier 1
first so the ConfigMap holds the 5 vars.

```bash
git -C ../.upstream/edge-scheduler apply ../patches/0002-*.patch   # prereq

./test-add-scheduler.sh      # podman-build patched scheduler, k3s-import, repoint the
                             # wes-plugin-scheduler Deployment (auto-reverts if the
                             # rollout doesn't go Ready)
# schedule any normal plugin, then:
#   sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'  # -> wes-identity
./test-remove-scheduler.sh   # restore original scheduler image
```

`test-add-scheduler.sh` auto-reverts on a failed rollout; `test-remove-scheduler.sh` is
always safe to run. Build notes baked into the script (learned on H00F): build needs
`sudo podman`; the bare `FROM` in the Dockerfile is fully-qualified to `docker.io/...`
via a throwaway copy (the node's registries.conf has no unqualified-search); the
multi-stage build needs `--build-arg TARGETARCH/VERSION` (Go compiles inside the
container — no host Go).

Gotcha for the real upload path: `pluginctl run` from a node with a stale host
`pluginctl` builds pods client-side and won't show injection — schedule via the patched
scheduler daemon (cloud/sesctl), or update the host binary too.

## Files

```
lib.sh                    shared: kubectl wrapper, one-shot backup/restore, node vsn
test-add-configmap.sh     Tier 1 up
test-remove-configmap.sh  Tier 1 down
test-plugin-pod.yaml      Tier 1 pywaggle2 reader pod (explicit envFrom)
test-add-scheduler.sh     Tier 2 up (build + side-load + patch Deployment)
test-remove-scheduler.sh  Tier 2 down (restore Deployment)
```

The Tier-1 pod runs `node_info_env.py` (byte-equivalent to `../pywaggle2/`) against the
real injected env and prints `NodeInfo`. Both tiers are verified on live H00F; see
`../HANDOFF.md`.
