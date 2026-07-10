#!/usr/bin/env bash
# test-gen-wes-identity.sh -- pure-bash test suite for gen-wes-identity.sh.
# No deps beyond bash + jq (which the generator itself requires). Run: ./test-gen-wes-identity.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/gen-wes-identity.sh"
FIX="$HERE/fixtures"

pass=0; fail=0
ok()   { printf "  ok   %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  FAIL %s\n     expected: %s\n     got:      %s\n" "$1" "$2" "$3"; fail=$((fail+1)); }

# get VALUE of KEY from a generated env blob ("" if key absent)
val() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;found=1} END{if(!found)print ""}'; }
# does KEY appear at all?
has() { printf '%s\n' "$1" | grep -q "^$2="; }

run() { WAGGLE_CONFIG_DIR="$FIX/$1" bash "$GEN" 2>/dev/null; }

eq() { # desc, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

echo "== H00F (camera node: real gps, no mobility field) =="
OUT="$(run h00f)"
eq  "vsn=H00F"                 "H00F"                 "$(val "$OUT" WAGGLE_NODE_VSN)"
eq  "node_id lowercased"       "00004cbb4701d16c"     "$(val "$OUT" WAGGLE_NODE_ID)"
eq  "gps_lat real"             "41.7179852752395"     "$(val "$OUT" WAGGLE_NODE_GPS_LAT)"
eq  "gps_lon real"             "-87.98271513806043"   "$(val "$OUT" WAGGLE_NODE_GPS_LON)"
eq  "mobility absent -> empty" ""                     "$(val "$OUT" WAGGLE_NODE_MOBILITY)"
# leak checks: none of the sensitive manifest fields may appear anywhere in output
for leak in "10.31.81.10" "stw-cgi" "01234567890AB" "Cass Ave" "XNV-8081Z"; do
  if printf '%s' "$OUT" | grep -q "$leak"; then bad "no leak: $leak" "absent" "PRESENT"; else ok "no leak: $leak"; fi
done

echo "== W096 (lorawan node: real gps, deveui/address must NOT leak) =="
OUT="$(run w096)"
eq  "vsn=W096"                 "W096"                 "$(val "$OUT" WAGGLE_NODE_VSN)"
eq  "gps_lat real"             "41.868532807"         "$(val "$OUT" WAGGLE_NODE_GPS_LAT)"
eq  "gps_lon real"             "-87.64589484"         "$(val "$OUT" WAGGLE_NODE_GPS_LON)"
for leak in "0123456789ABCDEF" "Sap_Flow" "Union Ave" "FEDCBA98765" "deveui"; do
  if printf '%s' "$OUT" | grep -q "$leak"; then bad "no leak: $leak" "absent" "PRESENT"; else ok "no leak: $leak"; fi
done

echo "== minimal (default manifest: null gps, no mobility) -> sentinels =="
OUT="$(run minimal)"
eq  "vsn=V999"                 "V999"                 "$(val "$OUT" WAGGLE_NODE_VSN)"
eq  "null gps_lat -> 999"      "999"                  "$(val "$OUT" WAGGLE_NODE_GPS_LAT)"
eq  "null gps_lon -> 999"      "999"                  "$(val "$OUT" WAGGLE_NODE_GPS_LON)"
eq  "mobility -> empty"        ""                     "$(val "$OUT" WAGGLE_NODE_MOBILITY)"

echo "== mobile (mobility field present) =="
OUT="$(run mobile)"
eq  "mobility=mobile"          "mobile"               "$(val "$OUT" WAGGLE_NODE_MOBILITY)"
eq  "gps_lat present"          "41.5"                 "$(val "$OUT" WAGGLE_NODE_GPS_LAT)"

echo "== nomanifest (fresh node: no node-id/vsn files, no manifest) -> all sentinels =="
OUT="$(run nomanifest)"
eq  "vsn missing -> 0"         "0"                    "$(val "$OUT" WAGGLE_NODE_VSN)"
eq  "node_id missing -> empty" ""                     "$(val "$OUT" WAGGLE_NODE_ID)"
eq  "gps_lat missing -> 999"   "999"                  "$(val "$OUT" WAGGLE_NODE_GPS_LAT)"
eq  "gps_lon missing -> 999"   "999"                  "$(val "$OUT" WAGGLE_NODE_GPS_LON)"
eq  "mobility missing -> empty" ""                    "$(val "$OUT" WAGGLE_NODE_MOBILITY)"

echo "== structural: exactly the 5 expected keys, backward-compatible order =="
OUT="$(run h00f)"
KEYS="$(printf '%s\n' "$OUT" | awk -F= 'NF{print $1}' | paste -sd, -)"
eq  "key set + order" "WAGGLE_NODE_ID,WAGGLE_NODE_VSN,WAGGLE_NODE_GPS_LAT,WAGGLE_NODE_GPS_LON,WAGGLE_NODE_MOBILITY" "$KEYS"
# backward-compat: the first two lines are byte-identical to today's upstream output
FIRST2="$(printf '%s\n' "$OUT" | head -2)"
eq  "upstream-compat first 2 lines" "WAGGLE_NODE_ID=00004cbb4701d16c
WAGGLE_NODE_VSN=H00F" "$FIRST2"

echo "== valid env: every line parses as KEY=VALUE and sources cleanly =="
OUT="$(run w096)"
if ( set -a; eval "$OUT" ) 2>/dev/null; then ok "sources without error"; else bad "sources without error" "clean" "error"; fi

echo
echo "-------------------------------------------"
printf "RESULT: %d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
