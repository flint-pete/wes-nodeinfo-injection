# Changelog

All notable changes to `wes-nodeinfo-injection`. Format loosely follows Keep a
Changelog; this project uses semantic versioning. (Added in 1.0.1; the 1.0.0 entry is
reconstructed from the `v1.0.0` tag message and git log.)

## [Unreleased]

- `install-pluginctl-nodeinfo.sh` now installs to `/usr/local/bin/pluginctl-nodeinfo`
  by default. That's on sudo's `secure_path`, so the command is `sudo pluginctl-nodeinfo run`.
  It's root-owned 0755, like the stock pluginctl.

- **Tier 1b:** `node-test/install-pluginctl-nodeinfo.sh` copies the patched `pluginctl`
  out of the patched edge-scheduler image to `/usr/local/bin/pluginctl-nodeinfo`, so
  hand-launched (`pluginctl run`) pods get `envFrom: wes-identity` like SES jobs. It
  needs only Tier 1. Verified on H039: env injection, the `-e` override, `--env-from`
  coexistence, and node GPS reaching the consumers' Beehive records.
- The image build moved into `lib.sh` (`build_patched_scheduler_image`), shared by
  Tier 1b and Tier 2 (`test-add-scheduler.sh`). The build steps are unchanged.

- Tier-2 verification text (script + README) now says: SES job required, pods are in
  namespace `ses`, and pluginctl pods survive the scheduler's start-up clean-up
  (found during the H039 fresh-install run).

## [1.0.1] - 2026-10-01

- Comments and docs no longer describe the Sage ECR builder as broken; the
  cyberinfrastructure team fixed Thor builds. Native podman build stays the test path.

Student-readiness pass: docs corrected against the code, one safety fix in the node
scripts. Patches (`patches/`) unchanged.

### Fixed
- `node-test/lib.sh` `backup_resource`: previously recorded `__ABSENT__` on ANY
  `kubectl get` failure (no cluster access, wrong kubeconfig, kubectl missing), so a
  later restore would DELETE the real `wes-identity` / scheduler Deployment. Now only
  a real NotFound is recorded as absent; any other error aborts with a clear message
  (suggesting `KUBECTL="sudo k3s kubectl"`).
- `node-test/lib.sh`: default `KUBECTL` is `sudo kubectl` if `kubectl` is on PATH,
  else `sudo k3s kubectl` if only `k3s` is.
- Broken prereq command in README/TESTING/HANDOFF/node-test README:
  `git -C ../.upstream/edge-scheduler apply ../patches/0002-*.patch` fails because
  `git -C` changes directory first. Now
  `git -C ../.upstream/edge-scheduler apply "$(realpath ../patches/0002-edge-scheduler-envfrom-wes-identity.patch)"`
  from `node-test/` (and TESTING.md runs `cd node-test` first).
- `test-add-scheduler.sh` header no longer lists host Go as a requirement (Go
  compiles inside the container). `test-remove-scheduler.sh` no longer hard-codes
  `waggle/edge-scheduler:0.28.0`; it restores whatever image the backup recorded.
- `test-plugin-pod.yaml` / node-test README: the inline reader is a semantically
  equivalent condensed copy of `read_node_info()`, not byte-identical.
- `fixtures/nomanifest/` was empty and therefore missing from fresh clones; added
  `.gitkeep` (the generator only reads `node-id`, `vsn`, `node-manifest-v2.json`).

### Changed (docs)
- README: added "Populating `.upstream/`" (clone URLs, base commits
  waggle-edge-stack `edba812` / edge-scheduler `5391a00`, patch commands) and
  "How this fits the media stack" (Tier 1 alone changes no running plugin; pluginctl
  is client-side; producer uses `--vsn`; links to the hub guide, REBOOT-RECOVERY,
  HOW-IT-WORKS and pywaggle2-nodeinfo). "Applies to upstream HEAD" -> "applies to the
  recorded base commits".
- `get_node_info()` -> `read_node_info()` (the real function); `Plugin.get_node_info()`
  described as the future upstream wrapper.
- Host Go documented as needed only for offline tests; Tier 2 needs `sudo podman`,
  `git`, network access to docker.io.
- TESTING R2 (reboot): side-loaded image usually persists but is not guaranteed;
  `ImagePullBackOff` failure mode and remedy. New R8: re-check `wes-identity` after a
  reboot / always after update-stack.
- `image-sampler2` references -> the current copies of the reader contract
  (pywaggle2-nodeinfo canonical, this mirror, inline pod reader, media-sampler3
  `nodemeta.py`, vendored `node_info.py` in sage-yolo2 and sage-bioclip2). Go test
  fixture container name `image-sampler2` -> `media-sampler3` (name only).
- Private design-doc paths -> public
  https://github.com/flint-pete/sage-design-planning/blob/master/pywaggle2-design.md
  (`gen-wes-identity.sh`, `pywaggle2/node_info_env.py` — the latter kept
  byte-identical with pywaggle2-nodeinfo).
- Added `VERSION` and this `CHANGELOG.md`.

### Moved
- H00F verification story, "learned on H00F" build notes, and the optional
  `node-info.json` phase-2 idea -> `docs/history/NOTES.md`.

## [1.0.0] - 2026-07 (tag `v1.0.0`) — CI handoff

Deliver five node-identity env vars (`WAGGLE_NODE_{ID,VSN,GPS_LAT,GPS_LON,MOBILITY}`)
to plugin pods so pywaggle2 can read them. Two patches:
- `0001` waggle-edge-stack `update-stack.sh` — add GPS + mobility to the
  `wes-identity` ConfigMap.
- `0002` edge-scheduler `resourcemanager.go` — `EnvFrom: wes-identity` (Optional) on
  the plugin container.

Included the offline test suite (bash+jq generator, isolated Go unit, Python e2e),
the `node-test/` side-load + restore scripts (with the restore resourceVersion
conflict fix), and README/HANDOFF/TESTING. Verified end-to-end on live H00F
(ConfigMap → envFrom → reader; scheduler auto-injection; geotagged upload round-trip
in the Sage data API).
