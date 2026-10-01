# wes-nodeinfo-injection

A small WES change that lets a running plugin learn its own node identity + location
(VSN, node_id, lat/lon, mobility) as env vars, read by pywaggle2's `read_node_info()`
(from [pywaggle2-nodeinfo](https://github.com/flint-pete/pywaggle2-nodeinfo); a
`Plugin.get_node_info()` wrapper is the proposed future upstream API). This is the
WES ("Part B") half of the pywaggle2 node-info improvement.

Delivered as **two patches** against two upstream repos — nothing is pushed upstream
yet. Verified on live hardware (history: [docs/history/NOTES.md](docs/history/NOTES.md)).

## The change in one sentence

Deliver five node-identity env vars to every plugin pod the scheduler creates by (a) adding GPS+mobility to
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

## How this fits the media stack

The two node-side tiers (`node-test/`) do different things:

- **Tier 1** — regenerate the `wes-identity` ConfigMap with all five vars. On its own
  this **changes no running plugin**: nothing consumes `wes-identity` until a pod
  gets an `envFrom` for it.
- **Tier 2** — swap in the patched scheduler, which adds `envFrom: wes-identity` to
  every pod *it* creates.

`pluginctl run` builds pods **client-side**, so pluginctl-launched pods never get the
env, even with Tier 2. That is why the media stack does not depend on it: the producer
(media-sampler3) is launched with `--vsn`; the consumers (sage-yolo2, sage-bioclip2)
take identity from each frame's EXIF, with env as fallback / cross-check; and Beehive
attaches the node's VSN to published data downstream anyway. Under `pluginctl` the
reader returns all `None` (mobility `"unknown"`). No fleet manifest has a `mobility`
field yet, so even with injection mobility is `"unknown"`.

Hub docs (media-sampler3): install guide
[INSTALLING-MEDIA-SAMPLER3.md](https://github.com/flint-pete/media-sampler3/blob/master/INSTALLING-MEDIA-SAMPLER3.md) (Step 3 covers this
repo), [REBOOT-RECOVERY.md](https://github.com/flint-pete/media-sampler3/blob/master/REBOOT-RECOVERY.md) (what to re-check after a reboot),
[docs/HOW-IT-WORKS.md](https://github.com/flint-pete/media-sampler3/blob/master/docs/HOW-IT-WORKS.md) (data flow and ownership). The reader
lives in [pywaggle2-nodeinfo](https://github.com/flint-pete/pywaggle2-nodeinfo).

## Test it

```bash
make test            # 3 layers (bash + go + python), no mocks
make test-upstream   # build the REAL upstream scheduler w/ patch + run its tests
make patches-check   # confirm both patches apply clean to the recorded base commits
```

`make test` needs host `bash`, `jq`, Go (1.22+ at /usr/local/go), `python3`; its three
layers are self-contained. Host Go is needed only for these offline tests
(`make test`, `make test-upstream`) — the on-node Tier 2 build compiles Go inside a
container and needs `sudo podman`, `git`, and network access to docker.io instead.
`.upstream/` clones are needed only for `test-upstream`/`patches-check` and Tier 2.

To exercise it on a real node (side-load + restore), see `node-test/README.md`.

## Populating `.upstream/`

`.upstream/` is gitignored (never commit it). The patches were made against these
base commits:

| Upstream repo | Base commit | Patch |
|---|---|---|
| https://github.com/waggle-sensor/waggle-edge-stack.git | `edba812` | `patches/0001-waggle-edge-stack-add-gps-mobility-to-wes-identity.patch` |
| https://github.com/waggle-sensor/edge-scheduler.git | `5391a00` | `patches/0002-edge-scheduler-envfrom-wes-identity.patch` |

From the repo root:

```bash
mkdir -p .upstream
git clone https://github.com/waggle-sensor/waggle-edge-stack.git .upstream/waggle-edge-stack
git -C .upstream/waggle-edge-stack checkout edba812
git clone https://github.com/waggle-sensor/edge-scheduler.git .upstream/edge-scheduler
git -C .upstream/edge-scheduler checkout 5391a00

# apply the patches to the working trees (needed by test-upstream and Tier 2;
# patches-check reads the pristine commit via `git archive HEAD`, so it works either way)
git -C .upstream/waggle-edge-stack apply "$(realpath patches/0001-waggle-edge-stack-add-gps-mobility-to-wes-identity.patch)"
git -C .upstream/edge-scheduler   apply "$(realpath patches/0002-edge-scheduler-envfrom-wes-identity.patch)"
```

Use `"$(realpath …)"` (or an absolute path): `git -C <dir>` changes directory
*before* resolving a relative patch path, so `git -C .upstream/x apply ../patches/…`
looks in the wrong place and fails.

## Layout

```
gen-wes-identity.sh          testable form of the update-stack.sh change (Part A)
test-gen-wes-identity.sh     32 tests: values, sentinels, no-leak assertions
fixtures/                    faithful node dirs: h00f, w096, minimal, mobile, nomanifest
                             (nomanifest is empty on purpose; .gitkeep just keeps it in git)
scheduler-change/            isolated Go module reproducing the container build + EnvFrom
pywaggle2/node_info_env.py   byte-identical mirror of pywaggle2-nodeinfo's reader (for test_e2e.py)
test_e2e.py                  7 tests: gen -> env -> pywaggle2 reader (full chain)
patches/                     the two upstream diffs (the deliverable)
node-test/                   side-load + restore scripts for a live node
.upstream/                   upstream clones at the base commits, patched (gitignored; see above)
docs/history/NOTES.md        verification history and design notes moved out of these docs
VERSION, CHANGELOG.md        release history
```

See `HANDOFF.md` for the CI-team summary: rollout risks and how to fold the change
into base CI. `TESTING.md` is the operator guide for the side-load path.
