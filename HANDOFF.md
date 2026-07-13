# HANDOFF — wes-nodeinfo-injection (for the Sage CI team)

The WES ("Part B") change that feeds pywaggle2's `get_node_info()`. Delivered as two
patches against upstream, verified end-to-end on live hardware. Nothing has been
pushed upstream — this repo is the review + test harness; `patches/` is the
deliverable.

## What it does

Gives every plugin pod five node-identity env vars so a running plugin can learn its
own VSN, node_id, GPS, and mobility:

```
WAGGLE_NODE_ID  WAGGLE_NODE_VSN  WAGGLE_NODE_GPS_LAT  WAGGLE_NODE_GPS_LON  WAGGLE_NODE_MOBILITY
```

Do NOT mount the raw `node-manifest-v2.json` into plugin pods — it leaks sensor
URIs/creds, LoRaWAN DevEUIs, hardware serials, modem config, and precise street
address (verified on H00F + W096). The env projection is an inherent whitelist: WES
picks each var explicitly, so nothing sensitive rides along.

## How it works — the two patches (both apply clean to upstream HEAD)

### 1. waggle-edge-stack — `kubernetes/update-stack.sh` (`update_wes`)
`patches/0001-*.patch`. Today `update_wes` writes only `WAGGLE_NODE_{ID,VSN}` into
`configs/wes-identity.env` (→ the `wes-identity` ConfigMap). The patch adds three
manifest-sourced vars via `jq`, in the same style, with sentinels for absent values
(`999` for missing coords — off-globe, since `0` is a real coordinate; empty for
missing mobility):

```sh
WAGGLE_NODE_GPS_LAT=$(jq -r '(.gps_lat) // "999"' "${_manifest}" ...)
WAGGLE_NODE_GPS_LON=$(jq -r '(.gps_lon) // "999"' "${_manifest}" ...)
WAGGLE_NODE_MOBILITY=$(jq -r '(.mobility) // ""' "${_manifest}" ...)
```

### 2. edge-scheduler — `pkg/nodescheduler/resourcemanager.go`
`patches/0002-*.patch`. In `createPodTemplateSpecForPlugin`, the plugin container
literal gains one field:

```go
EnvFrom: []apiv1.EnvFromSource{
    {ConfigMapRef: &apiv1.ConfigMapEnvSource{
        LocalObjectReference: apiv1.LocalObjectReference{Name: "wes-identity"},
        Optional:             booltoPtr(true),  // reuses the existing helper (:2181)
    }},
},
```

- `Optional: true` → a node whose WES hasn't created/regenerated the ConfigMap still
  schedules plugins (safe rollout).
- `EnvFrom` is layered UNDER `container.Env`, so an explicit plugin `Env` var of the
  same name still wins — "user env first" precedence preserved.
- `createPodTemplateSpecForPlugin` is shared by all pod-builder entry points
  (`CreatePodTemplate`, `CreateJobTemplate`, `CreateDeploymentTemplate`, and the
  scheduler daemon), so this ONE patch covers every scheduling path.

pywaggle2 (`pywaggle2/node_info_env.py`, production home `waggle/data/`) normalizes
sentinels → `None`/`"unknown"` by range, so plugin authors never see `0`/`999`/`""`.

## Verification

Offline (`make test`, no mocks): env generator 32/32 (incl. no-leak assertions);
isolated Go unit 4/4; end-to-end gen→env→pywaggle2 reader 7/7; the REAL upstream
`edge-scheduler` builds rc=0 with the patch and its `pkg/nodescheduler` tests pass;
both patches apply clean to pristine HEAD (`make patches-check`). k8s types pinned to
the upstream `k8s.io/api v0.23.1`.

Live on H00F (both tiers, node returned to stock after):
- **ConfigMap → envFrom → pywaggle2**: `read_node_info()` resolved the real
  `vsn=H00F, node_id=00004cbb4701d16c, lat=41.7179852752395, lon=-87.98271513806043,
  mobility=unknown`.
- **Patched scheduler auto-injection**: a plugin scheduled with no `envFrom` in its
  own spec received `envFrom: [{configMapRef: {name: wes-identity, optional: true}}]`
  and saw all five vars at runtime.
- **Full cloud round-trip**: the reference consumer (image-sampler2, wired to read
  these vars) produced a geotagged image whose EXIF carried H00F's real coords, and
  the upload appears in the public Sage data API with `meta.vsn=H00F,
  node_id=00004cbb4701d16c`.

## Test on a node (setup / teardown)

