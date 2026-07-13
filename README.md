# wes-nodeinfo-injection

A small WES change that lets a running plugin learn its own node identity + location,
so **pywaggle2** can expose `get_node_info()` (VSN, node_id, lat/lon, mobility). This
is the WES ("Part B") half of the pywaggle2 node-info improvement.

Verified end-to-end on live hardware (H00F): a plugin scheduled by the patched
scheduler auto-receives the env, reads its real identity/GPS, and produced a
geotagged upload visible in the Sage data API. Delivered as **two clean patches**
against two upstream repos — nothing is pushed upstream yet.

## The change in one sentence

Deliver five node-identity env vars to every plugin pod by (a) adding GPS+mobility to
the **existing** `wes-identity` ConfigMap, and (b) giving the plugin container
`EnvFrom: wes-identity`. Both reuse mechanisms WES already has. **The raw manifest is
never mounted into plugin pods** — it carries sensor URIs/creds, DevEUIs, serials,
modem config, and street address; the env projection is an inherent whitelist.

The five vars (pywaggle2 normalizes every sentinel → `None`/`"unknown"`, so plugin
authors never see `0`/`999`/`""`):

| Env var | Source | Sentinel when absent | pywaggle2 sees |
|---|---|---|---|
| `WAGGLE_NODE_ID` | `/etc/waggle/node-id` (existing) | empty | `None` |
| `WAGGLE_NODE_VSN` | `/etc/waggle/vsn` (existing) | `0` | `None` |
| `WAGGLE_NODE_GPS_LAT` | manifest `.gps_lat` (**new**) | `999` (range-detected) | `None` |
| `WAGGLE_NODE_GPS_LON` | manifest `.gps_lon` (**new**) | `999` | `None` |
| `WAGGLE_NODE_MOBILITY` | manifest `.mobility` (**new field, CI to add**) | empty | `"unknown"` |

## How it works (two repos, because plugin-pod env is injected by the scheduler)

Standard plugin-pod env/mounts are injected by the **edge-scheduler** binary, not by
the waggle-edge-stack YAMLs — so the change spans both:

- `patches/0001-waggle-edge-stack-add-gps-mobility-to-wes-identity.patch`
  → `update-stack.sh::update_wes()`: adds the 3 manifest-sourced vars (via `jq`, in
  the existing style) to `configs/wes-identity.env`, which becomes the `wes-identity`
  ConfigMap.
- `patches/0002-edge-scheduler-envfrom-wes-identity.patch`
  → `resourcemanager.go::createPodTemplateSpecForPlugin()`: adds one field to the
  plugin container literal —
  ```go
  EnvFrom: []apiv1.EnvFromSource{{ConfigMapRef: &apiv1.ConfigMapEnvSource{
      LocalObjectReference: apiv1.LocalObjectReference{Name: "wes-identity"},
      Optional:             booltoPtr(true)}}},
  ```
  `Optional: true` → a node whose WES hasn't regenerated the ConfigMap still schedules
  plugins (safe, incremental rollout). `EnvFrom` layers UNDER `container.Env`, so any
  explicit plugin `Env` var of the same name still wins.

`createPodTemplateSpecForPlugin` is shared by every pod-builder entry point
(`CreatePodTemplate`, `CreateJobTemplate`, `CreateDeploymentTemplate`, and the
scheduler daemon), so the single patch covers all scheduling paths.

## Test it

```bash
make test            # 3 layers (bash + go + python), no mocks
make test-upstream   # build the REAL upstream scheduler w/ patch + run its tests
make patches-check   # confirm both patches apply clean to pristine upstream HEAD
```

Requires `bash`, `jq`, Go (1.22+ at /usr/local/go), `python3`. `.upstream/` clones are
needed only for `test-upstream`/`patches-check`; the three `make test` layers are
self-contained.

To exercise it on a real node (side-load + restore), see `node-test/README.md`.

## Layout

```
gen-wes-identity.sh          testable form of the update-stack.sh change (Part A)
test-gen-wes-identity.sh     32 tests: values, sentinels, no-leak assertions
fixtures/                    faithful node dirs: h00f, w096, minimal, mobile, nomanifest
scheduler-change/            isolated Go module reproducing the container build + EnvFrom
pywaggle2/node_info_env.py   the pywaggle2-side reader (sentinel->None normalization)
test_e2e.py                  7 tests: gen -> env -> pywaggle2 reader (full chain)
patches/                     the two upstream diffs (the deliverable)
node-test/                   side-load + restore scripts for a live node
.upstream/                   shallow clones w/ patches applied (for test-upstream)
```

See `HANDOFF.md` for the CI-team summary: rollout risks and how to fold the change
into base CI. `TESTING.md` is the operator guide for the side-load path.
