# TESTING.md — testing & side-loading the wes-nodeinfo-injection change

Authoritative operator guide. Covers **how** to verify and side-load the change,
**why** it's structured this way, and **what can go wrong**. Read this before running
anything on a live node.

Design reference: `~/AI-projects/pywaggle2-design.md` §2.4 (grounded in WES source +
live H00F/W096 inspection). Deliverable summary: `HANDOFF.md`.

---

## 0. TL;DR

| You want to… | Do this | Risk |
|---|---|---|
| Verify the change offline | `make test` | none |
| Confirm patches still apply | `make patches-check` | none |
| Build the real patched scheduler | `make test-upstream` | none (local build) |
| Test pywaggle2 on a real node, safely | `node-test/` **Tier 1** | low, seconds to revert |
| Prove all plugins auto-get node-info | `node-test/` **Tier 2** | control-plane; auto-reverts |

The change ships as **two patches** (`patches/`) against two upstream repos. Nothing
is pushed upstream; side-loading is how we test before merge.

---

## 1. What the change is (one screen)

A running plugin cannot learn its own VSN / GPS today (verified: plugin pods have no
`WAGGLE_NODE_*` env and no manifest mount). This change gives every plugin five env
vars so pywaggle2 can expose `get_node_info()`:

```
WAGGLE_NODE_ID  WAGGLE_NODE_VSN  WAGGLE_NODE_GPS_LAT  WAGGLE_NODE_GPS_LON  WAGGLE_NODE_MOBILITY
```

Delivered by reusing WES machinery that already exists:

- **Part A** (`patches/0001`, waggle-edge-stack `update-stack.sh`): add GPS+mobility
  to the **existing** `wes-identity` ConfigMap (today it holds only ID+VSN).
- **Part B** (`patches/0002`, edge-scheduler `resourcemanager.go`): add
  `EnvFrom: wes-identity` (Optional) to the plugin container the scheduler builds.

pywaggle2 normalizes sentinels → `None` so plugin authors never see `0`/`999`/`""`
(sentinel contract in `pywaggle2/node_info_env.py`).

---

## 2. Why this approach (design rationale)

### 2.1 Why env vars, not a mounted manifest
WES already splits config **scalars→env, structured→curated file, raw manifest→host
only** (source-confirmed). We extend that existing split rather than invent a new one.
Env is the minimal, lowest-risk channel and works for non-Python plugins with zero
parsing.

### 2.2 Why NOT mount the raw manifest
Verified on real nodes: `node-manifest-v2.json` carries sensor URIs (internal IPs, and
camera creds on credentialed-URI nodes), LoRaWAN DevEUIs, hardware serials, modem
config, and precise street address. Mounting it wholesale would leak all of that to
every third-party plugin. The env projection is an inherent **whitelist** — WES picks
each var explicitly — so nothing sensitive rides along. (A richer, still-whitelisted
`node-info.json` file channel is designed in §2.4.3 but deliberately **not** built
here; env covers the 5 identity scalars.)

### 2.3 Why reuse `wes-identity` instead of a new ConfigMap
It already exists, is already regenerated per-node by `update-stack.sh`, and is
already consumed by WES system pods via `envFrom`. Adding 3 vars + one `envFrom` line
is a smaller, more reviewable diff than standing up new plumbing.

### 2.4 Why `Optional: true` on the EnvFrom
A node whose WES hasn't regenerated the ConfigMap yet must still schedule plugins.
Optional makes the projection a no-op on un-migrated nodes → safe, incremental rollout.

### 2.5 Why two test tiers (and why side-load at all)
The change lives in **two layers**: config generation (Part A) and the scheduler
binary (Part B). They fail/rollback independently and have very different blast radii.
Because the patches aren't merged upstream, the only way to exercise them on real
hardware is to side-load — mirroring what we did for wes-local-cache-manager, except
this change **mutates existing WES objects** (ConfigMap + scheduler) rather than
deploying a standalone DaemonSet. So teardown is **restore-from-backup**, not delete.

Splitting into tiers lets us validate ~90% of the change (Part A + the whole pywaggle2
read path) with a near-zero-risk ConfigMap edit, and only touch the control plane
(Part B) as a deliberate, separate step.

---

## 3. Offline verification (no node, no risk)

```bash
make test            # 3 layers: env-gen (32) + Go unit (4) + e2e (7)
make patches-check   # both patches apply clean to pristine upstream HEAD
make test-upstream   # builds the REAL upstream edge-scheduler w/ patch + runs its tests
```

All green as of last run. `make test` is the canonical command. `.upstream/` clones are
needed only for the latter two (see README for how to populate them).

---

## 4. Side-load onto a real node

Run **on the node** (H00F needs `sudo kubectl`; the scripts default `KUBECTL="sudo
kubectl"`). Backups land in `node-test/.node-backup/` (gitignored) so teardown works
from any shell, and re-running `add` never clobbers an existing backup.

### 4.1 Tier 1 — ConfigMap only (SAFE, start here)

