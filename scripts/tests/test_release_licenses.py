"""Behavioral tests for release notice collection and stale-output detection."""

import importlib.util
import gzip
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "generate_release_licenses.py"


class ReleaseLicenseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if SCRIPT.exists():
            spec = importlib.util.spec_from_file_location("release_licenses", SCRIPT)
            cls.generator = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.generator)
        else:
            cls.generator = None

    def setUp(self):
        self.assertIsNotNone(self.generator, "Release license generator is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))
        return target

    def collect(self, sources):
        return self.generator.collect_component(
            "example", "v1.0.0", "example.org/example", self.root, sources
        )

    def test_preserves_exact_legal_text_and_nested_notice_for_selected_sources(self):
        license_text = "Copyright 2026 Example\r\nPermission is granted.\r\n"
        self.write("LICENSE", license_text)
        self.write("selected/NOTICE.txt", "Additional attribution\n")
        self.write("selected/code.go", "package selected\n")
        self.write("windows/LICENSE", "Windows-only license\n")
        component = self.collect(["selected/code.go"])
        notices = {n["paths"][0]: n for n in component["notices"]}
        self.assertEqual(notices["LICENSE"]["text"], license_text)
        self.assertEqual(notices["selected/NOTICE.txt"]["text"], "Additional attribution\n")
        self.assertNotIn("windows/LICENSE", notices)
        self.assertIn("windows/LICENSE", component["excluded_notice_candidates"])

    def test_deduplicates_identical_headers_without_losing_attribution_paths(self):
        header = "// Copyright 2026 Someone.\n// Licensed under the Example license.\n"
        for name in ("a.go", "b.go"):
            self.write(name, header + "\npackage example\n\nconst Secret = 123\n")
        component = self.collect(["b.go", "a.go"])
        self.assertEqual(len(component["notices"]), 1)
        notice = component["notices"][0]
        self.assertEqual(notice["paths"], ["a.go", "b.go"])
        self.assertEqual(notice["kind"], "source-header")
        self.assertEqual(notice["text"], header)
        self.assertNotIn("Secret", notice["text"])

    def test_missing_license_does_not_invent_a_grant(self):
        self.write("code.go", "// Copyright 2009 The Go Authors.\n// Use is governed by a BSD-style license in the LICENSE file.\n\npackage example\n")
        component = self.collect(["code.go"])
        self.assertFalse(component["has_root_license"])
        self.assertEqual(component["notices"][0]["kind"], "source-header")

    def test_source_named_license_is_not_copied_as_a_legal_document(self):
        self.write("license_test.go", "package tests\nconst Internal = 1\n")
        component = self.collect([])
        self.assertEqual(component["notices"], [])
        self.assertFalse(component["has_root_license"])

    def test_preserves_embedded_javascript_legal_comments_without_copying_code(self):
        header = "/** @license React\n * Copyright Example\n */"
        embedded = self.root / "assets/app.js.gz"
        embedded.parent.mkdir()
        embedded.write_bytes(gzip.compress(("doSomething();\n" + header + "\nrun();").encode()))
        self.write("assets/NOTICE", "Asset attribution\n")
        component = self.collect(["assets/app.js.gz"])
        notices = {n["kind"]: n for n in component["notices"]}
        self.assertEqual(notices["embedded-asset-comment"]["text"], header)
        self.assertEqual(notices["notice-file"]["text"], "Asset attribution\n")
        self.assertNotIn("doSomething", str(notices))

    def test_missing_selected_source_fails_instead_of_silently_omitting_notices(self):
        self.write("LICENSE", "Example license\n")
        with self.assertRaisesRegex(FileNotFoundError, "missing.go"):
            self.collect(["missing.go"])

    def test_inventory_rejects_version_drift_even_when_module_count_matches(self):
        inventory = {"module_count": 1, "modules": [{"module": "example.org/a", "version": "v1"}]}
        packages = [{"Module": {"Path": "example.org/a", "Version": "v2"}}]
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.generator.validate_inventory(inventory, packages)

    def test_local_main_module_has_no_published_version(self):
        inventory = {"module_count": 1, "modules": [{"module": "example.org/main", "version": None}]}
        packages = [{"Module": {"Path": "example.org/main", "Main": True}}]
        self.generator.validate_inventory(inventory, packages)

    def test_outputs_are_deterministic_and_check_does_not_rewrite_stale_files(self):
        self.write("LICENSE", "Copyright Example\nLicense terms\n")
        component = self.collect([])
        bundle = {"schema_version": 1, "scope": "fixture", "unresolved": ["Rights unresolved"], "components": [component]}
        first = self.generator.render_bundle(bundle)
        self.assertEqual(first, self.generator.render_bundle(bundle))
        output = self.root / "output"
        self.assertTrue(self.generator.write_outputs(output, first, check=False))
        self.assertTrue(self.generator.write_outputs(output, first, check=True))
        target = output / "Licenses.txt"
        target.write_text("stale", encoding="utf-8")
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertFalse(self.generator.write_outputs(output, first, check=True))
        self.assertEqual(target.read_text(), "stale")
        metadata = json.loads((output / "DependencyLicenses.json").read_text())
        notice = metadata["components"][0]["notices"][0]
        self.assertNotIn("text", notice)
        self.assertEqual(len(notice["sha256"]), 64)
        self.assertNotIn("Rights unresolved", first["Licenses.txt"])
        self.assertIn("Rights unresolved", first["DependencyLicenses.json"])

    def test_supplemental_notice_fails_if_cached_legal_text_is_corrupt(self):
        directory = "scripts/license_sources/"
        self.write(directory + "LICENSE", "abc")
        manifest = {"scope": "Additional source-distribution notice", "packages": [{
            "name": "example", "version": "1", "source": "https://example.org/source",
            "notices": [{"path": "LICENSE", "upstream_path": "LICENSE", "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]
        }]}
        self.write(directory + "manifest.json", json.dumps(manifest))
        components = self.generator.supplemental_components(self.root)
        self.assertEqual(components[0]["notices"][0]["text"], "abc")
        self.assertEqual(components[0]["selection"], "Additional source-distribution notice")
        self.write(directory + "LICENSE", "changed")
        with self.assertRaisesRegex(ValueError, "hash"):
            self.generator.supplemental_components(self.root)


if __name__ == "__main__":
    unittest.main()
