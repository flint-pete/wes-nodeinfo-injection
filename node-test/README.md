# node-test/ — side-load the change onto a real node before upstream merge

Because the two upstream patches aren't merged yet, these scripts install the change
on a node (H00F or any), let you test pywaggle2 `get_node_info()` on real hardware,
and then cleanly restore. Analogous to wes-local-cache-manager's
test-add-node.sh/test-remove-node.sh — but this change MUTATES existing WES machinery
(the `wes-identity` ConfigMap + the scheduler) rather than deploying a standalone
DaemonSet, so **remove == restore-from-backup**, not delete.

Run these ON the node (H00F needs `sudo kubectl`). Backups go to `.node-backup/`
(gitignored) so teardown works even from a fresh shell. Re-running add is safe (it
never clobbers an existing backup).

## Two tiers (escalating blast radius)

### Tier 1 — ConfigMap only (safe, seconds to revert, no scheduler change)
Tests Part A + the entire pywaggle2 read path without replacing any system binary.

```bash
./test-add-configmap.sh      # backup wes-identity; regenerate it w/ 5 vars from THIS
                             # node's manifest; launch a test pod that reads it via
                             # explicit envFrom and prints the pywaggle2 NodeInfo
# ... inspect the printed NodeInfo: real vsn + lat/lon for this node ...
./test-remove-configmap.sh   # restore original wes-identity; delete test pod
```

Existing plugins are untouched in Tier 1 (they don't consume `wes-identity` until the
scheduler change). This is the daily-driver loop.

### Tier 2 — patched scheduler (higher risk: replaces the control-plane scheduler)
Proves the scheduler auto-injects `envFrom: wes-identity` into EVERY plugin (no
per-pod edit). Run Tier 1 first so the ConfigMap actually holds the 5 vars.

```bash
# prereq: apply patch 0002 into the source the script builds from
git -C ../.upstream/edge-scheduler apply ../patches/0002-*.patch

./test-add-scheduler.sh      # podman-build patched scheduler, k3s-import, point the
                             # wes-plugin-scheduler Deployment at it (auto-reverts if
                             # the rollout doesn't go Ready)
# ... schedule any normal plugin (pluginctl/sesctl), then:
#   sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'
#   -> should show wes-identity ; the plugin's pywaggle2 sees node-info
./test-remove-scheduler.sh   # restore original scheduler image (waggle/edge-scheduler:0.28.0)
```

Tier 2 touches the control plane: if the patched scheduler crashlooped, plugin
scheduling would stall until revert — so `test-add-scheduler.sh` auto-reverts on a
failed rollout, and `test-remove-scheduler.sh` is always safe to run.

## Testing pywaggle2 specifically

The Tier-1 test pod (`test-plugin-pod.yaml`) IS the pywaggle2 harness: it runs the
`node_info_env.py` reader (inlined, byte-equivalent to `../pywaggle2/node_info_env.py`)
against the real injected env and prints the resolved `NodeInfo`. To go further —
prove a real geotagged upload — swap the pod's command for image-sampler2 wired to
`_runtime_identity()` reading these env vars, then confirm via the data API that the
upload carried this node's real lat/lon.

## Files
```
lib.sh                  shared: kubectl wrapper, one-shot backup/restore, node vsn
test-add-configmap.sh   Tier 1 up
test-remove-configmap.sh Tier 1 down
test-plugin-pod.yaml    Tier 1 pywaggle2 reader pod (explicit envFrom)
test-add-scheduler.sh   Tier 2 up (build + side-load + patch Deployment)
test-remove-scheduler.sh Tier 2 down (restore Deployment)
```

## Verified (local, pre-node)
- all scripts pass `bash -n`; pod YAML parses
- Tier-1 add/remove control flow verified against a FAKE kubectl + h00f fixture
  (backup → regenerate 5-var env → create CM → deploy pod → restore → cleanup)

On-node run is the remaining live step (needs a maintenance window on the target).
