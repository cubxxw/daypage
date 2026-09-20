#!/usr/bin/env python3
"""Regression tests for scripts/localization_reference_check.py.

Run from the repository root:

    python3 -m unittest discover -s scripts/tests -p 'test_localization*.py'

The fixtures exercise the checker contract:
  * a key that exists in NEITHER locale but is referenced statically fails;
  * a key present in both locales passes;
  * a key present in only one locale is reported per-locale;
  * format-placeholder mismatches are reported, ``%%`` is not a placeholder;
  * comments, raw display text and dynamically-composed keys are ignored;
  * ``Text("key")`` and ``Text("key", bundle:)`` are both recognized.
"""

from __future__ import annotations

import contextlib
import io
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SCRIPTS_DIR.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import localization_reference_check as lrc  # noqa: E402


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content), encoding="utf-8")


class Fixture:
    """Builds an isolated repository-shaped fixture on disk."""

    def __init__(self, test_case: unittest.TestCase) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        test_case.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.en = self.root / "DayPage/Resources/en.lproj/Localizable.strings"
        self.zh = self.root / "DayPage/Resources/zh-Hans.lproj/Localizable.strings"

    def swift(self, body: str, name: str = "Fixture.swift") -> None:
        _write(self.root / "DayPage/App" / name, body)

    def strings(self, en: str, zh: str) -> None:
        _write(self.en, en)
        _write(self.zh, zh)

    def check(self) -> lrc.CheckResult:
        return lrc.check_repository(self.root, self.en, self.zh)


