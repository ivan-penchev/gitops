"""Tests for the plaintext Secret rule in check_sops.py."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_sops", ROOT / ".github/scripts/check_sops.py")
check_sops = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_sops)


def errors_for(text):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(text)
    errors = []
    check_sops.check_plain_yaml(f.name, errors)
    Path(f.name).unlink()
    return errors


class PlainSecretTest(unittest.TestCase):
    def test_flux_placeholders_pass(self):
        self.assertEqual(errors_for("kind: Secret\nstringData:\n  TOKEN: ${pve_exporter_token}\n"), [])

    def test_literal_value_fails(self):
        self.assertTrue(errors_for("kind: Secret\nstringData:\n  TOKEN: hunter2\n"))

    def test_placeholder_inside_text_fails(self):
        self.assertTrue(errors_for("kind: Secret\nstringData:\n  URL: https://u:${pw}@host\n"))

    def test_data_fails_even_next_to_placeholders(self):
        self.assertTrue(errors_for("kind: Secret\ndata:\n  A: aGk=\nstringData:\n  B: ${b}\n"))

    def test_config_file_of_placeholders_passes(self):
        text = "kind: Secret\nstringData:\n  config.yaml: |\n    clusters:\n      - url: ${url}\n        token: ${token}\n"
        self.assertEqual(errors_for(text), [])

    def test_config_file_with_a_literal_fails(self):
        text = "kind: Secret\nstringData:\n  config.yaml: |\n    clusters:\n      - url: ${url}\n        token: hunter2\n"
        self.assertTrue(errors_for(text))


if __name__ == "__main__":
    unittest.main()