Tests Part A + the full pywaggle2 read path. Does **not** replace any system binary.
Existing plugins are unaffected (they don't consume `wes-identity` until Tier 2).

```bash
cd node-test
./test-add-configmap.sh
#   → backs up wes-identity
#   → regenerates it with 5 vars from THIS node's real manifest
#   → launches wes-nodeinfo-test pod (reads the CM via explicit envFrom)
#   → prints the resolved pywaggle2 NodeInfo

# inspect: the NodeInfo should show this node's real vsn + lat/lon,
# mobility="unknown" (until the manifest gains a mobility field).

./test-remove-configmap.sh
#   → restores the original wes-identity, deletes the test pod
```

Revert time: seconds. Worst case if you walk away: `wes-identity` carries 3 extra vars
nothing consumes yet — harmless — plus one idle test pod.

### 4.2 Tier 2 — patched scheduler (CONTROL PLANE, deliberate)

Proves the scheduler auto-injects `envFrom: wes-identity` into **every** plugin with no
per-pod edit. Run Tier 1 first so the ConfigMap actually holds the 5 vars.

```bash
# apply patch 0002 into the source the script builds from
git -C ../.upstream/edge-scheduler apply ../patches/0002-*.patch

cd node-test
./test-add-scheduler.sh
#   → podman-builds the patched scheduler (native, on-node — ECR builder is broken)
#   → imports into k3s containerd
#   → repoints the wes-plugin-scheduler Deployment at it
#   → AUTO-REVERTS if the rollout doesn't go Ready

# schedule any normal plugin (pluginctl/sesctl), then confirm injection:
sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'
#   → should list wes-identity ; the plugin's pywaggle2 now sees node-info

./test-remove-scheduler.sh
#   → restores the original waggle/edge-scheduler:0.28.0 image
```

### 4.3 Testing pywaggle2 specifically

The Tier-1 pod (`test-plugin-pod.yaml`) **is** the pywaggle2 harness — it runs the
`node_info_env.py` reader against the real injected env and prints `NodeInfo`. To prove
a real geotagged upload, swap the pod's command for image-sampler2 wired to
`_runtime_identity()` reading these env vars, then confirm via the data API that the
upload carried this node's real lat/lon.

---

## 5. Risks & mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | **Tier 2 scheduler crashloops** → plugin scheduling stalls | low | high (until revert) | `test-add-scheduler.sh` auto-reverts on failed rollout; `test-remove-scheduler.sh` always safe; deployment backed up first |
| R2 | Side-loaded image lost on node **reboot** (k3s state clears; ECR side-load only) | certain on reboot | medium | documented; re-run `test-add-scheduler.sh` to restore. Tier 1 CM survives reboot |
| R3 | `wes-identity` overwritten by a WES **update-stack run** during test | low | low | test edit is idempotent-ish; a real update-stack regenerates from manifest anyway. Restore from backup if needed |
| R4 | `mobility` field **not yet in manifest** → always "unknown" | certain today | low (conservative) | correct-by-design; pywaggle2 treats unknown conservatively. CI to add the field (default `static`) |
| R5 | Manifest **GPS is stale/wrong** on a node → plugin gets bad coords | node-dependent | medium | out of scope for this change; surfaced as-is. Mobile nodes use live gpsd (Tier-2 GPS), not this env |
| R6 | Explicit plugin env **collides** with an injected var | very low | low | k8s applies `Env` over `EnvFrom` → explicit always wins (the precedence pywaggle2 wants). Verified in Go tests |
| R7 | Running Tier 2 **without Tier 1** → envFrom points at a CM missing gps/mobility | operator error | low | Tier 2 script + docs require Tier 1 first; Optional envFrom degrades gracefully |
| R8 | `podman build` fails on-node (runc `/proc/acpi`, Infra #2) | possible | medium | native podman build is the known-good path (unlike ECR); if it fails, that's the Infra #2 builder bug, not this change |

**Rollback of record:** `test-remove-configmap.sh` then `test-remove-scheduler.sh`
returns the node to stock. Both are idempotent and safe to re-run. The only state left
after full teardown is the (unreferenced) side-loaded image in containerd — prune with
`sudo k3s ctr images rm docker.io/library/edge-scheduler:nodeinfo-test`.

---

## 6. What's verified vs pending

**Verified (offline):** `make test` 3 layers green; real upstream scheduler builds +
tests pass with patch applied; both patches apply clean to HEAD; all side-load scripts
pass `bash -n`; Tier-1 add/remove flow validated against a fake kubectl + h00f fixture.

**Pending (needs a live node + maintenance window):** the actual on-node Tier 1 run
(first real-hardware pywaggle2 NodeInfo), then Tier 2 (auto-injection proof), then the
image-sampler2 geotagged-upload end-to-end.

---

## 7. Upstream / CI-owned follow-ups

1. Add a `mobility` field to `node-manifest-v2.json` (default `static`) — the only
   true schema change requested (design §2.3).
2. Decide on the optional phase-2 `node-info.json` curated file channel (§2.4.3).
3. Confirm whether the CI team's planned runtime "GPS call" is a gpsd wrapper so
   pywaggle2 wraps the same source (Tier-2 GPS; `WAGGLE_GPS_SERVER` is already injected).
4. Merge the two patches, then rollout: build the scheduler image + regenerate
   `wes-identity` fleet-wide. `Optional: true` makes this safely incremental.