class MissingReferenceTests(unittest.TestCase):
    def test_equal_but_missing_key_fails(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("ghost.key", comment: "")\n')
        # Locale files agree with each other, yet the key exists in neither.
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        result = fixture.check()

        self.assertFalse(result.ok)
        self.assertIn("ghost.key", result.missing_from_both)

    def test_present_key_passes(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            'let a = NSLocalizedString("present.key", comment: "")\n'
            'let b = LocalizedStringKey("also.present")\n'
        )
        fixture.strings(
            '"present.key" = "Present";\n"also.present" = "Also";\n',
            '"present.key" = "存在";\n"also.present" = "也在";\n',
        )

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 2)

    def test_missing_in_english_locale_reported(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("zh.only.key", comment: "")\n')
        fixture.strings('"present.key" = "Present";\n', '"zh.only.key" = "仅中文";\n')

        result = fixture.check()

        self.assertIn("zh.only.key", result.missing_in_en)
        self.assertNotIn("zh.only.key", result.missing_from_both)

    def test_missing_in_chinese_locale_reported(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("en.only.key", comment: "")\n')
        fixture.strings('"en.only.key" = "English only";\n', '"present.key" = "存在";\n')

        result = fixture.check()

        self.assertIn("en.only.key", result.missing_in_zh)
        self.assertNotIn("en.only.key", result.missing_from_both)


class PlaceholderTests(unittest.TestCase):
    def test_placeholder_mismatch_is_flagged(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("count.key", comment: "")\n')
        fixture.strings('"count.key" = "%d items";\n', '"count.key" = "%@ 条";\n')

        result = fixture.check()

        self.assertFalse(result.ok)
        self.assertIn("count.key", result.placeholder_mismatches)

    def test_matching_placeholders_pass(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("count.key", comment: "")\n')
        fixture.strings('"count.key" = "%1$d of %2$d";\n', '"count.key" = "%1$d / %2$d";\n')

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))

    def test_escaped_percent_is_not_a_placeholder(self) -> None:
        # EN spells out "percent"; ZH uses an escaped %%%. Both carry %@ and %d.
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("progress.key", comment: "")\n')
        fixture.strings(
            '"progress.key" = "%@, %d percent";\n',
            '"progress.key" = "%@，完成 %d%%";\n',
        )

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))

    def test_unnumbered_argument_type_reordering_fails(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("count.key", comment: "")\n')
        fixture.strings(
            '"count.key" = "%@ has %d items";\n',
            '"count.key" = "%d 条属于 %@";\n',
        )
        result = fixture.check()
        self.assertFalse(result.ok)
        self.assertIn("count.key", result.placeholder_mismatches)

    def test_explicit_argument_positions_allow_safe_translated_order(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("count.key", comment: "")\n')
        fixture.strings(
            '"count.key" = "%@ has %d items";\n',
            '"count.key" = "%2$d 条属于 %1$@";\n',
        )
        result = fixture.check()
        self.assertTrue(result.ok, lrc.format_report(result))

    def test_non_format_prose_with_percent_is_not_flagged(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("usage.key", comment: "")\n')
        fixture.strings(
            '"usage.key" = "You have used 80% of the budget.";\n',
            '"usage.key" = "已用掉预算的 80%。";\n',
        )

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))

    def test_format_specifier_parser(self) -> None:
        self.assertEqual(lrc.format_specifiers("%1$@, %2$lld"), ("%1$@", "%2$lld"))
        self.assertEqual(lrc.format_specifiers("100%% done"), ())
        self.assertEqual(lrc.format_specifiers("80% of"), ())


class ReferenceHeuristicTests(unittest.TestCase):
    def test_commented_references_are_ignored(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            """
            // let a = NSLocalizedString("line.comment.key", comment: "")
            /*
               let b = NSLocalizedString("block.comment.key", comment: "")
               let c = LocalizedStringKey("block.comment.key2")
            */
            /// Doc comment mentioning NSLocalizedString("doc.comment.key", comment: "")
            let real = NSLocalizedString("real.key", comment: "")
            """
        )
        fixture.strings('"real.key" = "Real";\n', '"real.key" = "真实";\n')

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 1)

    def test_raw_display_text_is_ignored(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            """
            let a = NSLocalizedString("已关闭", comment: "legacy inline fallback")
            let b = Text("OK")
            let c = Text("Hello, world")
            """
        )
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 0)

    def test_dynamic_and_composed_keys_are_ignored(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            """
            let variable = "runtime.key"
            let a = NSLocalizedString(variable, comment: "")
            let b = NSLocalizedString("prefix.key" + suffix, comment: "")
            let c = LocalizedStringKey("Error \\(index)")
            let d = NSLocalizedString("interp.\\(name)", comment: "")
            let e = Text(verbatim: "some.key")
            """
        )
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 0)

    def test_text_bundle_and_bare_text_are_recognized(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            """
            let a = Text("onboarding.title", bundle: .main)
            let b = Text("onboarding.subtitle")
            """
        )
        fixture.strings(
            '"onboarding.title" = "Title";\n"onboarding.subtitle" = "Subtitle";\n',
            '"onboarding.title" = "标题";\n"onboarding.subtitle" = "副标题";\n',
        )

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 2)

    def test_string_localized_wrapper_is_recognized(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let value = String(localized: "string.localized.key")\n')
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        result = fixture.check()

        self.assertIn("string.localized.key", result.missing_from_both)

    def test_multiline_call_is_recognized(self) -> None:
        fixture = Fixture(self)
        fixture.swift(
            """
            let value = NSLocalizedString(
                "multiline.key",
                value: "fallback",
                comment: ""
            )
            """
        )
        fixture.strings('"multiline.key" = "Value";\n', '"multiline.key" = "值";\n')

        result = fixture.check()

        self.assertTrue(result.ok, lrc.format_report(result))
        self.assertEqual(result.references_scanned, 1)


class CliTests(unittest.TestCase):
    def _run(self, argv):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = lrc.main(argv)
        return code, stdout.getvalue()

    def test_cli_exit_zero_when_clean(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("present.key", comment: "")\n')
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        code, out = self._run(
            ["--root", str(fixture.root), "--en", str(fixture.en), "--zh", str(fixture.zh)]
        )

        self.assertEqual(code, 0, out)
        self.assertIn("references OK", out)

    def test_cli_exit_one_when_missing(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("ghost.key", comment: "")\n')
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')

        code, out = self._run(
            ["--root", str(fixture.root), "--en", str(fixture.en), "--zh", str(fixture.zh)]
        )

        self.assertEqual(code, 1, out)
        self.assertIn("ghost.key", out)

    def test_cli_exit_two_when_strings_missing(self) -> None:
        fixture = Fixture(self)
        fixture.swift('let x = NSLocalizedString("present.key", comment: "")\n')
        fixture.strings('"present.key" = "Present";\n', '"present.key" = "存在";\n')
        missing_en = fixture.root / "DayPage/Resources/en.lproj/DoesNotExist.strings"

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = lrc.main(
                ["--root", str(fixture.root), "--en", str(missing_en), "--zh", str(fixture.zh)]
            )

        self.assertEqual(code, 2)


class RepositoryIntegrationTests(unittest.TestCase):
    """Guards the real en/zh files and the shell entry point."""

    def setUp(self) -> None:
        if not (REPO_ROOT / "DayPage/Resources").is_dir():
            self.skipTest("repository layout not found")

    def test_repository_has_no_missing_references_or_placeholder_drift(self) -> None:
        en = REPO_ROOT / "DayPage/Resources/en.lproj/Localizable.strings"
        zh = REPO_ROOT / "DayPage/Resources/zh-Hans.lproj/Localizable.strings"

        result = lrc.check_repository(REPO_ROOT, en, zh)

        self.assertGreater(result.files_scanned, 0)
        self.assertGreater(result.references_scanned, 0)
        self.assertEqual(result.missing_from_both, {}, lrc.format_report(result))
        self.assertEqual(result.missing_in_en, {}, lrc.format_report(result))
        self.assertEqual(result.missing_in_zh, {}, lrc.format_report(result))
        self.assertEqual(result.placeholder_mismatches, {}, lrc.format_report(result))

    def test_repository_locale_files_are_in_parity(self) -> None:
        en = lrc.load_localization_file(
            REPO_ROOT / "DayPage/Resources/en.lproj/Localizable.strings"
        )
        zh = lrc.load_localization_file(
            REPO_ROOT / "DayPage/Resources/zh-Hans.lproj/Localizable.strings"
        )

        self.assertEqual(set(en), set(zh))

    def test_shell_parity_script_passes(self) -> None:
        script = REPO_ROOT / "scripts/check_localization_parity.sh"
        if not script.is_file():
            self.skipTest("checker script not found")

        completed = subprocess.run(
            ["bash", str(script)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        self.assertIn("Localization parity OK", completed.stdout)


if __name__ == "__main__":
    unittest.main()
