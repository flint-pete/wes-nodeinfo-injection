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
   - **ALSO update the host `pluginctl` binary** (see Live-verification note below):
     the injection is in `createPodTemplateSpecForPlugin`, shared by every pod-builder
     entry point (`CreatePodTemplate`/`CreateJobTemplate`/`CreateDeploymentTemplate`
     and the scheduler daemon) — so the patch is complete in ONE place. BUT each
     *binary* must carry it. A node's stale host `/usr/bin/pluginctl` (0.28.0) builds
     pods client-side with unpatched code, so `pluginctl run` on such a node shows NO
     injection even with the patched scheduler deployed. Rollout must ship the patched
     pluginctl too (it's in the same image), or restrict scheduling to the cloud/sesctl
     path that goes through the patched scheduler daemon.

## Live verification on H00F (2026-07-12)

Both tiers proven on real hardware; node returned to stock afterward.

- **Tier 1** (ConfigMap → envFrom → pywaggle2): `read_node_info()` resolved
  `vsn=H00F, lat=41.7179852752395, lon=-87.98271513806043, mobility=unknown`; clean
  restore to the original 2-var `wes-identity`.
- **Tier 2** (patched scheduler auto-injection): a plugin scheduled through the
  patched `createPodTemplateSpecForPlugin` (no envFrom in its own spec) received
  `envFrom: [{configMapRef: {name: wes-identity, optional: true}}]` and saw all five
  `WAGGLE_NODE_*` env vars at runtime. Scheduler rollout Ready; restored to
  `waggle/edge-scheduler:0.28.0` after.
- **Build**: the patched edge-scheduler compiled natively on-node via `podman build`
  (arm64, Go compiled inside the container — no host Go), rc=0. The `/proc/acpi`
  Infra #2 blocker did NOT bite this base image on this node.
- **Two on-node gotchas folded into `node-test/test-add-scheduler.sh`:** (a) build
  needs `sudo podman`; (b) this node's `registries.conf` has no unqualified-search
  registries, so the Dockerfile's bare `FROM waggle/plugin-base` must be fully
  qualified to `docker.io/...` (done via a throwaway Dockerfile so the packaged one
  stays clean); the multi-stage build also requires `--build-arg TARGETARCH/VERSION`.

## Gate 3 — consumer proof: image-sampler2 geotags from the injected env (2026-07-12)

The producer half of the story, closing the loop. image-sampler2's
`nodemeta._runtime_identity()` was wired to read the 5 injected `WAGGLE_NODE_*` env
vars (the placeholder it was designed to await), and side-loaded on H00F with those
vars supplied via `pluginctl run --env-from` (exactly what `envFrom: wes-identity`
delivers). Result: the plugin produced `1783…-v2-H00F-top_camera.jpg` whose EXIF
carried `Model=H00F` and GPS `lat=41.7179852778, lon=-87.9827151389` (H00F's real
surveyed coords), with upload meta `vsn=H00F, node_id=00004cbb4701d16c` — every
value sourced from the injected env, produced through pywaggle's real upload path.
- The final Beehive object-store round-trip was blocked by an UNRELATED chronic H00F
  upload-agent rsync stall (154 agent restarts; auth succeeds, transfer interrupts) —
  the file was correctly produced AND selected by the agent; only the node→Beehive
  transfer failed. Not a defect in this change.
- Gotcha found: the upload-agent's path regex requires the version segment to match
  `x.y.z|latest|test`, so a side-load image tagged `:gate3` is silently never
  shipped; retag `:test`. (Captured in the sage-waggle sideload reference.)
- Together, Gate 2 (scheduler AUTO-injects the envFrom) + Gate 3 (a real plugin
  CONSUMES the env into geotagged output) prove the whole mechanism end-to-end on
  real hardware.

## Notes

- The pywaggle2-side reader (`pywaggle2/node_info_env.py`) lives here for the e2e
  proof; the production home is pywaggle2 (`waggle/data/` per the nodeinfo-gps design
  ref). The resolver logic mirrors image-sampler2 `nodemeta.py::resolve_identity()`
  (already tested), extended to read the new env vars.
- `.upstream/` holds shallow clones with the patches applied in-place (for
  `test-upstream`); the canonical deliverable is `patches/`.
