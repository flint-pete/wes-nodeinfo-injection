# HANDOFF — wes-nodeinfo-injection (for the Sage CI team)

The WES ("Part B") change that feeds pywaggle2's node-identity reader
(`read_node_info()`; a `Plugin.get_node_info()` wrapper is the proposed future
upstream API). Delivered as two patches against upstream, verified end-to-end on
live hardware. Nothing has been
pushed upstream — this repo is the review + test harness; `patches/` is the
deliverable.

## What it does

Gives every plugin pod the scheduler creates five node-identity env vars so a running plugin can learn its
own VSN, node_id, GPS, and mobility:

```
WAGGLE_NODE_ID  WAGGLE_NODE_VSN  WAGGLE_NODE_GPS_LAT  WAGGLE_NODE_GPS_LON  WAGGLE_NODE_MOBILITY
```

Do NOT mount the raw `node-manifest-v2.json` into plugin pods — it leaks sensor
URIs/creds, LoRaWAN DevEUIs, hardware serials, modem config, and precise street
address (verified on H00F + W096). The env projection is an inherent whitelist: WES
picks each var explicitly, so nothing sensitive rides along.

## How it works — the two patches

Both apply clean to the recorded base commits: waggle-edge-stack `edba812`,
edge-scheduler `5391a00` (`make patches-check`; see README "Populating
`.upstream/`"). Newer upstream commits may need a rebase.

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
`edge-scheduler` builds with the patch and its `pkg/nodescheduler` tests pass
(`make test-upstream`); both patches apply clean to the recorded base commits
(`make patches-check`). k8s types pinned to the upstream `k8s.io/api v0.23.1`.

Live: both tiers verified on H00F (ConfigMap → envFrom → reader; patched-scheduler
auto-injection; geotagged upload round-trip to the Sage data API), node returned to
stock after. Tier 1 re-verified on H041 during the media-stack install. Detailed
results: [docs/history/NOTES.md](docs/history/NOTES.md).

## Test on a node (setup / teardown)

Scripts live in `node-test/` and run ON the node (`$KUBECTL`, default `sudo kubectl`,
or `sudo k3s kubectl` when only k3s is on PATH). Backups go to
`node-test/.node-backup/` (gitignored); re-running `add` never clobbers an existing
backup; teardown is restore-from-backup (the change mutates existing objects).

```bash
# TIER 1 — ConfigMap only (safe, seconds to revert; tests Part A + pywaggle2 read)
cd node-test
./test-add-configmap.sh       # backup + regenerate wes-identity (5 vars from THIS
                              # node's manifest) + launch a reader pod, print NodeInfo
./test-remove-configmap.sh    # restore original wes-identity, delete the pod

# TIER 2 — patched scheduler (control-plane; proves fleet-wide auto-injection)
git -C ../.upstream/edge-scheduler apply "$(realpath ../patches/0002-edge-scheduler-envfrom-wes-identity.patch)"   # prereq (run from node-test/)
./test-add-scheduler.sh       # podman-build patched scheduler, k3s-import, repoint the
                              # Deployment; AUTO-REVERTS if the rollout isn't Ready
sudo kubectl get pod <plugin> -o jsonpath='{.spec.containers[0].envFrom}'  # -> wes-identity
./test-remove-scheduler.sh    # restore the original scheduler image
```

Run Tier 1 before Tier 2 so the ConfigMap holds the vars. Tier 2 needs `sudo podman`,
`git`, and network access to docker.io on the node — no host Go. Full operator detail
+ risk table (incl. reboot behaviour, R2/R8): `TESTING.md`.

## Risks for fleet-wide deployment

| Risk | Impact | Mitigation |
|---|---|---|
| Scheduler rollout fails / crashloops | plugin scheduling stalls fleet-wide until revert | `Optional: true` keeps scheduling working even with no ConfigMap; roll the scheduler image canary-first (one node) before fleet; deployment is trivially revertible to the prior image |
| ConfigMap not yet regenerated on a node | plugin gets no node-info (env absent) | `Optional: true` → no-op, plugins still run; roll the `update-stack.sh` change and the scheduler independently, in either order |
| `mobility` field absent from manifests | every node reports `mobility="unknown"` | correct-by-design (conservative); add the field (default `static`) to close it — see CI tasks |
| Manifest GPS stale/wrong on a node | plugin gets bad coords | out of scope for this change; surfaced as-is. Mobile nodes should use live gpsd (pywaggle2 Tier-2 GPS via `WAGGLE_GPS_SERVER`, already injected), not this static env |
| Explicit plugin env collides with an injected var | none | k8s applies `Env` over `EnvFrom` → explicit wins (verified) |
| Host `pluginctl` builds pods client-side | `pluginctl run` pods show NO injection despite a patched scheduler (true for every pod in today's media stack) | ship a `pluginctl` rebuilt from the patched source alongside the scheduler (not done/tested here), OR schedule via the cloud/sesctl daemon path, OR pass identity explicitly (media-sampler3 uses `--vsn`). The scheduler daemon itself is always correct once patched |

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
4. **pywaggle2**: land `node_info_env.py`'s reader (`read_node_info()`) in
   `waggle/data/` behind a `Plugin.get_node_info()` wrapper. Its sentinel contract must stay in lock-step with the generator
   (`("","0")→None` for vsn, coords by range |lat|>90 / |lon|>180, node_id `""`→None).

(A possible richer `node-info.json` phase 2 was considered and not built; see
[docs/history/NOTES.md](docs/history/NOTES.md).)

## Repo notes

- `patches/` is the canonical deliverable. `.upstream/` (gitignored) holds clones of
  the two upstream repos at the base commits (edge-scheduler `5391a00`,
  waggle-edge-stack `edba812`) with the patches applied in the working tree, used
  only by `make test-upstream` / `make patches-check` and the Tier-2 node build.
  How to create it: README "Populating `.upstream/`".
- The pywaggle2-side reader is packaged as its own repo — **`pywaggle2-nodeinfo`**
  (v0.1.0): the reader at `waggle/data/node_info_env.py` + 25 unit tests + its own
  README/DESIGN/HANDOFF for the CI team. That repo is the CANONICAL source; the copy
  under `pywaggle2/node_info_env.py` here is a mirror kept only for this repo's
  `test_e2e.py` — keep it byte-identical to `pywaggle2-nodeinfo`.
- **Every copy of the reader contract** — keep aligned if the contract changes:
  1. `pywaggle2-nodeinfo/waggle/data/node_info_env.py` — canonical;
  2. `pywaggle2/node_info_env.py` here — byte-identical mirror (`diff -q`);
  3. `node-test/test-plugin-pod.yaml` here — condensed inline reader, semantically
     equivalent (not byte-identical);
  4. `media-sampler3/nodemeta.py` (`_runtime_identity()`) — independent
     re-implementation of the same sentinel contract (the producer; it feeds EXIF
     GPS + filename + upload meta);
  5. `sage-yolo2/node_info.py` and 6. `sage-bioclip2/node_info.py` — vendored copies
     of the canonical reader (v0.1.1 @ `79aa76b`; see `sage-yolo2/VENDORED.md`).
