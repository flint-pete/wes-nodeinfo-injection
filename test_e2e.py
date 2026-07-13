#!/usr/bin/env python3
"""
test_e2e.py -- end-to-end: WES gen script -> env file -> process env -> pywaggle2 reader.

Chains the real pieces in production order:
  1. run gen-wes-identity.sh against a fixture node dir (the WES config-gen step)
  2. capture its output as the env a pod would receive via `wes-identity` ConfigMap
  3. load that env into a fresh process and run pywaggle2's read_node_info()
  4. assert the resolved NodeInfo (real values on real nodes; None on sentinels)

Proves the ~5 env vars are produced correctly AND consumed correctly by pywaggle2,
with the sentinel->None normalization intact across the boundary.
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "gen-wes-identity.sh")
FIX = os.path.join(HERE, "fixtures")
sys.path.insert(0, os.path.join(HERE, "pywaggle2"))
from node_info_env import read_node_info  # noqa: E402


def gen_env(fixture):
    """Run the WES generator for a fixture; return {KEY:VALUE} dict (pod env)."""
    out = subprocess.run(
        ["bash", GEN],
        env={**os.environ, "WAGGLE_CONFIG_DIR": os.path.join(FIX, fixture)},
        capture_output=True, text=True, check=True,
    ).stdout
    env = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            env[k] = v
    return env


def resolve(fixture):
    """Full chain: generate env, then read it back through pywaggle2's reader."""
    return read_node_info(env=gen_env(fixture))


class TestEndToEnd(unittest.TestCase):
    def test_h00f_camera_real_values(self):
        ni = resolve("h00f")
        self.assertEqual(ni.vsn, "H00F")
        self.assertEqual(ni.node_id, "00004cbb4701d16c")
        self.assertAlmostEqual(ni.lat, 41.7179852752395)
        self.assertAlmostEqual(ni.lon, -87.98271513806043)
        self.assertEqual(ni.mobility, "unknown")   # h00f manifest has no mobility key (verified) -> unknown
        self.assertFalse(ni.vsn_is_placeholder)

    def test_w096_lorawan_real_values(self):
        ni = resolve("w096")
        self.assertEqual(ni.vsn, "W096")
        self.assertAlmostEqual(ni.lat, 41.868532807)
        self.assertAlmostEqual(ni.lon, -87.64589484)
        self.assertEqual(ni.mobility, "unknown")

    def test_minimal_null_gps_becomes_none(self):
        ni = resolve("minimal")
        self.assertEqual(ni.vsn, "V999")           # V999 is a real (test) vsn, not the "0" sentinel
        self.assertIsNone(ni.lat)                  # 999 sentinel -> None (never faked)
        self.assertIsNone(ni.lon)
        self.assertEqual(ni.mobility, "unknown")

    def test_mobile_fixture(self):
        ni = resolve("mobile")
        self.assertEqual(ni.mobility, "mobile")
        self.assertAlmostEqual(ni.lat, 41.5)

    def test_fresh_node_all_sentinels_to_none(self):
        ni = resolve("nomanifest")
        self.assertIsNone(ni.vsn)                  # "0" sentinel -> None
        self.assertTrue(ni.vsn_is_placeholder)
        self.assertIsNone(ni.node_id)
        self.assertIsNone(ni.lat)
        self.assertIsNone(ni.lon)
        self.assertEqual(ni.mobility, "unknown")

    def test_never_fabricate_coords_invariant(self):
        # The whole reason for range-based sentinel detection: a plugin building an
        # EXIF geotag must get None (and OMIT the tag), never a bogus coordinate.
        for fx in ("minimal", "nomanifest"):
            ni = resolve(fx)
            self.assertIsNone(ni.lat, f"{fx}: lat must be None, not fabricated")
            self.assertIsNone(ni.lon, f"{fx}: lon must be None, not fabricated")

    def test_explicit_env_overrides_generated(self):
        # pod-level env (e.g. operator override) wins over the ConfigMap-projected
        # value -- mirrors the k8s Env-over-EnvFrom precedence the scheduler relies on.
        env = gen_env("nomanifest")
        env["WAGGLE_NODE_VSN"] = "W042"
        ni = read_node_info(env=env)
        self.assertEqual(ni.vsn, "W042")
        self.assertFalse(ni.vsn_is_placeholder)


if __name__ == "__main__":
    unittest.main(verbosity=2)
