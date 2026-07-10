# HANDOFF -- wes-nodeinfo-injection

For the Sage CI team. This is the "Part B" WES change that feeds pywaggle2's
`get_node_info()`. It is a prototype, built and tested against real upstream source
and two live nodes, expressed as two applyable patches. Nothing here has been pushed
to any upstream repo.

## What we're asking for

Deliver 5 node-identity env vars to every plugin pod, reusing mechanisms WES already
has. Do NOT mount the raw `node-manifest-v2.json` into plugin pods (it leaks sensor
URIs/creds, LoRaWAN DevEUIs, hardware serials, modem config, precise street address —
verified on H00F + W096; see `~/AI-projects/pywaggle2-design.md` §2.4.2).

## The two patches (both apply clean to upstream HEAD)

### 1. waggle-edge-stack — `kubernetes/update-stack.sh` (`update_wes`)
`patches/0001-...patch`. Today it writes only `WAGGLE_NODE_{ID,VSN}` into
`configs/wes-identity.env` (→ the `wes-identity` ConfigMap). The patch adds three
manifest-sourced vars via `jq`, in the same style:
`WAGGLE_NODE_GPS_LAT`, `WAGGLE_NODE_GPS_LON`, `WAGGLE_NODE_MOBILITY`, with sentinels
(`999` for missing coords — off-globe, since `0` is a real coordinate; empty for
missing mobility).

### 2. edge-scheduler — `pkg/nodescheduler/resourcemanager.go`
`patches/0002-...patch`. In `createPodTemplateSpecForPlugin`, the plugin container
literal gains one field:
```go
EnvFrom: []apiv1.EnvFromSource{
    {ConfigMapRef: &apiv1.ConfigMapEnvSource{
        LocalObjectReference: apiv1.LocalObjectReference{Name: "wes-identity"},
        Optional:             booltoPtr(true),
    }},
},
```
`Optional: true` means a node whose WES hasn't created the ConfigMap still schedules
plugins (safe rollout). EnvFrom is layered UNDER `container.Env`, so any explicit
`Env` var of the same name still wins — the "user env first" precedence is preserved.

## What's verified (all green, real tooling — no mocks)

- **env generator**: 32/32 — real values on H00F/W096 fixtures, sentinel→behavior on
  minimal/mobile/fresh-node, and **no-leak assertions** (deveui, sensor uri, serial,
  address never appear in output).
- **Go change**: isolated unit 4/4; AND the **real upstream `edge-scheduler`
  `pkg/nodescheduler` builds (rc=0) with the patch applied and its own tests pass**
  (no regression). k8s types are the upstream-pinned `k8s.io/api v0.23.1`.
- **end-to-end** (7/7): `gen-wes-identity.sh` → env → pywaggle2 `read_node_info()`
  yields correct `NodeInfo` — real lat/lon on real nodes, `None` on every sentinel,
  `mobility="unknown"` when absent, explicit-env-override wins.
- Both patches **apply clean** to pristine upstream HEAD.

Reproduce: `make test` (fast, self-contained), `make test-upstream` (full scheduler
build), `make patches-check`.

## What's CI-owned / open

1. **Add a `mobility` field to `node-manifest-v2.json`** (design §2.3; default
   `static` for the current fleet). Until it exists the generator emits the empty
   sentinel and pywaggle2 reads `"unknown"` — correct, but GPS-mobility logic stays
   conservative until the field lands. This is the only true schema change requested.
2. **Curated `node-info.json` file channel (optional, phase 2).** This prototype
   implements the env-scalar channel (covers ~95% of plugins + non-Python via env).
   The structured file channel (a whitelisted `waggle-node-info` ConfigMap mounted at
   `/run/waggle/node-info.json`, mirroring `data-config.json`) is designed in §2.4.3
   but NOT built here — it's the natural next step if/when a richer surface (sanitized
   sensor list, etc.) is wanted. Env alone is sufficient for the 5 identity scalars.
3. **Confirm the runtime "GPS call"/"VSN call" the CI team mentioned (2026-07-06).**
   If it's a gpsd wrapper, pywaggle2's Tier-2 `GPS()` wraps the SAME source
   (`WAGGLE_GPS_SERVER` is already injected into plugin pods today — verified in
   resourcemanager.go). This env change is the Tier-1 (static identity) half and is
   complementary, not competing.
4. **Publish/rollout**: build the patched scheduler image + roll `wes-identity`
   regeneration to nodes. DRY-run friendly: with `Optional: true` the EnvFrom is a
   no-op on nodes that haven't regenerated the ConfigMap yet.

## Notes

- The pywaggle2-side reader (`pywaggle2/node_info_env.py`) lives here for the e2e
  proof; the production home is pywaggle2 (`waggle/data/` per the nodeinfo-gps design
  ref). The resolver logic mirrors image-sampler2 `nodemeta.py::resolve_identity()`
  (already tested), extended to read the new env vars.
- `.upstream/` holds shallow clones with the patches applied in-place (for
  `test-upstream`); the canonical deliverable is `patches/`.
