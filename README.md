# wes-nodeinfo-injection

Build & test the small WES change that lets a running plugin learn its own node
identity + location, so **pywaggle2** can expose `get_node_info()` (VSN, node_id,
lat/lon, mobility) — the "Part B" WES side of the pywaggle2 two-part improvement.

Design: `~/AI-projects/pywaggle2-design.md` §2.4 (grounded in WES source + live
H00F/W096 node inspection, 2026-07-09).

## The change in one sentence

Deliver five node-identity env vars to every plugin pod by (a) adding GPS+mobility
to the **existing** `wes-identity` ConfigMap, and (b) giving the plugin container
`EnvFrom: wes-identity` — reusing mechanisms WES already has. **No raw manifest is
ever mounted into plugin pods** (it carries sensor URIs/creds, DevEUIs, serials,
modem, street address — see design §2.4.2).

The five vars:

| Env var | Source | Sentinel when absent | pywaggle2 sees |
|---|---|---|---|
| `WAGGLE_NODE_ID` | `/etc/waggle/node-id` (existing) | empty | `None` |
| `WAGGLE_NODE_VSN` | `/etc/waggle/vsn` (existing) | `0` | `None` |
| `WAGGLE_NODE_GPS_LAT` | manifest `.gps_lat` (**new**) | `999` (range-detected) | `None` |
| `WAGGLE_NODE_GPS_LON` | manifest `.gps_lon` (**new**) | `999` | `None` |
| `WAGGLE_NODE_MOBILITY` | manifest `.mobility` (**new**, proposed field) | empty | `"unknown"` |

## Why two upstream repos

The standard plugin-pod env/mounts are injected by the **edge-scheduler** binary,
NOT by the waggle-edge-stack YAMLs (design §2.4.4). So the change spans both:

- `patches/0001-waggle-edge-stack-add-gps-mobility-to-wes-identity.patch`
  → `update-stack.sh::update_wes()`: add the 3 manifest-sourced vars to
  `configs/wes-identity.env` (which becomes the `wes-identity` ConfigMap).
- `patches/0002-edge-scheduler-envfrom-wes-identity.patch`
  → `resourcemanager.go::createPodTemplateSpecForPlugin()`: add
  `EnvFrom: wes-identity` (Optional) to the plugin container.

Both are **verified to apply cleanly** to pristine upstream HEAD (`make patches-check`).

## Layout

```
gen-wes-identity.sh          extracted, testable form of the update-stack.sh change
test-gen-wes-identity.sh     32 tests for the generator (values, sentinels, no-leak)
fixtures/                    faithful node dirs: h00f, w096, minimal, mobile, nomanifest
scheduler-change/            isolated Go module reproducing the container build + EnvFrom
  podbuilder.go              the change, using k8s.io/api v0.23.1 (matches upstream)
  podbuilder_test.go         4 Go unit tests
pywaggle2/node_info_env.py   the pywaggle2-side reader (sentinel->None normalization)
test_e2e.py                  7 tests: gen -> env -> pywaggle2 reader (full chain)
patches/                     real unified diffs for the two upstream repos
.upstream/                   shallow clones (edge-scheduler, waggle-edge-stack) w/ patches applied
```

## Test it

```bash
make test            # all three layers (bash + go + python), no mocks
make test-upstream   # build the REAL upstream scheduler w/ patch + run its tests
make patches-check   # confirm both patches apply to pristine upstream
```

Requires: `bash`, `jq`, Go (1.22+, at /usr/local/go), `python3`. `.upstream/` clones
are needed only for `test-upstream`/`patches-check`; the three `make test` layers are
self-contained.

## Verification status (2026-07-12)

- env generator: **32/32** pass
- Go isolated unit: **4/4** pass; `scheduler-change` builds clean, `go vet` clean
- end-to-end: **7/7** pass
- REAL upstream edge-scheduler: **builds rc=0** with patch applied; upstream
  `pkg/nodescheduler` tests **pass** (no regression)
- both patches **apply clean** to pristine upstream HEAD
- **LIVE on H00F: Tier-1 round-trip verified** — pywaggle2 resolved the real
  NodeInfo (`vsn=H00F`, `lat=41.7179852752395`, `lon=-87.98271513806043`) from the
  regenerated `wes-identity` ConfigMap; clean teardown back to the original 2 vars.
  See `TESTING.md` §6. Tier-2 (scheduler auto-injection) is the next live gate.

See `HANDOFF.md` for the exact diffs and what's CI-owned vs done.

## Testing on a real node before upstream merge

`node-test/` has side-load scripts (Tier 1: ConfigMap-only, safe; Tier 2: patched
scheduler) to install the change on H00F/any node, test pywaggle2 `get_node_info()`
on real hardware, then restore. See `node-test/README.md`.

Full operator guide — instructions, rationale, and risk analysis — is in
`TESTING.md`.
