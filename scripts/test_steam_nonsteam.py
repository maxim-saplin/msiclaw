#!/usr/bin/env python3
"""Unit tests for steam_nonsteam.py (no device required)."""

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import steam_nonsteam as sn  # noqa: E402


class TestDiskDict(unittest.TestCase):
    def test_precision_and_bytes(self):
        gib = 1024 ** 3
        d = sn.disk_dict(int(52.38 * gib), int(217.5 * gib))
        self.assertEqual(d["avail_bytes"], int(52.38 * gib))
        self.assertEqual(d["total_bytes"], int(217.5 * gib))
        self.assertEqual(d["avail_gb"], 52.38)
        self.assertEqual(d["total_gb"], 217.5)


class TestDiskAfterUninstall(unittest.TestCase):
    def test_estimates_when_btrfs_lags(self):
        gib = 1024 ** 3
        before = int(112 * gib)
        total = int(217 * gib)
        freed = int(17 * gib)
        avail, tot, measured = sn.disk_after_uninstall(
            before, total, freed, before, total, 0
        )
        self.assertEqual(measured, freed)
        self.assertEqual(avail, before + freed)

    def test_prefers_measured(self):
        gib = 1024 ** 3
        before = int(112 * gib)
        polled = int(129 * gib)
        avail, _, measured = sn.disk_after_uninstall(
            before, int(217 * gib), int(17 * gib), polled, int(217 * gib), polled - before
        )
        self.assertEqual(avail, polled)
        self.assertEqual(measured, polled - before)


class TestSteamHome(unittest.TestCase):
    def test_respects_home_env(self):
        with patch.dict(os.environ, {"HOME": "/home/user"}):
            self.assertEqual(sn.steam_home(), Path("/home/user"))

    def test_root_home(self):
        with patch.dict(os.environ, {"HOME": "/root"}):
            self.assertEqual(sn.steam_home(), Path("/root"))


class TestBuildListJson(unittest.TestCase):
    @patch("steam_nonsteam.disk_usage", return_value=(100 * 1024 ** 3, 200 * 1024 ** 3))
    def test_schema_keys(self, _mock_disk):
        items = [
            {
                "item_type": "game",
                "appid": 1,
                "name": "Test",
                "total_bytes": 1000,
                "exe": "",
                "install_label": "1 MiB",
                "install_bytes": 500,
                "compat_bytes": 300,
                "shader_bytes": 100,
                "grid_bytes": 100,
            }
        ]
        payload = sn.build_list_json(items)
        self.assertTrue(payload["ok"])
        self.assertIn("disk", payload)
        self.assertIn("items", payload)
        self.assertIn("counts", payload)
        self.assertEqual(payload["counts"]["games"], 1)


class TestItemToJson(unittest.TestCase):
    def test_orphan_steam_app_uninstallable(self):
        item = {
            "item_type": "orphan",
            "appid": 123,
            "name": "orphan 123",
            "kind": "steam app",
            "total_bytes": 1000,
            "compat_bytes": 800,
            "shader_bytes": 200,
        }
        j = sn.item_to_json(item, 1)
        self.assertTrue(j["uninstallable"])

    def test_orphan_no_shortcut_uninstallable(self):
        item = {
            "item_type": "orphan",
            "appid": 456,
            "name": "orphan 456",
            "kind": "no shortcut",
            "total_bytes": 1000,
            "compat_bytes": 800,
            "shader_bytes": 200,
        }
        j = sn.item_to_json(item, 2)
        self.assertTrue(j["uninstallable"])


if __name__ == "__main__":
    unittest.main()
