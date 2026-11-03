#!/usr/bin/env python3
"""Exercise public log and Release replay checks with disposable sources and products."""
import importlib.machinery
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("check-public-logs")
ROOT = Path(__file__).resolve().parents[2]


class SourceFixture:
    @classmethod
    def setUpClass(cls):
        loader = importlib.machinery.SourceFileLoader("public_logs", str(SCRIPT))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        cls.check = importlib.util.module_from_spec(spec)
        loader.exec_module(cls.check)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Sources").mkdir()
        (self.root / "Tools/Lint").mkdir(parents=True)
        self.source = self.root / "Sources/Test.swift"
        self.exceptions = self.root / "Tools/Lint/public-log-exceptions.txt"
        self.exceptions.write_text('{"ceiling": 0}\n')

    def run_check(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return self.check.main(list(args), root=self.root)


class PublicLogSentinelTests(SourceFixture, unittest.TestCase):
    def test_counts_and_typed_durations(self):
        self.source.write_text(r'''let elapsed: Duration = .seconds(1)
let interval: TimeInterval = 1
log("\(items.count, privacy: .public) \(payload.utf8.count, privacy: .public)")
log("\(byteCount, privacy: .public) \(totalBytes, privacy: .public)")
log("\(elapsed, privacy: .public) \(interval.description, privacy: .public)")
log("\(elapsed.formatted(.units(allowed: [.seconds])), privacy: .public)")''')
        self.assertEqual(self.run_check(), 0)

    def test_rejects_identifiers_titles_and_other_values(self):
        for value in ("contact.id", "title", "window.windowNumber", "pid", "enabled", "kind.rawValue"):
            with self.subTest(value=value):
                self.source.write_text('log("\\(' + value + ', privacy: .public)")')
                self.assertEqual(self.run_check(), 1)

    def test_nested_and_multiline_interpolations(self):
        self.source.write_text('log("\\(String(describing: title),\n privacy: .public)")')
        self.assertEqual(self.run_check(), 1)
        self.source.write_text('log("\\(items.map { "\\($0.title)" }, privacy: .public)")')
        self.assertEqual(self.run_check(), 1)

    def test_comments_and_public_token_spacing(self):
        for text in (
            'log("\\(title, privacy: /* ) */ . public)")',
            '/* let title: Duration */ log("\\(title, privacy: .public)")',
        ):
            self.source.write_text(text)
            self.assertEqual(self.run_check(), 1)
        self.source.write_text('// log("\\(title, privacy: .public)")')
        self.assertEqual(self.run_check(), 0)

    def test_exception_metadata_and_growth(self):
        line = r'log("\(title, privacy: .public)")'
        self.source.write_text(line)
        entry = dict(path="Sources/Test.swift", text=line, reason="Legacy text", destination="private", removal="Convert this log")
        self.exceptions.write_text(json.dumps(dict(ceiling=1)) + "\n" + json.dumps(entry) + "\n")
        self.assertEqual(self.run_check(), 0)
        for key in ("reason", "destination", "removal"):
            broken = dict(entry)
            del broken[key]
            self.exceptions.write_text('{"ceiling": 1}\n' + json.dumps(broken) + "\n")
            self.assertEqual(self.run_check(), 1)
        self.exceptions.write_text('{"ceiling": 0}\n' + json.dumps(entry) + "\n")
        self.assertEqual(self.run_check(), 1)

    def test_named_logs_are_private_or_numeric(self):
        paths = (
            "Sources/SeatBroker/Seat/HumanControlCompletion.swift",
            "Sources/SeatBroker/Seat/HumanInterventionConsumer.swift",
            "Sources/SeatBroker/Seat/HumanPreviewControl.swift",
            "BrausApp/App/Braus/Views/House/Screen/Twins/WindowTwins.swift",
            "BrausApp/App/Braus/Views/HumanControl/LendingCompanion.swift",
        )
        phrases = ("human handoff summary:", "title=", "human review replay saved:", "window.title,", "trace.summary,")
        for path, phrase in zip(paths, phrases):
            text = (ROOT / path).read_text()
            lines = [line for line in text.splitlines() if phrase in line]
            self.assertTrue(lines, path)
            for line in lines:
                for expression, _, _ in self.check.interpolations(line):
                    self.assertTrue(self.check.allowed(expression, text), expression)
        self.assertNotIn('.prefix(3).joined', (ROOT / paths[0]).read_text())


class ReleaseHasNoReplayTests(SourceFixture, unittest.TestCase):
    def test_conditional_branches(self):
        marker = 'let path = "handoff-test"'
        for condition in ("DEBUG", "DEBUG && OTHER", "OTHER && DEBUG", "(DEBUG)"):
            self.source.write_text(f"#if {condition}\n{marker}\n#endif\n")
            self.assertEqual(self.run_check(), 0, condition)
        for text in (
            f"#if DEBUG || OTHER\n{marker}\n#endif",
            f"#if DEBUG\n#else\n{marker}\n#endif",
            f"#if OTHER\n#elseif DEBUG\n#else\n{marker}\n#endif",
            f"#if strange(?)\n{marker}\n#endif",
            f"#if OTHER\n#if DEBUG\n#endif\n{marker}\n#endif",
        ):
            self.source.write_text(text)
            self.assertEqual(self.run_check(), 1, text)
        self.source.write_text(f"#if OTHER\n#elseif DEBUG\n{marker}\n#endif")
        self.assertEqual(self.run_check(), 0)

    def test_url_string_cannot_hide_a_marker(self):
        self.source.write_text('let url = "https://example.com"; let path = "handoff-test"')
        self.assertEqual(self.run_check(), 1)

    def test_markers_checked_separately(self):
        for marker in self.check.REPLAY_MARKERS:
            self.source.write_text('let value = "' + marker + '"')
            self.assertEqual(self.run_check(), 1)

    def test_real_replay_branch_without_guard(self):
        real = (ROOT / "Sources/SeatBroker/Seat/HumanPreviewControl.swift").read_text()
        start = real.index("#if DEBUG", real.index("human digest rendering"))
        branch = real[start:real.index("#endif", start) + len("#endif")]
        entries = {line: dict(path="Sources/Test.swift", text=line, reason="Fixture log", destination="private", removal="End fixture")
                   for _, _, line in self.check.interpolations(branch)}
        self.exceptions.write_text(json.dumps(dict(ceiling=len(entries))) + "\n" +
                                   ''.join(json.dumps(entry) + "\n" for entry in entries.values()))
        self.source.write_text(branch)
        self.assertEqual(self.run_check(), 0)
        self.source.write_text(branch.replace("#if DEBUG", "").replace("#endif", ""))
        self.assertEqual(self.run_check(), 1)

    def test_empty_release_directory_fails(self):
        products = self.root / "products"
        products.mkdir()
        self.assertEqual(self.run_check("--release-products", str(products)), 1)

    def test_composed_binary_path_and_debug_elimination(self):
        products = self.root / "products"
        products.mkdir()
        fixture = self.root / "fixture.swift"
        body = 'print("Library/Application Support/Braus/Runs" + "/" + "handoff-fixture")\n'
        for guarded, expected in ((False, 1), (True, 0)):
            fixture.write_text("#if DEBUG\n" + body + "#endif\n" if guarded else body)
            env = dict(os.environ, TOOLCHAINS="com.apple.dt.toolchain.XcodeDefault")
            result = subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(self.root / "cache"),
                                     str(fixture), "-o", str(products / "fixture")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.run_check("--release-products", str(products)), expected)


if __name__ == "__main__":
    unittest.main()
