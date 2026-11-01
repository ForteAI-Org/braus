#!/usr/bin/env python3
"""Exercise conservative literal discovery and frozen source identities."""
import importlib.machinery
import importlib.util
import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import tempfile

loader = importlib.machinery.SourceFileLoader('model_text_lint', str(Path(__file__).with_name('check-model-text')))
spec = importlib.util.spec_from_loader(loader.name, loader)
lint = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lint
loader.exec_module(lint)


class ModelTextLintTests(unittest.TestCase):
    def test_inline_constant_and_new_word(self):
        source = 'let description = "Read this."; let fragment = "Stop"; answer(fragment)'
        findings = lint.scan_file('Example.swift', source)
        self.assertEqual([f.raw for f in findings], ['"Read this."', '"Stop"'])
        self.assertTrue(all(f.key not in lint.classifications() for f in findings))

    def test_raw_multiline_and_interpolation(self):
        source = 'let text = #"raw \\#(render("nested"))"#\nlet summary = """\nRead\nmore.\n"""'
        findings = lint.scan_file('Example.swift', source)
        self.assertEqual(len(findings), 3)
        self.assertIn('"nested"', [f.raw for f in findings])
        self.assertTrue(any('Read\nmore.' in f.raw for f in findings))

    def test_comments_and_json_key(self):
        source = '// "Ignore"\n/* nested /* "Ignore" */ end */ let object = ["message": text]'
        findings = lint.scan_file('Example.swift', source)
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].raw, '"message"')
        self.assertEqual(findings[0].symbol, 'object')

    def test_outcome_cause_keys_require_exact_reviewed_identity(self):
        path = 'Sources/Integration/AutomationMCP/CallDispatcher.swift'
        known = lint.classifications()
        for symbol, code in [
            ('refusal', 'uncertainty_refusal'),
            ('refusal', 'historical_value_refusal'),
            ('noSession', 'no_session'),
            ('unconfirmed', 'memory_unconfirmed'),
            ('values', 'invalid_arguments'),
        ]:
            with self.subTest(code=code):
                source = f'let {symbol} = "{code}"'
                finding = lint.scan_file(path, source)[0]
                self.assertEqual(known[finding.key], 'typed outcome cause key in OutcomeText')
                self.assertNotIn(lint.scan_file('Example.swift', source)[0].key, known)
                self.assertNotIn(lint.scan_file(path, f'let unreviewed = "{code}"')[0].key, known)
        self.assertNotIn(lint.scan_file(path, 'let refusal = "new_refusal"')[0].key, known)

    def test_identity_changes_with_sentence(self):
        before = lint.scan_file('Example.swift', 'let text = "Read."')[0]
        after = lint.scan_file('Example.swift', 'let text = "Wait."')[0]
        self.assertNotEqual(before.key, after.key)
        row = f'Example.swift:1 | text | {before.digest} | AutomationMCP | TU5'
        entries = lint.parse_exceptions(row)
        self.assertIn(before.key, entries)
        self.assertNotIn(after.key, entries)

    def test_nested_comments_and_escaped_quotes(self):
        source = r'let text = "Say \"yes\" // still text" /* "no" */'
        self.assertEqual(len(lint.scan_file('Example.swift', source)), 1)

    def test_duplicate_and_ownerless_exception_fail(self):
        digest = 'a' * 64
        row = f'Example.swift:1 | text | {digest} | AutomationMCP | TU5'
        with self.assertRaises(ValueError):
            lint.parse_exceptions(row + '\n' + row)
        with self.assertRaises(ValueError):
            lint.parse_exceptions(row.replace('AutomationMCP', ''))

    def test_symbols_ignore_comments_and_string_contents(self):
        source = '/* let wrong = */ let actual = "let hidden ="; answer("Stop")'
        findings = lint.scan_file('Example.swift', source)
        self.assertEqual([f.symbol for f in findings], ['actual', 'actual'])

    def test_report_checks_all_literal_forms(self):
        sources = [
            'let description = "Stop"',
            'let fragment = "Stop"; answer(fragment)',
            r'let description = "Wait \(count)"',
            'let description = #"Stop"#',
            'let description = """\nStop\n"""',
            'let payload = ["message": "Stop"]',
        ]
        for source in sources:
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = 'Sources/Integration/AutomationMCP/Example.swift'
                (root / path).parent.mkdir(parents=True)
                (root / path).write_text(source)
                (root / lint.EXCEPTIONS).parent.mkdir(parents=True)
                (root / lint.EXCEPTIONS).write_text('')
                known = {f.key: 'JSON key' for f in lint.scan_file(path, source) if f.raw == '"message"'}
                with patch.object(lint, 'CENSUS_FILES', ()), patch.object(lint, 'classifications', return_value=known):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(lint.check(root), 1)
        source = '/* "Ignore" */ let payload = ["message": text]'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = 'Sources/Integration/AutomationMCP/Example.swift'
            (root / path).parent.mkdir(parents=True)
            (root / path).write_text(source)
            (root / lint.EXCEPTIONS).parent.mkdir(parents=True)
            (root / lint.EXCEPTIONS).write_text('')
            known = {f.key: 'JSON key' for f in lint.scan_file(path, source)}
            with patch.object(lint, 'CENSUS_FILES', ()), patch.object(lint, 'classifications', return_value=known):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(lint.check(root), 0)

    def test_unterminated_comment_is_an_error(self):
        with self.assertRaises(ValueError):
            lint.scan_file('Example.swift', '/* nested /* still open */')


if __name__ == '__main__':
    unittest.main()
