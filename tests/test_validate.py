"""Tests for the validation and metrics tooling."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "metrics"))

import validate as val  # noqa: E402


class TestValidate(unittest.TestCase):
    def test_repo_self_validates(self):
        # the repo's own instance files must validate clean (PENDING pins are warnings)
        self.assertTrue((REPO / "configs" / "repo.yaml").exists())
        cfg = val.load_repo_config()
        self.assertIn("validation", cfg)
        checks = list(val.collect_checks(cfg))
        self.assertGreaterEqual(len(checks), 6)

    def test_collect_checks_parses(self):
        cfg = val.load_repo_config()
        kinds = [k for k, _, _ in val.collect_checks(cfg)]
        self.assertIn("dataset", kinds)
        self.assertIn("manifest", kinds)

    def test_find_pending(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "x.yaml"
            f.write_text("a: PENDING\nb:\n  c: pending\nn: 5\n")
            hits = val.find_pending(f)
            self.assertEqual(len(hits), 2)

    def test_validate_cli_exit_zero(self):
        # without --fail-on-pending the repo must validate (exit 0)
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "validate.py")],
                           capture_output=True, text=True, cwd=REPO)
        self.assertEqual(r.returncode, 0, r.stderr)


class TestAssessContamination(unittest.TestCase):
    def test_screen_mode_without_oracle(self):
        from assess_contamination import screen_assess
        res = screen_assess(Path("assembly.fa"))
        self.assertEqual(res["mode"], "screen")
        self.assertIn("installed", res)


if __name__ == "__main__":
    unittest.main()
