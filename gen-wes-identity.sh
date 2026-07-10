#!/bin/bash
# gen-wes-identity.sh -- generate the wes-identity.env used by the WES
# `wes-identity` ConfigMap, EXTENDED with node GPS + mobility.
#
# This is the extracted, standalone, testable form of the identity-config block in
# waggle-edge-stack `kubernetes/update-stack.sh::update_wes()`. Upstream today writes
# only WAGGLE_NODE_ID + WAGGLE_NODE_VSN (see .upstream copy, ~L196-L203). This adds
# the three fields pywaggle2's node-info accessor needs -- GPS lat/lon + mobility --
# read from the node manifest, in the SAME env-var style as the existing two.
#
# Design refs: ~/AI-projects/pywaggle2-design.md sec 2.4.3 (env scalars) + 2.4.4
# (concrete diff). Sentinels match sec 2.2.3 so pywaggle2 normalizes uniformly:
#   VSN missing        -> 0
#   node_id missing    -> (unset / empty)
#   lat/lon missing    -> 999   (off-globe; 0 is Null Island = a REAL coord)
#   mobility missing   -> (unset -> pywaggle2 resolves to "unknown")
#
# Faithful to upstream: reads node-id/vsn from ${WAGGLE_CONFIG_DIR} exactly like the
# upstream node_id()/node_vsn() helpers; reads gps/mobility from the manifest via jq.
#
# Usage:
#   WAGGLE_CONFIG_DIR=/etc/waggle ./gen-wes-identity.sh            # -> stdout
#   WAGGLE_CONFIG_DIR=./fixtures/h00f ./gen-wes-identity.sh > out.env
set -euo pipefail

WAGGLE_CONFIG_DIR="${WAGGLE_CONFIG_DIR:-/etc/waggle}"
NODE_MANIFEST_V2="${NODE_MANIFEST_V2:-node-manifest-v2.json}"
MANIFEST_PATH="${MANIFEST_PATH:-${WAGGLE_CONFIG_DIR}/${NODE_MANIFEST_V2}}"

# --- identity scalars: mirror upstream node_id()/node_vsn() (case-normalized) ----
# Upstream reads bare files /etc/waggle/{node-id,vsn}. Missing file -> sentinel.
if [ -r "${WAGGLE_CONFIG_DIR}/node-id" ]; then
  WAGGLE_NODE_ID="$(awk '{print tolower($0)}' "${WAGGLE_CONFIG_DIR}/node-id")"
else
  WAGGLE_NODE_ID=""          # unset sentinel: emitted empty (pywaggle2 -> None)
fi

if [ -r "${WAGGLE_CONFIG_DIR}/vsn" ]; then
  WAGGLE_NODE_VSN="$(awk '{print toupper($0)}' "${WAGGLE_CONFIG_DIR}/vsn")"
else
  WAGGLE_NODE_VSN="0"        # VSN sentinel (never a real vsn)
fi

# --- new: GPS + mobility from the manifest ---------------------------------------
# jq extracts a scalar; if the field is absent/null we substitute the sentinel.
# NOTE: `mobility` does NOT yet exist in node-manifest-v2.json upstream (design
# sec 2.3 proposes adding it, default "static"). Until it lands, this resolves to
# the unset sentinel -> pywaggle2 treats it as "unknown", which is correct.
jq_scalar() {  # $1 = jq path expr, $2 = sentinel when null/absent/missing-file
  local expr="$1" sentinel="$2"
  if [ -r "${MANIFEST_PATH}" ]; then
    jq -r "(${expr}) // \"${sentinel}\"" "${MANIFEST_PATH}" 2>/dev/null || echo "${sentinel}"
  else
    echo "${sentinel}"
  fi
}

WAGGLE_NODE_GPS_LAT="$(jq_scalar '.gps_lat' 999)"
WAGGLE_NODE_GPS_LON="$(jq_scalar '.gps_lon' 999)"
# `// ""` inside jq_scalar means a genuinely-missing mobility yields the sentinel:
WAGGLE_NODE_MOBILITY="$(jq_scalar '.mobility' '')"

# --- emit (identical stanza style to upstream wes-identity.env) -------------------
# Order: existing two first (byte-compatible with today), then the three additions.
cat <<EOF
WAGGLE_NODE_ID=${WAGGLE_NODE_ID}
WAGGLE_NODE_VSN=${WAGGLE_NODE_VSN}
WAGGLE_NODE_GPS_LAT=${WAGGLE_NODE_GPS_LAT}
WAGGLE_NODE_GPS_LON=${WAGGLE_NODE_GPS_LON}
WAGGLE_NODE_MOBILITY=${WAGGLE_NODE_MOBILITY}
EOF
