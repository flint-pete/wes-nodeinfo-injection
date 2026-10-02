# TESTING.md — verifying & side-loading wes-nodeinfo-injection

Operator guide: how to verify the change offline, side-load it onto a live node, and
restore. Read this before running anything on a node. CI-team summary: `HANDOFF.md`.

---

## TL;DR

| You want to… | Do this | Risk |
|---|---|---|
| Verify the change offline | `make test` | none |
| Confirm patches still apply | `make patches-check` | none |
| Build the real patched scheduler | `make test-upstream` | none (local build) |
| Test pywaggle2 on a real node, safely | `node-test/` **Tier 1** | low, seconds to revert |
| Prove all plugins auto-get node-info | `node-test/` **Tier 2** | control-plane; auto-reverts |

The change ships as **two patches** (`patches/`) against two upstream repos. Nothing
is pushed upstream; side-loading is how we test before merge. Because the change
mutates existing WES objects (the `wes-identity` ConfigMap + the scheduler),
**teardown is restore-from-backup, not delete**.

---

## What the change is

A running plugin cannot learn its own VSN / GPS today. This change gives every
scheduler-launched plugin five env vars that pywaggle2's `read_node_info()` reads
(a `Plugin.get_node_info()` wrapper is the proposed future upstream API):

```
WAGGLE_NODE_ID  WAGGLE_NODE_VSN  WAGGLE_NODE_GPS_LAT  WAGGLE_NODE_GPS_LON  WAGGLE_NODE_MOBILITY
```

- **Part A** (`patches/0001`, waggle-edge-stack `update-stack.sh`): add GPS+mobility to
  the existing `wes-identity` ConfigMap (today it holds only ID+VSN).
- **Part B** (`patches/0002`, edge-scheduler `resourcemanager.go`): add
  `EnvFrom: wes-identity` (Optional) to the plugin container the scheduler builds.

pywaggle2 normalizes sentinels → `None`/`"unknown"` so plugin authors never see
`0`/`999`/`""` (contract in `pywaggle2/node_info_env.py`). Full rationale + the
whitelist argument (why not mount the raw manifest) are in `HANDOFF.md`.

---

## Offline verification (no node, no risk)

```bash
make test            # 3 layers: env-gen (32) + Go unit (4) + e2e (7)
make patches-check   # both patches apply clean to the recorded base commits
make test-upstream   # builds the REAL upstream edge-scheduler w/ patch + runs its tests
```

`make test` is the canonical command and is self-contained (needs host `bash`, `jq`,
Go at `/usr/local/go`, `python3`). `.upstream/` clones are needed only for the latter
two (see README "Populating `.upstream/`"). Host Go is needed only for these offline
tests — not for the on-node Tier 2 build.

---

## Side-load onto a real node

Run **on the node**. Scripts use `$KUBECTL`: default `sudo kubectl` if `kubectl` is on
PATH, else `sudo k3s kubectl` (override by exporting `KUBECTL`).
Backups land in `node-test/.node-backup/` (gitignored) so teardown works from any
shell; re-running `add` never clobbers an existing backup.

### Tier 1 — ConfigMap only (SAFE, start here)

