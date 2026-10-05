"""Isolated tests for the Python application embedded in install.sh."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import call, patch


TEST_DIR = tempfile.TemporaryDirectory(prefix="buddy-tests-")
os.environ["BUDDY_CONFIG_FILE"] = str(Path(TEST_DIR.name) / "config.json")
os.environ["BUDDY_LOG_FILE"] = str(Path(TEST_DIR.name) / "buddy.log")
Path(os.environ["BUDDY_CONFIG_FILE"]).write_text(
    json.dumps({
        "admin_user": "test-admin",
        "admin_pass": "test-password-long-enough",
        "telegram_token": "test-token-secret",
        "telegram_chat_id": "12345",
        "zerotier_net": ""
    }),
    encoding="utf-8"
)

APP_DIR = os.environ.get("BUDDY_TEST_APP_DIR")
if APP_DIR:
    sys.path.insert(0, APP_DIR)

import app as buddy  # noqa: E402


class BuddyAppTests(unittest.TestCase):
    def setUp(self):
        self.client = buddy.app.test_client()
        self.config = {
            "admin_user": "test-admin",
            "admin_pass": "test-password-long-enough",
            "telegram_token": "test-token-secret",
            "telegram_chat_id": "12345",
            "zerotier_net": ""
        }
        buddy.config = dict(self.config)
        buddy.lan_has_internet = False
        buddy.wifi_has_internet = False
        buddy.failover_in_progress = False
        buddy.telegram_queue.clear()
        Path(os.environ["BUDDY_CONFIG_FILE"]).write_text(
            json.dumps(self.config), encoding="utf-8"
        )

    def test_all_routes_require_auth(self):
        for path in ("/", "/api/status", "/api/config", "/api/scan", "/api/logs"):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 401)
        self.assertEqual(self.client.post("/api/control/restart").status_code, 401)

    def test_wrong_credentials_are_rejected(self):
        response = self.client.get("/api/status", auth=("test-admin", "wrong-password"))
        self.assertEqual(response.status_code, 401)

    def test_config_get_redacts_secrets(self):
        with patch.object(buddy, "run_cmd", return_value="200 info node-id"):
            response = self.client.get("/api/config", auth=("test-admin", self.config["admin_pass"]))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["admin_pass"], "")
        self.assertEqual(response.json["telegram_token"], "")
        self.assertEqual(response.json["admin_user"], "test-admin")
        self.assertEqual(response.json["zerotier_node_id"], "node-id")

    def test_config_post_keeps_blank_secrets_and_saves_private_file(self):
        payload = {
            "admin_user": "new-admin",
            "admin_pass": "",
            "telegram_token": "",
            "telegram_chat_id": "",
            "zerotier_net": ""
        }
        with patch.object(buddy, "run_cmd", return_value=""):
            response = self.client.post(
                "/api/config", json=payload,
                auth=("test-admin", self.config["admin_pass"])
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(buddy.config["admin_user"], "new-admin")
        self.assertEqual(buddy.config["admin_pass"], self.config["admin_pass"])
        self.assertEqual(buddy.config["telegram_token"], self.config["telegram_token"])
        self.assertEqual(buddy.config["telegram_chat_id"], "")
        saved = json.loads(Path(os.environ["BUDDY_CONFIG_FILE"]).read_text(encoding="utf-8"))
        self.assertEqual(saved["admin_pass"], self.config["admin_pass"])
        self.assertEqual(Path(os.environ["BUDDY_CONFIG_FILE"]).stat().st_mode & 0o777, 0o600)

    def test_config_post_rejects_invalid_json_and_short_password(self):
        auth = ("test-admin", self.config["admin_pass"])
        response = self.client.post("/api/config", data="[]", content_type="application/json", auth=auth)
        self.assertEqual(response.status_code, 400)
        response = self.client.post("/api/config", json={"admin_pass": "short"}, auth=auth)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(buddy.config["admin_pass"], self.config["admin_pass"])

    def test_status_reports_current_state(self):
        buddy.lan_has_internet = True
        buddy.wifi_has_internet = False
        buddy.wifi_signal_strength = "Cafe (73%)"
        buddy.active_channel = "LAN / STARLINK"
        with patch.object(buddy, "run_cmd", return_value="eth0 UP"):
            response = self.client.get(
                "/api/status", auth=("test-admin", self.config["admin_pass"])
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json["lan_internet"])
        self.assertFalse(response.json["wifi_internet"])
        self.assertEqual(response.json["wifi_signal"], "Cafe (73%)")
        self.assertEqual(response.json["active_channel"], "LAN / STARLINK")

    def test_wifi_scan_parses_escaped_colons_and_deduplicates(self):
        listing = "*:Cafe\\:North:83:▂▄▆_:WPA2\n:Open:51:▂▄__:--\n:Open:49:▂___:--"
        with patch.object(buddy, "run_cmd", side_effect=["", listing]):
            networks = buddy.scan_all_wifi_networks()
        self.assertEqual([item["ssid"] for item in networks], ["Cafe:North", "Open"])
        self.assertTrue(networks[0]["in_use"])
        self.assertEqual(networks[0]["security"], "WPA2")

    def test_connect_rejects_bad_payload_and_invalid_ssid(self):
        auth = ("test-admin", self.config["admin_pass"])
        response = self.client.post("/api/connect", data="[]", content_type="application/json", auth=auth)
        self.assertEqual(response.status_code, 400)
        for ssid in ("", "a\x00b", "x" * 33):
            with self.subTest(ssid=repr(ssid)):
                response = self.client.post("/api/connect", json={"ssid": ssid}, auth=auth)
                self.assertEqual(response.status_code, 400)
        response = self.client.post(
            "/api/connect", json={"ssid": "Cafe", "password": "a\x00b"}, auth=auth
        )
        self.assertEqual(response.status_code, 400)

    def test_connect_preserves_percent_and_unicode_ssid_without_shell(self):
        completed = SimpleNamespace(returncode=0, stdout="activated", stderr="")
        with patch.object(buddy.subprocess, "run", return_value=completed) as run:
            response = self.client.post(
                "/api/connect",
                json={"ssid": "Cafe 100% + & Київ", "password": "p a s s"},
                auth=("test-admin", self.config["admin_pass"])
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json["success"])
        self.assertEqual(run.call_args, call(
            ["nmcli", "device", "wifi", "connect", "Cafe 100% + & Київ",
             "ifname", "wlan0", "password", "p a s s"],
            capture_output=True, text=True, timeout=30
        ))

    def test_connect_returns_nmcli_failure_and_timeout(self):
        auth = ("test-admin", self.config["admin_pass"])
        failure = SimpleNamespace(returncode=10, stdout="", stderr="wrong password")
        with patch.object(buddy.subprocess, "run", return_value=failure):
            response = self.client.post("/api/connect", json={"ssid": "Cafe"}, auth=auth)
        self.assertEqual(response.status_code, 502)
        self.assertIn("wrong password", response.json["message"])
        with patch.object(buddy.subprocess, "run", side_effect=buddy.subprocess.TimeoutExpired("nmcli", 30)):
            response = self.client.post("/api/connect", json={"ssid": "Cafe"}, auth=auth)
        self.assertEqual(response.status_code, 504)

    def test_control_rejects_unknown_action_and_runs_valid_action(self):
        auth = ("test-admin", self.config["admin_pass"])
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with patch.object(buddy.subprocess, "run", return_value=completed) as run:
            self.assertEqual(self.client.post("/api/control/pwn", auth=auth).status_code, 400)
            self.assertEqual(self.client.post("/api/control/restart", auth=auth).status_code, 200)
        run.assert_called_once_with(
            ["systemctl", "restart", "wifi-failover.service"],
            capture_output=True, text=True, timeout=20
        )

    def test_control_reports_systemctl_failure(self):
        auth = ("test-admin", self.config["admin_pass"])
        failed = SimpleNamespace(returncode=1, stdout="", stderr="unit failed")
        with patch.object(buddy.subprocess, "run", return_value=failed):
            response = self.client.post("/api/control/restart", auth=auth)
        self.assertEqual(response.status_code, 502)
        self.assertIn("unit failed", response.json["message"])

    def test_set_default_route_metric_removes_stale_metric_route(self):
        route_dump = (
            "default via 192.168.1.1 dev wlan0 proto dhcp metric 50\n"
            "default via 192.168.1.1 dev wlan0 proto dhcp metric 600"
        )
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with patch.object(buddy, "run_cmd", return_value=route_dump), \
             patch.object(buddy.subprocess, "run", return_value=completed) as run:
            self.assertTrue(buddy.set_default_route_metric("wlan0", 600))

        commands = [entry.args[0] for entry in run.call_args_list]
        self.assertIn(
            ["ip", "-4", "route", "replace", "default", "via", "192.168.1.1",
             "dev", "wlan0", "metric", "600"],
            commands
        )
        self.assertIn(
            ["ip", "-4", "route", "del", "default", "via", "192.168.1.1",
             "dev", "wlan0", "metric", "50"],
            commands
        )

    def test_route_policy_promotes_wifi_and_restores_lan_preference(self):
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        active_failover_routes = {
            "eth0": "default via 192.168.1.1 dev eth0 proto dhcp metric 100",
            "wlan0": "default via 10.0.0.1 dev wlan0 proto dhcp metric 600"
        }
        with patch.object(
            buddy, "run_cmd", side_effect=lambda cmd, timeout=20: active_failover_routes[cmd[-1]]
        ), patch.object(buddy.subprocess, "run", return_value=completed) as run:
            buddy.apply_default_route_policy(lan_ok=False, wifi_ok=True)
        promoted = [entry.args[0] for entry in run.call_args_list]
        self.assertIn(
            ["ip", "-4", "route", "replace", "default", "via", "10.0.0.1",
             "dev", "wlan0", "metric", "50"], promoted
        )

        restored_routes = {
            "eth0": "default via 192.168.1.1 dev eth0 proto dhcp metric 100",
            "wlan0": "default via 10.0.0.1 dev wlan0 proto dhcp metric 50"
        }
        with patch.object(
            buddy, "run_cmd", side_effect=lambda cmd, timeout=20: restored_routes[cmd[-1]]
        ), patch.object(buddy.subprocess, "run", return_value=completed) as run:
            buddy.apply_default_route_policy(lan_ok=True, wifi_ok=True)
        restored = [entry.args[0] for entry in run.call_args_list]
        self.assertIn(
            ["ip", "-4", "route", "replace", "default", "via", "10.0.0.1",
             "dev", "wlan0", "metric", "600"], restored
        )
        self.assertIn(
            ["ip", "-4", "route", "del", "default", "via", "10.0.0.1",
             "dev", "wlan0", "metric", "50"], restored
        )

    def test_set_default_route_metric_ignores_interface_without_gateway(self):
        with patch.object(buddy, "run_cmd", return_value=""), \
             patch.object(buddy.subprocess, "run") as run:
            self.assertFalse(buddy.set_default_route_metric("wlan0", 50))
        run.assert_not_called()

    def test_open_wifi_does_not_report_nmcli_failure_as_connected(self):
        failed = SimpleNamespace(returncode=10, stdout="", stderr="connection failed")
        with patch.object(buddy.subprocess, "run", return_value=failed), \
             patch.object(buddy, "check_internet") as check:
            success, message = buddy.connect_open_wifi("Cafe")
        self.assertFalse(success)
        self.assertEqual(message, "connection failed")
        check.assert_not_called()

    def test_failover_uses_existing_wifi_without_scanning(self):
        with patch.object(buddy, "check_internet", return_value=True), \
             patch.object(buddy, "scan_all_wifi_networks") as scan, \
             patch.object(buddy, "send_telegram_message"):
            self.assertEqual(buddy.auto_failover_routine(), "Wi-Fi already active")
        scan.assert_not_called()
        self.assertFalse(buddy.failover_in_progress)

    def test_failover_reports_no_open_network_without_disconnecting_lan(self):
        networks = [{"ssid": "Protected", "security": "WPA2", "signal": "90"}]
        with patch.object(buddy, "check_internet", return_value=False), \
             patch.object(buddy, "scan_all_wifi_networks", return_value=networks), \
             patch.object(buddy, "send_telegram_message"), \
             patch.object(buddy, "run_cmd") as run:
            self.assertEqual(buddy.auto_failover_routine(), "No open networks")
        self.assertFalse(any("eth0" in str(args) for args, _ in run.call_args_list))
        self.assertFalse(buddy.failover_in_progress)

    def test_failover_tries_strongest_open_network_and_does_not_disconnect_eth0(self):
        networks = [
            {"ssid": "weak", "security": "--", "signal": "20"},
            {"ssid": "strong", "security": "", "signal": "90"}
        ]
        with patch.object(buddy, "check_internet", return_value=False), \
             patch.object(buddy, "scan_all_wifi_networks", return_value=networks), \
             patch.object(buddy, "connect_open_wifi", side_effect=[(True, "activated")]) as connect, \
             patch.object(buddy, "send_telegram_message"):
            self.assertEqual(buddy.auto_failover_routine(), "Connected: strong")
        connect.assert_called_once_with("strong")
        self.assertFalse(buddy.failover_in_progress)

    def test_failover_continues_after_failed_wifi_and_always_releases_lock(self):
        networks = [
            {"ssid": "first", "security": "--", "signal": "90"},
            {"ssid": "second", "security": "--", "signal": "40"}
        ]
        with patch.object(buddy, "check_internet", return_value=False), \
             patch.object(buddy, "scan_all_wifi_networks", return_value=networks), \
             patch.object(buddy, "connect_open_wifi", side_effect=[(False, "no route"), (True, "ok")]), \
             patch.object(buddy, "send_telegram_message"), \
             patch.object(buddy, "run_cmd") as run:
            self.assertEqual(buddy.auto_failover_routine(), "Connected: second")
        self.assertIn(call(["nmcli", "device", "disconnect", "wlan0"]), run.call_args_list)
        self.assertFalse(any("eth0" in str(args) for args, _ in run.call_args_list))
        self.assertFalse(buddy.failover_in_progress)


if __name__ == "__main__":
    unittest.main(verbosity=2)

