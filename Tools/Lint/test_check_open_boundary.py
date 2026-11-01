#!/usr/bin/env python3
"""Exercise the boundary check in disposable Git repositories."""

import contextlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("check-open-boundary")
EXCEPTIONS = "Tools/Lint/open-boundary-exceptions.txt"
PRIVATE = bytes.fromhex("5054534c").decode()
VENDOR = "com.vendor.Editor"


class BoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader("open_boundary", str(SCRIPT))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.check = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = cls.check
        loader.exec_module(cls.check)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test User")
        self.git("config", "user.email", "test@example.com")
        self.exceptions()

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.root, check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        self.git("add", "--", path)

    def exceptions(self, ceiling=0, entries=()):
        self.write(EXCEPTIONS, f"# transitional ceiling: {ceiling}\n" + "\n".join(entries) + "\n")

    def entry(self, path="Sources/One.swift", literal=VENDOR, kind="transitional"):
        return f"bundle-id | {path} | {literal} | {kind} | browser category policy"

    def commit(self, message="Initial state"):
        self.git("-c", "commit.gpgsign=false", "commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def run_check(self, *args, expected=0, root=None):
        result = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), *args],
            cwd=root or self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_private_word_in_a_comment_fails(self):
        self.write("Tests/One.swift", "// " + PRIVATE)
        self.assertIn("Tests/One.swift:1: words unlisted", self.run_check(expected=1))

    def test_private_word_in_a_file_name_fails(self):
        path = "Documentation/" + PRIVATE + ".md"
        self.write(path, "Clean content")
        self.assertIn(path + ":1: words", self.run_check(expected=1))

    def test_uppercase_rule_ignores_accepts_label(self):
        self.write("Tests/One.swift", "func acceptsLabelOrBareIndex() {}")
        self.run_check()

    def test_generic_words_pass(self):
        self.write("Sources/One.swift", bytes.fromhex(
            "6d617070696e672062656e63682063616d706169676e2062726175732d62656e63686d61726b2d637561"
        ).decode())
        self.run_check()

    def test_all_private_patterns_and_cli_scope(self):
        for encoded in (
            "5054534c", "5074736c", "7074736c", "62726175732d6d617070696e67",
            "62726175735f6d617070696e67", "42726175734d617070696e67",
            "70726f2d746f6f6c732d6d617070696e67", "6d617070696e672d7365747570",
            "62726175732d62656e6368", "62656e63686b6974", "63616d706169676e2d6c697665",
            "62616e636f", "6d6170706174757261",
        ):
            with self.subTest(encoded=encoded):
                self.write("Tools/Engine/braus/entry.py", bytes.fromhex(encoded).decode())
                self.run_check(expected=1)

    def test_vendor_bundle_id_in_code_fails_and_in_comment_passes(self):
        path = "Sources/One.swift"
        self.write(path, f'let value = "{VENDOR}"')
        self.assertIn("bundle-id unlisted", self.run_check(expected=1))
        self.write(path, f'// "{VENDOR}"\n/// "{VENDOR}"\n/* outer /* nested */ "{VENDOR}" */')
        self.run_check()

    def test_comment_markers_inside_strings_and_raw_literals(self):
        self.write("Sources/One.swift", 'let url = "https://example.com"\n' + f'let id = #"{VENDOR}"#')
        self.run_check(expected=1)
        self.write("Sources/One.swift", 'let text = "/* text */ \\" value"\n' + f'let id = """\n{VENDOR}\n"""')
        self.run_check(expected=1)

    def test_bundle_ids_in_tests_and_documents_pass(self):
        for path in ("Tests/One.swift", "Documentation/One.md", "BrausApp/App/BrausTests/One.swift",
                     "Tools/Engine/braus/entry.py"):
            self.write(path, f'"{VENDOR}"')
        self.run_check()

    def test_interpolation_preserves_nested_code_and_comment_boundaries(self):
        self.write("Sources/One.swift", 'let text = "value \\(lookup("' + VENDOR + '"))"')
        self.run_check(expected=1)
        self.write("Sources/One.swift", 'let text = "value \\(lookup("// text"))"\n' + f'// "{VENDOR}"')
        self.run_check()

    def test_every_bundle_prefix_and_exact_literals(self):
        for prefix in ("com", "org", "net", "io", "de", "co", "us"):
            with self.subTest(prefix=prefix):
                self.write("Sources/One.swift", f'"{prefix}.vendor.Editor"')
                self.run_check(expected=1)
        self.write("Sources/One.swift", '"https://com.vendor.Editor"\n" com.vendor.Editor"\n'
                   '"com.vendor.Editor/path"\n"ru.vendor.Editor"')
        self.run_check()

    def test_app_source_is_checked(self):
        self.write("BrausApp/App/Braus/One.swift", f'"{VENDOR}"')
        self.run_check(expected=1)

    def test_apple_example_and_product_ids_pass(self):
        self.write("Sources/One.swift", '\n'.join(f'"{prefix}App"' for prefix in (
            "com.apple.", "com.example.", "org.example.", "com.forte.",
        )))
        self.run_check()

    def test_listed_exception_passes_and_stale_exception_fails(self):
        self.write("Sources/One.swift", f'"{VENDOR}"')
        self.exceptions(1, [self.entry()])
        self.run_check()
        self.write("Sources/One.swift", "let clean = true")
        self.assertIn("stale exception", self.run_check(expected=1))

    def test_exceptions_do_not_cover_other_literals_or_words(self):
        self.write("Sources/One.swift", f'"{VENDOR}"\n"net.other.Editor"')
        self.exceptions(1, [self.entry()])
        self.run_check(expected=1)
        self.write("Sources/One.swift", "// " + PRIVATE)
        self.exceptions(0, [f"words | Sources/One.swift | {PRIVATE} | category | policy"])
        self.run_check(expected=1)

    def test_transitional_over_ceiling_fails(self):
        self.write("Sources/One.swift", f'"{VENDOR}"')
        self.exceptions(0, [self.entry()])
        self.assertIn("exceeds ceiling", self.run_check(expected=1))

    def test_against_ref_refuses_a_higher_ceiling(self):
        base = self.commit()
        self.exceptions(1)
        self.assertIn("ceiling increased", self.run_check("--against", base, expected=1))

    def test_strict_refuses_transitional(self):
        self.write("Sources/One.swift", f'"{VENDOR}"')
        self.exceptions(1, [self.entry()])
        self.run_check("--strict", expected=1)
        self.exceptions(0, [self.entry(kind="category")])
        self.run_check("--strict")

    def test_structural_split_keeps_the_ceiling(self):
        self.write("Sources/One.swift", f'"{VENDOR}"\n"{VENDOR}"')
        self.exceptions(2, [self.entry()])
        base = self.commit()
        self.write("Sources/One.swift", f'"{VENDOR}"')
        self.write("Sources/Two.swift", f'"{VENDOR}"')
        self.exceptions(2, [self.entry(), self.entry(path="Sources/Two.swift")])
        self.run_check("--against", base)
        self.write("Sources/Two.swift", f'"{VENDOR}"\n"{VENDOR}"')
        self.run_check("--against", base, expected=1)

    def test_bootstrap_missing_file_allows_14_not_15(self):
        self.git("rm", "-f", "--", EXCEPTIONS)
        self.write("README.md", "Initial state")
        base = self.commit()
        self.git("update-ref", "refs/remotes/origin/test-base", base)
        for ceiling, expected in ((14, True), (15, False)):
            with self.subTest(ceiling=ceiling), contextlib.redirect_stdout(io.StringIO()) as output:
                result = self.check.compare_baseline(
                    self.root, base, ceiling,
                    bootstrap_ref="origin/test-base", bootstrap_prefix=base[:8],
                )
                self.assertEqual(result, expected)
                self.assertIn("initial ceiling: 14; baseline has no exceptions file", output.getvalue())

    def test_other_missing_file_fails(self):
        self.git("rm", "-f", "--", EXCEPTIONS)
        self.write("README.md", "Initial state")
        base = self.commit()
        self.exceptions()
        self.git("update-ref", "refs/remotes/origin/elio/interactive-bg", base)
        self.run_check("--against", base, expected=2)
        self.git("update-ref", "refs/remotes/origin/test-base", base)
        self.write("README.md", "Next state")
        other = self.commit()
        self.git("rm", "--", EXCEPTIONS)
        other = self.commit()
        self.exceptions()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(self.check.compare_baseline(
                self.root, other, 0, bootstrap_ref="origin/test-base", bootstrap_prefix=base[:8],
            ))

    def test_invalid_ref_and_unreadable_tree_exit_2(self):
        self.run_check("--against", "no-such-ref", expected=2)
        self.write(EXCEPTIONS, "invalid\n")
        self.run_check("--against", "no-such-ref", expected=2)
        self.exceptions()
        base = self.commit()
        original = self.check.git
        for operation in ("ls-tree", "show"):
            def fail(root, *args):
                if args[0] == operation:
                    raise self.check.SearchError("injected Git read error")
                return original(root, *args)
            with mock.patch.object(self.check, "git", side_effect=fail):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(self.check.main(["--against", base], root=self.root), 2)

    def test_existing_malformed_file_fails(self):
        self.write(EXCEPTIONS, "invalid\n")
        base = self.commit()
        self.exceptions()
        self.run_check("--against", base, expected=1)
        for text in ("", "# transitional ceiling: -1\n", "# transitional ceiling: 0\nbad\n",
                     "# transitional ceiling: 0\n# transitional ceiling: 1\n",
                     "# transitional ceiling: 0\n" + self.entry(kind="unknown")):
            self.write(EXCEPTIONS, text)
            self.run_check(expected=1)

    def test_post_bootstrap_13_to_14_fails(self):
        self.exceptions(13)
        base = self.commit()
        self.exceptions(14)
        self.run_check("--against", base, expected=1)

    def test_ceiling_counts_occurrences_not_pairs(self):
        self.write("Sources/One.swift", f'"{VENDOR}"\n"{VENDOR}"')
        self.exceptions(1, [self.entry()])
        self.run_check(expected=1)
        self.exceptions(2, [self.entry()])
        self.assertIn("transitional=2", self.run_check())

    def test_commit_message_with_private_word_fails(self):
        base = self.commit()
        self.write("README.md", "Next state")
        self.commit(PRIVATE)
        self.assertIn("commits unlisted", self.run_check("--commits", f"{base}..HEAD", expected=1))
        self.run_check()
        self.run_check("--commits", "missing..HEAD", expected=2)

    def test_unsearchable_tree_exits_2(self):
        with tempfile.TemporaryDirectory() as outside:
            self.run_check(root=outside, expected=2)
        with mock.patch.object(self.check, "git", side_effect=self.check.SearchError("cannot list files")):
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(self.check.main([], root=self.root), 2)


if __name__ == "__main__":
    unittest.main()