Tests Part A + the full pywaggle2 read path. Replaces no system binary; existing
plugins are unaffected (they don't consume `wes-identity` until Tier 2).

```bash
cd node-test
./test-add-configmap.sh
#   → backs up wes-identity, regenerates it with 5 vars from THIS node's real manifest,
#     launches the wes-nodeinfo-test pod (reads the CM via explicit envFrom), prints
#     the resolved pywaggle2 NodeInfo (real vsn + lat/lon; mobility="unknown" until the
#     manifest gains a mobility field)
./test-remove-configmap.sh
#   → restores the original wes-identity, deletes the test pod
```

Revert time: seconds. Worst case if you walk away: `wes-identity` carries 3 extra vars
nothing consumes yet (harmless) plus one idle test pod.

### Tier 2 — patched scheduler (CONTROL PLANE, deliberate)

Proves the scheduler auto-injects `envFrom: wes-identity` into **every** plugin with no
per-pod edit. Run Tier 1 first so the ConfigMap holds the 5 vars.

Tier 2 needs on the node: `sudo podman`, `git`, network access to docker.io, and
`.upstream/edge-scheduler` populated at `5391a00` (README). No host Go.

```bash
cd node-test
git -C ../.upstream/edge-scheduler apply "$(realpath ../patches/0002-edge-scheduler-envfrom-wes-identity.patch)"   # prereq (run from node-test/)

./test-add-scheduler.sh
#   → podman-builds the patched scheduler (native, on-node), imports into k3s
#     containerd, repoints the wes-plugin-scheduler Deployment; AUTO-REVERTS if the
#     rollout doesn't go Ready

# schedule a plugin via SES (sesctl) - stock pluginctl pods don't count - then confirm injection:
sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'
#   → lists wes-identity ; the plugin's pywaggle2 now sees node-info

./test-remove-scheduler.sh
#   → restores the original scheduler image
```

Note: `pluginctl run` builds the pod client-side with the host `/usr/bin/pluginctl`'s
own (unpatched) pod builder, so pluginctl-launched pods will NOT show injection —
schedule via the patched scheduler daemon (cloud/sesctl), use an explicit
`envFrom`, or launch with the patched binary from `./install-pluginctl-nodeinfo.sh`
(Tier 1b, `/usr/local/bin/pluginctl-nodeinfo`).

---

## Risks & mitigations (side-load)

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Tier-2 scheduler crashloops → scheduling stalls | low | high (until revert) | `test-add-scheduler.sh` auto-reverts on failed rollout; `test-remove-scheduler.sh` always safe; deployment backed up first |
| R2 | Side-loaded scheduler image lost on node **reboot** | usually persists (survived a power-cut reboot on H041), not guaranteed | high if lost: the Deployment patch persists in the k3s datastore, so the scheduler pod goes `ImagePullBackOff` and plugin scheduling stalls | after any reboot check the scheduler pod; if `ImagePullBackOff`, run `test-remove-scheduler.sh` immediately (restores the stock image) or re-run `test-add-scheduler.sh`. Tier 2 has never been tested across a reboot |
| R3 | `wes-identity` overwritten by a real update-stack run mid-test | low | low | a real update-stack regenerates from manifest anyway; restore from backup if needed |
| R4 | `mobility` absent from manifest → always "unknown" | today | low | correct-by-design; pywaggle2 treats unknown conservatively |
| R5 | Manifest GPS stale/wrong → plugin gets bad coords | node-dependent | medium | out of scope; surfaced as-is. Mobile nodes use live gpsd, not this static env |
| R6 | Explicit plugin env collides with an injected var | very low | none | k8s applies `Env` over `EnvFrom` → explicit wins (verified) |
| R7 | Tier 2 without Tier 1 → envFrom points at a CM missing gps/mobility | operator error | low | scripts + docs require Tier 1 first; `Optional` envFrom degrades gracefully |
| R8 | `wes-identity` back to 2 vars after a reboot or WES (re)install / `update-stack.sh` run | update-stack: always (it regenerates the CM); reboot: seen once on H00F, not on H041 | low (GPS/mobility read as `None`/`"unknown"`) | after any reboot, check `sudo k3s kubectl get cm wes-identity -o yaml`; if the GPS/MOBILITY vars are missing re-run `test-add-configmap.sh` (idempotent). Always re-run it after a WES (re)install / update-stack |

**Rollback of record:** `test-remove-configmap.sh` then `test-remove-scheduler.sh`
returns the node to stock — both idempotent, safe to re-run. The only residue after
full teardown is the unreferenced side-loaded image in containerd; prune with
`sudo k3s ctr images rm docker.io/library/edge-scheduler:nodeinfo-test`.

---

After a node reboot, also see the hub runbook
[REBOOT-RECOVERY.md](https://github.com/flint-pete/media-sampler3/blob/master/REBOOT-RECOVERY.md).

---

## Upstream / CI follow-ups

See `HANDOFF.md` → "Folding into base CI" for the merge + rollout plan. In brief: merge
both patches, cut a scheduler release, add the `mobility` manifest field (default
`static`), and land the pywaggle2 reader in `waggle/data/`.
