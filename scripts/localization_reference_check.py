#!/usr/bin/env python3
"""Static localization-reference checker for the DayPage iOS app.

`scripts/check_localization_parity.sh` already guarantees that en.lproj and
zh-Hans.lproj declare exactly the same keys. That check cannot catch the most
common localization defect: a Swift call site that references a *static literal
key which exists in NEITHER locale*. In that case the app falls back to the
inline `value:`/fallback string (often Chinese-only) or renders the raw key.

This helper scans Swift sources for statically-resolvable localization references
and reports any leaf key that is absent from BOTH locale files. It also compares
format placeholders between the two locales for keys that are present in both.

Supported reference forms
-------------------------
- ``NSLocalizedString("some.key", ...)``
- ``NSLocalizedString(\\n    "some.key", ...)`` (multi-line call)
- ``LocalizedStringKey("some.key")``
- ``String(localized: "some.key")``
- ``Text("some.key")`` (SwiftUI localizes bare string literals)
- ``Text("some.key", bundle: ...)``

Heuristics and documented limitations
-------------------------------------
To avoid drowning in raw display text, only literals that look like localization
identifiers are considered: lowercase dotted tokens matching
``^[a-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$``. Consequences:

- Raw literal copy such as ``Text("OK")`` or ``NSLocalizedString("已关闭")`` is
  deliberately ignored. Those exist in the tree today and behave as inline
  fallbacks; migrating them to dotted keys is a separate production change.
- A key referenced dynamically (``NSLocalizedString(someVariable)``), built by
  concatenation/interpolation (``"a." + suffix`` or ``"\\(name).label"``), or with
  a runtime-interpolated fallback value is NOT statically resolvable and is
  therefore skipped. This checker cannot prove the absence of such keys.
- Comments (line and block) are stripped before scanning, so commented-out calls
  are ignored.

Placeholder comparison
----------------------
For keys present in both locales the argument-index/type signatures of C-style
format specifiers are compared (``%@``, ``%d``, ``%1$lld``, ...). Unnumbered
arguments retain their order; numbered arguments can reorder safely. ``%%`` is a literal
percent, not a placeholder. Exotic specifiers using flag characters (e.g.
``% o``) are not recognized; that is intentional so prose such as ``80% of`` in
non-format strings is not misread as a placeholder.

Exit codes (CLI)
----------------
0 — every static reference resolves and placeholders agree
1 — missing reference(s) or placeholder mismatch reported
2 — a strings file is missing/unreadable

Usage:
    python3 scripts/localization_reference_check.py [--root DIR] [--en FILE] [--zh FILE]
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

# Only dotted, lowercase identifiers are treated as auditable localization keys.
KEY_PATTERN = re.compile(r"^[a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$")

# Conservative printf-style specifier matcher: optional positional index,
# optional length modifier, then a common conversion character. Does not accept
# flag characters so literal text like "80% of" is not mistaken for "%o".
FORMAT_SPECIFIER_PATTERN = re.compile(
    r"%(?:\d+\$)?(?:hh|h|ll|l|z|t|j|q|L)?[@dioufFeEgGxXscpaA]"
)

_NEWLINE = "\n"


class LocalizationFileError(Exception):
    """Raised when a required .strings file is missing or unreadable."""


@dataclass
class CheckResult:
    """Outcome of one repository scan."""

    files_scanned: int = 0
    references_scanned: int = 0
    # key -> ["relative/path.swift:line", ...]
    missing_from_both: Dict[str, List[str]] = field(default_factory=dict)
    missing_in_en: Dict[str, List[str]] = field(default_factory=dict)
    missing_in_zh: Dict[str, List[str]] = field(default_factory=dict)
    # key -> (english_placeholders, chinese_placeholders)
    placeholder_mismatches: Dict[str, Tuple[Tuple[str, ...], Tuple[str, ...]]] = field(
        default_factory=dict
    )

    @property
    def ok(self) -> bool:
        return not (
            self.missing_from_both
            or self.missing_in_en
            or self.missing_in_zh
            or self.placeholder_mismatches
        )


# ---------------------------------------------------------------------------
# Source scanning
# ---------------------------------------------------------------------------


def strip_comments(source: str) -> str:
    """Blank out ``//`` and ``/* */`` comments while preserving string literals.

    Every removed character is replaced with a space (newlines kept) so that
    offsets and line numbers in the result still map to the original source.
    """

    out = list(source)
    i = 0
    n = len(source)
    in_string = False
    while i < n:
        char = source[i]
        if in_string:
            if char == "\\":
                i += 2
                continue
            if char == '"':
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            i += 1
            continue
        if char == "/" and i + 1 < n and source[i + 1] == "/":
            end = source.find(_NEWLINE, i)
            if end == -1:
                end = n
            for k in range(i, end):
                out[k] = " "
            i = end
            continue
        if char == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            if end == -1:
                end = n
            else:
                end += 2
            for k in range(i, end):
                if out[k] != _NEWLINE:
                    out[k] = " "
            i = end
            continue
        i += 1
    return "".join(out)


def _skip_whitespace(source: str, index: int) -> int:
    while index < len(source) and source[index].isspace():
        index += 1
    return index


def _parse_string_literal(source: str, index: int):
    """Parse a double-quoted literal starting at ``index``.

    Returns ``(value, end_index, is_dynamic)`` or ``None`` when the source at
    ``index`` is not a string literal. ``is_dynamic`` is true when the literal
    contains string interpolation, which makes the key unresolvable statically.
    """

    if index >= len(source) or source[index] != '"':
        return None
    i = index + 1
    buffer: List[str] = []
    dynamic = False
    while i < len(source):
        char = source[i]
        if char == "\\":
            nxt = source[i + 1] if i + 1 < len(source) else ""
            if nxt == "(":
                dynamic = True
                buffer.append("\\(")
            elif nxt == "n":
                buffer.append("\n")
            elif nxt == "t":
                buffer.append("\t")
            elif nxt == '"':
                buffer.append('"')
            elif nxt == "\\":
                buffer.append("\\")
            else:
                buffer.append(nxt)
            i += 2
            continue
        if char == '"':
            return "".join(buffer), i + 1, dynamic
        buffer.append(char)
        i += 1
    return None


def _literal_key_after(source: str, index: int) -> Optional[str]:
    """Return the static key literal at ``index`` or ``None`` if not usable."""

    start = _skip_whitespace(source, index)
    parsed = _parse_string_literal(source, start)
    if parsed is None:
        return None
    value, end, dynamic = parsed
    if dynamic or not value:
        return None
    # String concatenation / interpolation built at runtime is not static.
    next_index = _skip_whitespace(source, end)
    if source[next_index : next_index + 1] == "+":
        return None
    if not KEY_PATTERN.match(value):
        return None
    return value


_REFERENCE_CALL_PATTERN = re.compile(
    r"\bNSLocalizedString\s*\("
    r"|\bLocalizedStringKey\s*\("
    r"|String\s*\(\s*localized\s*:"
)

_TEXT_CALL_PATTERN = re.compile(r"\bText\s*\(")


def iter_reference_keys(source: str) -> Iterable[str]:
    """Yield static localization keys referenced in ``source``."""

    for match in _REFERENCE_CALL_PATTERN.finditer(source):
        key = _literal_key_after(source, match.end())
        if key is not None:
            yield key

    for match in _TEXT_CALL_PATTERN.finditer(source):
        start = _skip_whitespace(source, match.end())
        parsed = _parse_string_literal(source, start)
        if parsed is None:
            continue
        value, end, dynamic = parsed
        if dynamic or not value:
            continue
        next_index = _skip_whitespace(source, end)
        if source[next_index : next_index + 1] == "+":
            continue
        if not KEY_PATTERN.match(value):
            continue
        yield value


def collect_references(
    swift_files: Iterable[Path], root: Path
) -> Tuple[Dict[str, List[str]], int]:
    """Map every static key to its call sites and return the reference count."""

    references: Dict[str, List[str]] = {}
    total = 0
    for path in swift_files:
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        try:
            relative = path.relative_to(root)
        except ValueError:
            relative = path
        for key in iter_reference_keys(strip_comments(raw)):
            references.setdefault(key, []).append(str(relative))
            total += 1
    return references, total


def discover_swift_files(root: Path) -> List[Path]:
    return sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts)


# ---------------------------------------------------------------------------
# Strings files
# ---------------------------------------------------------------------------

_STRINGS_LINE_PATTERN = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"(.*)"\s*;\s*$')


def load_localization_file(path: Path) -> Dict[str, str]:
    """Parse a ``Localizable.strings`` file into an ordered key -> value dict."""

    if not path.is_file():
        raise LocalizationFileError(f"strings file not found: {path}")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:  # pragma: no cover - defensive
        raise LocalizationFileError(f"strings file unreadable: {path}: {exc}") from exc

    entries: Dict[str, str] = {}
    for line in text.splitlines():
        match = _STRINGS_LINE_PATTERN.match(line)
        if match:
            entries[match.group(1)] = match.group(2)
    return entries


def format_specifiers(value: str) -> Tuple[str, ...]:
    """Return argument-index/type pairs, preserving unnumbered argument order.

    Sorting bare specifiers hides unsafe reorderings: `%@ then %d` and
    `%d then %@` consume the same argv positions as different types. Explicit
    positions permit safe translated reordering and repeated arguments.
    """

    # An escaped percent is literal text, never a placeholder.
    without_escapes = value.replace("%%", "")
    signature = set()
    next_argument = 1
    for specifier in FORMAT_SPECIFIER_PATTERN.findall(without_escapes):
        positional = re.fullmatch(r"%(\d+)\$(.+)", specifier)
        if positional:
            argument = int(positional.group(1))
            value_type = positional.group(2)
        else:
            argument = next_argument
            next_argument += 1
            value_type = specifier[1:]
        signature.add(f"%{argument}${value_type}")
    return tuple(sorted(signature))


# ---------------------------------------------------------------------------
# Check
# ---------------------------------------------------------------------------


def check_repository(
    root: Path, en_path: Path, zh_path: Path
) -> CheckResult:
    """Run the full missing-reference + placeholder check."""

    en_keys = load_localization_file(en_path)
    zh_keys = load_localization_file(zh_path)

    result = CheckResult()
    swift_root = root / "DayPage"
    swift_files = discover_swift_files(swift_root if swift_root.is_dir() else root)
    result.files_scanned = len(swift_files)
    references, total = collect_references(swift_files, root)
    result.references_scanned = total

    for key, locations in sorted(references.items()):
        if key not in en_keys and key not in zh_keys:
            result.missing_from_both[key] = locations
        elif key not in en_keys:
            result.missing_in_en[key] = locations
        elif key not in zh_keys:
            result.missing_in_zh[key] = locations

    for key in sorted(set(en_keys) & set(zh_keys)):
        en_specs = format_specifiers(en_keys[key])
        zh_specs = format_specifiers(zh_keys[key])
        if en_specs != zh_specs:
            result.placeholder_mismatches[key] = (en_specs, zh_specs)

    return result


def format_report(result: CheckResult) -> str:
    lines: List[str] = []
    if result.missing_from_both:
        lines.append(
            "::error::Localization keys referenced in Swift but absent from BOTH "
            "en.lproj and zh-Hans.lproj (the UI will show a raw key or an inline "
            "fallback instead of a translated string):"
        )
        for key, locations in result.missing_from_both.items():
            lines.append(f"  - {key} ({', '.join(locations)})")
    if result.missing_in_en:
        lines.append("::error::Keys referenced in Swift and present in zh-Hans but MISSING in en:")
        for key, locations in result.missing_in_en.items():
            lines.append(f"  - {key} ({', '.join(locations)})")
    if result.missing_in_zh:
        lines.append("::error::Keys referenced in Swift and present in en but MISSING in zh-Hans:")
        for key, locations in result.missing_in_zh.items():
            lines.append(f"  - {key} ({', '.join(locations)})")
    if result.placeholder_mismatches:
        lines.append("::error::Format placeholders differ between en and zh-Hans:")
        for key, (en_specs, zh_specs) in result.placeholder_mismatches.items():
            lines.append(f"  - {key}: en={list(en_specs)} zh={list(zh_specs)}")
    if not lines:
        lines.append(
            "✅ Localization references OK — "
            f"{result.references_scanned} static references across "
            f"{result.files_scanned} Swift files all resolve."
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _default_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=_default_root(),
        help="repository root that contains DayPage/ (default: repository root)",
    )
    parser.add_argument(
        "--en",
        type=Path,
        default=None,
        help="English Localizable.strings (default: <root>/DayPage/Resources/en.lproj/Localizable.strings)",
    )
    parser.add_argument(
        "--zh",
        type=Path,
        default=None,
        help="Simplified Chinese Localizable.strings (default: <root>/DayPage/Resources/zh-Hans.lproj/Localizable.strings)",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    en_path = (args.en or root / "DayPage/Resources/en.lproj/Localizable.strings").resolve()
    zh_path = (args.zh or root / "DayPage/Resources/zh-Hans.lproj/Localizable.strings").resolve()

    try:
        result = check_repository(root, en_path, zh_path)
    except LocalizationFileError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 2

    print(format_report(result))
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