Scripts live in `node-test/` and run ON the node (`sudo kubectl`). Backups go to
`node-test/.node-backup/` (gitignored); re-running `add` never clobbers an existing
backup; teardown is restore-from-backup (the change mutates existing objects).

```bash
# TIER 1 — ConfigMap only (safe, seconds to revert; tests Part A + pywaggle2 read)
cd node-test
./test-add-configmap.sh       # backup + regenerate wes-identity (5 vars from THIS
                              # node's manifest) + launch a reader pod, print NodeInfo
./test-remove-configmap.sh    # restore original wes-identity, delete the pod

# TIER 2 — patched scheduler (control-plane; proves fleet-wide auto-injection)
git -C ../.upstream/edge-scheduler apply ../patches/0002-*.patch   # prereq
./test-add-scheduler.sh       # podman-build patched scheduler, k3s-import, repoint the
                              # Deployment; AUTO-REVERTS if the rollout isn't Ready
sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'  # -> wes-identity
./test-remove-scheduler.sh    # restore the original scheduler image
```

Run Tier 1 before Tier 2 so the ConfigMap holds the vars. Full operator detail +
risk table: `TESTING.md`.

## Risks for fleet-wide deployment

| Risk | Impact | Mitigation |
|---|---|---|
| Scheduler rollout fails / crashloops | plugin scheduling stalls fleet-wide until revert | `Optional: true` keeps scheduling working even with no ConfigMap; roll the scheduler image canary-first (one node) before fleet; deployment is trivially revertible to the prior image |
| ConfigMap not yet regenerated on a node | plugin gets no node-info (env absent) | `Optional: true` → no-op, plugins still run; roll the `update-stack.sh` change and the scheduler independently, in either order |
| `mobility` field absent from manifests | every node reports `mobility="unknown"` | correct-by-design (conservative); add the field (default `static`) to close it — see CI tasks |
| Manifest GPS stale/wrong on a node | plugin gets bad coords | out of scope for this change; surfaced as-is. Mobile nodes should use live gpsd (pywaggle2 Tier-2 GPS via `WAGGLE_GPS_SERVER`, already injected), not this static env |
| Explicit plugin env collides with an injected var | none | k8s applies `Env` over `EnvFrom` → explicit wins (verified) |
| Stale host `pluginctl` builds pods client-side | `pluginctl run` on a node with an old binary shows NO injection despite a patched scheduler | ship the patched `pluginctl` (same image) alongside the scheduler, OR schedule via the cloud/sesctl daemon path. The scheduler daemon itself is always correct once patched |

## Folding into base CI

1. **Merge `patches/0001`** into waggle-edge-stack `update-stack.sh`. It's a 3-line
   `jq` addition in the existing `update_wes` block + 3 lines in the `wes-identity.env`
   heredoc — no new files, no new plumbing. The ConfigMap is already regenerated
   per-node by every `update-stack` run, so no extra rollout step: it takes effect the
   next time a node runs update-stack.
2. **Merge `patches/0002`** into edge-scheduler and cut a normal scheduler release.
   One field on one container literal, reusing the existing `booltoPtr` helper and the
   already-imported `apiv1` alias. The scheduler image ships through the normal build;
   `Optional: true` makes deploy order irrelevant.
3. **Add a `mobility` field to `node-manifest-v2.json`** (default `static` for the
   current fleet). This is the only true schema change requested; until it lands the
   generator emits the empty sentinel and pywaggle2 reads `"unknown"` (harmless).
4. **pywaggle2**: land `node_info_env.py`'s reader in `waggle/data/` behind
   `get_node_info()`. Its sentinel contract must stay in lock-step with the generator
   (`("","0")→None` for vsn, coords by range |lat|>90 / |lon|>180, node_id `""`→None).

Optional phase 2 (not built here): a richer, still-whitelisted `node-info.json` file
channel (a `waggle-node-info` ConfigMap mounted at `/run/waggle/node-info.json`,
mirroring `data-config.json`) for structured surfaces like a sanitized sensor list.
Env alone covers the five identity scalars.

## Repo notes

- `patches/` is the canonical deliverable. `.upstream/` holds shallow clones with the
  patches applied in-place, used only by `make test-upstream` / `make patches-check`.
- The reference consumer is a separate repo (`image-sampler2`): its
  `nodemeta._runtime_identity()` reads these five vars and feeds EXIF GPS + filename +
  upload meta. Its env-reading core shares the exact sentinel contract with
  `node_info_env.py` — keep the two aligned if the contract changes.
