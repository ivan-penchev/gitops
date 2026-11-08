"""Offline contracts for the homelab notification wiring (no credentials needed)."""

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
FLUX = ROOT / "kubernetes/notifications/telegram"
MONITOR = ROOT / "kubernetes/apps/monitor/configs"


def load(path):
    return yaml.safe_load(path.read_text())


class AlertingTests(unittest.TestCase):
    def test_flux_covers_repository_resources(self):
        alert = load(FLUX / "alert.yaml")
        sources = alert["spec"]["eventSources"]
        coverage = {(s["kind"], s["namespace"]) for s in sources}
        self.assertTrue(all(s["name"] == "*" for s in sources))
        self.assertEqual(alert["spec"]["eventSeverity"], "error")
        kinds = {"GitRepository", "OCIRepository", "HelmRepository", "HelmChart",
                 "Kustomization", "HelmRelease", "Bucket", "FluxInstance"}
        for path in (ROOT / "kubernetes").rglob("*.yaml"):
            if ".sops." in path.name:
                continue
            for resource in yaml.safe_load_all(path.read_text()):
                if not isinstance(resource, dict) or resource.get("kind") not in kinds:
                    continue
                if resource.get("apiVersion", "").startswith("kustomize.config."):
                    continue
                pair = (resource["kind"], resource.get("metadata", {}).get("namespace", "flux-system"))
                with self.subTest(path=path):
                    self.assertIn(pair, coverage)

    def test_namespace_local_encrypted_credentials(self):
        for directory, namespace in [(FLUX, "flux-system"), (MONITOR, "monitoring")]:
            secret = load(directory / "telegram-token.sops.yaml")
            self.assertEqual(secret["metadata"], {"name": "telegram-bot-token", "namespace": namespace})
            self.assertTrue(secret["stringData"]["token"].startswith("ENC[AES256_GCM,"))
            self.assertIn("sops", secret)
            self.assertIn("telegram-token.sops.yaml", load(directory / "kustomization.yaml")["resources"])
        provider = load(FLUX / "provider.yaml")
        receiver = load(MONITOR / "telegram-alertmanagerconfig.yaml")["spec"]["receivers"][0]["telegramConfigs"][0]
        self.assertEqual(provider["spec"]["secretRef"]["name"], "telegram-bot-token")
        self.assertEqual(receiver["botToken"], {"name": "telegram-bot-token", "key": "token"})
        self.assertEqual(str(receiver["chatID"]), provider["spec"]["channel"])
        self.assertTrue(receiver["sendResolved"])

    def test_cluster_wide_routes_are_trusted_and_selected(self):
        release = load(ROOT / "kubernetes/apps/monitor/controllers/kube-prometheus-stack/app/helmrelease.yaml")
        spec = release["spec"]["values"]["alertmanager"]["alertmanagerSpec"]
        config = load(MONITOR / "telegram-alertmanagerconfig.yaml")
        self.assertEqual(spec["alertmanagerConfigMatcherStrategy"], {"type": "None"})
        self.assertEqual(spec["alertmanagerConfigNamespaceSelector"],
                         {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}})
        for key, value in spec["alertmanagerConfigSelector"]["matchLabels"].items():
            self.assertEqual(config["metadata"]["labels"][key], value)
        self.assertTrue(release["spec"]["values"]["defaultRules"]["create"])

    def test_routing_noise_controls(self):
        route = load(MONITOR / "telegram-alertmanagerconfig.yaml")["spec"]["route"]
        matchers = {m["name"]: m for m in route["matchers"]}
        self.assertEqual(matchers["severity"]["matchType"], "=~")
        self.assertEqual(matchers["alertname"]["matchType"], "!~")
        for severity, expected in [("warning", True), ("critical", True), ("info", False), ("none", False)]:
            self.assertEqual(bool(re.fullmatch(matchers["severity"]["value"], severity)), expected)
        for name in ["Watchdog", "InfoInhibitor"]:
            self.assertIsNotNone(re.fullmatch(matchers["alertname"]["value"], name))
        self.assertNotIn("namespace", matchers)
        self.assertEqual(route["repeatInterval"], "12h")

    def test_flux_owner_decrypts_secrets(self):
        owner = load(ROOT / "kubernetes/clusters/homelab/notifications.yaml")["spec"]
        self.assertEqual((ROOT / owner["path"]).resolve(), FLUX)
        self.assertEqual(owner["decryption"], {"provider": "sops", "secretRef": {"name": "sops-age"}})
        self.assertTrue(owner["prune"])
        self.assertNotIn("dependsOn", owner)


if __name__ == "__main__":
    unittest.main()
