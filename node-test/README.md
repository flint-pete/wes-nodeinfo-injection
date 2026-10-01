# node-test/ — side-load the change onto a real node

Install the change on a node, test the pywaggle2 reader `read_node_info()` on real
hardware, then
cleanly restore. The change MUTATES existing WES machinery (the `wes-identity`
ConfigMap + the scheduler), so **remove == restore-from-backup**, not delete.

Run these ON the node. kubectl is `$KUBECTL`: default `sudo kubectl` if a `kubectl`
binary is on PATH, else `sudo k3s kubectl`; override with e.g.
`KUBECTL="sudo k3s kubectl" ./test-add-configmap.sh`. Backups go to `.node-backup/`
(gitignored) so teardown works from a fresh shell; re-running `add` never clobbers an
existing backup. If the backup step cannot read an object for any reason other than
"NotFound" (e.g. no cluster access), the script stops instead of recording it as
absent — otherwise teardown would delete the real object.

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
# prereq: .upstream/edge-scheduler populated at 5391a00 (see ../README.md), then:
git -C ../.upstream/edge-scheduler apply "$(realpath ../patches/0002-edge-scheduler-envfrom-wes-identity.patch)"   # prereq (run from node-test/)

./test-add-scheduler.sh      # podman-build patched scheduler, k3s-import, repoint the
                             # wes-plugin-scheduler Deployment (auto-reverts if the
                             # rollout doesn't go Ready)
# schedule any normal plugin, then:
#   sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'  # -> wes-identity
./test-remove-scheduler.sh   # restore original scheduler image
```

`test-add-scheduler.sh` auto-reverts on a failed rollout; `test-remove-scheduler.sh` is
always safe to run. What the Tier-2 build needs (all handled by the script):
`sudo podman`; network access to docker.io (the Dockerfile's bare `FROM` is
fully-qualified to `docker.io/...` in a throwaway copy, because the node's
registries.conf has no unqualified-search); `--build-arg TARGETARCH/VERSION`. Go
compiles inside the container — **no host Go** is needed on the node.

**`pluginctl run` pods do not get the injection.** The host `pluginctl` builds pods
client-side with its own (unpatched) pod builder, so only pods created by the patched
scheduler daemon (jobs via cloud/sesctl) get `envFrom: wes-identity`. To see Tier 2
work, schedule a job, or give the pod an explicit `envFrom` (as the Tier-1 pod does).

**After a reboot:** a side-loaded image usually survives, but not guaranteed. The
Deployment patch *does* persist (k3s datastore), so if the image is gone the scheduler
pod goes `ImagePullBackOff` — run `./test-remove-scheduler.sh` at once (restores the
stock scheduler), or re-run `./test-add-scheduler.sh`. Tier 2 has never been tested
across a reboot. Also check `wes-identity` still has the GPS/MOBILITY vars; if not,
re-run `./test-add-configmap.sh` (idempotent). See `../TESTING.md` (R2, R8) and the
hub [REBOOT-RECOVERY.md](https://github.com/flint-pete/media-sampler3/blob/master/REBOOT-RECOVERY.md).

## Files

```
lib.sh                    shared: kubectl wrapper, one-shot backup/restore, node vsn
test-add-configmap.sh     Tier 1 up
test-remove-configmap.sh  Tier 1 down
test-plugin-pod.yaml      Tier 1 pywaggle2 reader pod (explicit envFrom)
test-add-scheduler.sh     Tier 2 up (build + side-load + patch Deployment)
test-remove-scheduler.sh  Tier 2 down (restore Deployment)
```

The Tier-1 pod runs a semantically equivalent inline copy of `read_node_info()` (a
condensed version of `../pywaggle2/node_info_env.py`, not byte-identical) against the
real injected env and prints `NodeInfo`. Both tiers were verified on live H00F; see
`../HANDOFF.md` and the history in `../docs/history/NOTES.md`.
