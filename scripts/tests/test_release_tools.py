from __future__ import annotations

import importlib.util
import re
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release_version = _load(
    "resolve_release_version", ROOT / "scripts" / "resolve_release_version.py"
)
manifest_tool = _load(
    "create_update_manifest", ROOT / "scripts" / "create_update_manifest.py"
)
project_version = _load(
    "read_project_version", ROOT / "scripts" / "read_project_version.py"
)


class ReleaseVersionTests(unittest.TestCase):
    def test_dispatch_version_is_validated(self) -> None:
        self.assertEqual(
            release_version.resolve_version("1.2.3-rc.1", "main"),
            "1.2.3-rc.1",
        )
        with self.assertRaises(ValueError):
            release_version.resolve_version('1.2.3"; echo injected', "main")
        with self.assertRaises(ValueError):
            release_version.resolve_version("1.2.3..rc", "main")

    def test_tag_version_is_used_when_input_is_empty(self) -> None:
        self.assertEqual(release_version.resolve_version("", "v2.4.0"), "2.4.0")

    def test_semver_ordering_guards_monotonic_releases(self) -> None:
        self.assertGreater(release_version.compare_versions("2.0.0", "2.0.0-rc.2"), 0)
        self.assertLess(
            release_version.compare_versions("2.0.0-rc.2", "2.0.0-rc.10"),
            0,
        )
        self.assertEqual(release_version.compare_versions("2.0.0+9", "2.0.0+10"), 0)

    def test_project_version_ignores_flutter_build_number(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pubspec = Path(temp) / "pubspec.yaml"
            pubspec.write_text("name: app\nversion: 3.2.1+47\n", encoding="utf-8")
            self.assertEqual(project_version.read_project_version(pubspec), "3.2.1")
            self.assertEqual(project_version.read_project_build_number(pubspec), 47)

    def test_release_must_match_pubspec_version(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pubspec = Path(temp) / "pubspec.yaml"
            pubspec.write_text("name: app\nversion: 3.2.1+47\n", encoding="utf-8")
            self.assertEqual(
                release_version.read_flutter_version(pubspec), ("3.2.1", 47)
            )
            with self.assertRaises(ValueError):
                release_version.validate_release_pubspec("3.2.2", pubspec)


class ManifestTests(unittest.TestCase):
    def test_release_urls_are_version_pinned(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            (assets / "langbai-resolver-Setup.exe").write_bytes(b"setup")
            (assets / "langbai-resolver-Android.apk").write_bytes(b"apk")
            (assets / "windows-signing-cert-sha256.txt").write_text(
                "a" * 64, encoding="utf-8"
            )
            manifest = manifest_tool.build_manifest(
                version="1.2.3",
                repository="owner/repo",
                notes="notes",
                assets=assets,
            )
        windows = manifest["platforms"]["windows"]
        self.assertIn("/releases/download/v1.2.3/", windows["url"])
        self.assertEqual(windows["signing_certificate_sha256"], "a" * 64)
        self.assertEqual(windows["size_bytes"], 5)

    def test_mobile_only_release_omits_windows(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            (assets / "langbai-resolver-Android.apk").write_bytes(b"apk")
            (assets / "langbai-resolver-iOS.ipa").write_bytes(b"ipa")
            manifest = manifest_tool.build_manifest(
                version="1.2.3",
                repository="owner/repo",
                notes="notes",
                assets=assets,
            )
        self.assertNotIn("windows", manifest["platforms"])
        self.assertIn("android", manifest["platforms"])
        self.assertIn("ios", manifest["platforms"])

    def test_incomplete_windows_release_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            (assets / "langbai-resolver-Android.apk").write_bytes(b"apk")
            (assets / "langbai-resolver-Setup.exe").write_bytes(b"setup")
            with self.assertRaises(FileNotFoundError):
                manifest_tool.build_manifest(
                    version="1.2.3",
                    repository="owner/repo",
                    notes="notes",
                    assets=assets,
                )


class WorkflowTests(unittest.TestCase):
    def test_release_validation_exports_version_to_following_steps(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        commands = re.findall(
            r"python (?:\.\./)?scripts/resolve_release_version\.py "
            r"--pubspec [^\n]+",
            workflow,
        )
        self.assertEqual(len(commands), 6)
        self.assertTrue(all("--github-env" in command for command in commands))

    def test_mobile_release_accepts_skipped_windows_job(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "inputs.include_windows == true || "
            "vars.ENABLE_WINDOWS_SIGNED_BUILD == 'true'",
            workflow,
        )
        self.assertIn(
            "needs.windows.result == 'success' || "
            "needs.windows.result == 'skipped'",
            workflow,
        )

    def test_backend_tests_run_from_backend_directory(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertRegex(
            workflow,
            r"- name: Test backend\n"
            r"\s+working-directory: backend\n"
            r"\s+run: \|\n"
            r"\s+python -m pip install [^\n]+ -r requirements-dev\.lock\n"
            r"\s+python -m pytest tests -q",
        )


if __name__ == "__main__":
    unittest.main()
