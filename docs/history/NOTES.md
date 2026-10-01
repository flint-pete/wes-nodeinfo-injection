# wes-nodeinfo-injection — history notes

Verification history and design narrative moved out of README / HANDOFF /
node-test/README so those describe only current behaviour and rules. Nothing here is
needed to run the change. For how all six media-stack components evolved, see the
hub's [DESIGN-PATH.md](https://github.com/flint-pete/media-sampler3/blob/master/DESIGN-PATH.md).

## H00F live verification (v1.0.0, Jul 2026)

*(moved from README intro and HANDOFF "Verification")*

Verified end-to-end on live hardware (H00F): a plugin scheduled by the patched
scheduler auto-received the env, read its real identity/GPS, and produced a
geotagged upload visible in the Sage data API. Both tiers were run and the node was
returned to stock afterwards:

- **ConfigMap → envFrom → pywaggle2**: `read_node_info()` resolved the real
  `vsn=H00F, node_id=00004cbb4701d16c, lat=41.7179852752395, lon=-87.98271513806043,
  mobility=unknown`.
- **Patched scheduler auto-injection**: a plugin scheduled with no `envFrom` in its
  own spec received `envFrom: [{configMapRef: {name: wes-identity, optional: true}}]`
  and saw all five vars at runtime.
- **Full cloud round-trip**: the reference consumer at the time (`image-sampler2`,
  since superseded by media-sampler3, wired to read these vars) produced a geotagged
  image whose EXIF carried H00F's real coords, and the upload appears in the public
  Sage data API with `meta.vsn=H00F, node_id=00004cbb4701d16c`.
- The offline suite was green and both patches applied clean to the then-current
  upstream HEAD (recorded as the base commits `edba812` / `5391a00`).

The work went through gates (git log): Gate 1 Tier-1 round-trip + teardown (found
the `restore_resource` resourceVersion-conflict bug, fixed in `lib.sh`), Gate 2
Tier-2 build hardening, Gate 3 consumer proof and full data-API round-trip.

## Tier-2 build notes "learned on H00F"

*(moved from node-test/README; the resulting rules stay there and in the script)*

The first on-node builds of the patched scheduler failed until three things were
handled, all now baked into `test-add-scheduler.sh`: the build needed root
(`sudo podman`); H00F's `/etc/containers/registries.conf` defined no
unqualified-search registries, so the Dockerfile's bare `FROM waggle/plugin-base`
would not resolve (fixed by fully-qualifying it to docker.io in a throwaway
Dockerfile copy, so the patched source tree is never dirtied); and the multi-stage
Dockerfile needed `--build-arg TARGETARCH` and `VERSION`. Go compiles inside the
container, so no host Go was ever needed on the node.

The original pluginctl gotcha was phrased as "a *stale* host pluginctl builds pods
client-side and won't show injection". The current docs state it more generally:
the host pluginctl always builds pods client-side, so pluginctl-launched pods do not
get the injection.

## Considered, not built: a `node-info.json` phase 2

*(moved from HANDOFF "Folding into base CI")*

A richer, still-whitelisted `node-info.json` file channel was considered: a
`waggle-node-info` ConfigMap mounted at `/run/waggle/node-info.json`, mirroring
`data-config.json`, for structured surfaces like a sanitized sensor list. Env alone
covers the five identity scalars, so it was not built.

## Reboot observations

`wes-identity` after reboots: an H041 power-cut reboot left the 5-var ConfigMap
intact; earlier H00F notes saw it revert to the stock 2 vars. `update-stack.sh`
regenerates it from the manifest on every run (stock: 2 vars, until patch 0001 is
merged). Side-loaded images survived the H041 power-cut reboot. Tier 2 has not been
tested across a reboot.
