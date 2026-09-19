#!/usr/bin/env python3
"""Localization catalog coverage: every localizable call site must resolve
against a runtime-accurate key, and every required key must carry a REAL
zh-Hans translation.

Scans Conduit Swift sources for sites that look up String Catalog keys -

  1. AppLocalization.string("...") / String(localized: "...") - the
     skeleton must exist in Localizable.xcstrings with the SAME placeholder
     types the runtime will request: `\\(String(x))`-style interpolations
     request %@, integer-shaped expressions (Int casts, .count/.index/
     .total, count-like identifiers, digit arithmetic) request %lld.
     Placeholders are never normalized across type families, so a source
     Int interpolation against a %@ catalog key (or vice versa) fails.
  2. SwiftUI literal initializers (Text/Button/Label/TextField/SecureField/
     Toggle/NavigationLink/Picker/ProgressView/ContentUnavailableView/
     Section/Menu/GroupBox) - a leading string literal is a
     LocalizedStringKey and is checked the same way.
  3. LocalizedStringKey modifiers (.alert / .confirmationDialog /
     .navigationTitle / .accessibilityLabel / .accessibilityHint /
     .accessibilityValue).
  4. Raw user-facing String assignments/arguments that flow into
     Text/Label/alert rendering: `errorMessage = "..."`, `help: "..."`,
     `purposeText: "..."`.

For every required key (static call sites plus the explicit REGRESSION_KEYS
below - dynamic/ternary sites that cannot be extracted statically), the
checker then validates the zh-Hans localization:

  * the key must exist;
  * a zh-Hans localization must be present (a key with en-only content
    fails);
  * every stringUnit leaf - direct or inside plural/device variations -
    must have state == "translated" and a non-empty value;
  * the printf placeholders of each localized value must match the key's
    placeholder TYPE FAMILIES (object vs integer vs float) in count, order,
    and positional index validity - %@ and %lld are never interchangeable;
  * the value must not contain malformed literal Unicode escape sequences
    (e.g. the text "\\u4e00") - those are double-escaped authoring bugs,
    not legitimate backslash content.

Any violation is reported with file:line (call sites) or by key (catalog)
and fails the run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

REQUIRED_LANGUAGE = "zh-Hans"

# SwiftUI initializers whose first argument is a LocalizedStringKey when a
# string literal is passed directly. Variables/interpolations elsewhere are
# not statically checkable and are simply skipped.
SWIFTUI_LOCALIZED_INITIALIZERS = (
    "Text", "Button", "Label", "TextField", "SecureField",
    "Toggle", "NavigationLink", "Picker",
    "ProgressView", "ContentUnavailableView", "Section", "Menu", "GroupBox",
)

# Modifier-style APIs whose first argument is a LocalizedStringKey when a
# string literal is passed directly (there are String overloads too, but a
# raw literal in a String-position branch is exactly the bug class this
# checker exists for, so literal sites are always required to be keys).
SWIFTUI_LOCALIZED_MODIFIERS = (
    "alert", "confirmationDialog", "navigationTitle",
    "accessibilityLabel", "accessibilityHint", "accessibilityValue",
)

# Raw user-facing String assignments/arguments that later flow into
# Text/Label/alert rendering. Only literal right-hand sides are flagged.
RAW_STRING_ASSIGNMENT_RE = re.compile(
    r"\b(?:errorMessage|help|purposeText)\s*[:=]\s*\"")

# Keys that are intentionally not statically present in the catalog: pure
# variable passthroughs, separators, brand/protocol names, and placeholder
# tokens that must never be translated.
EXEMPT_KEYS = frozenset({
    "%@",            # verbatim variable passthrough
    "%lld",          # bare numeric counter chip
    "%@ %@",         # two-variable passthrough
    "%@: %@",        # speaker/field label passthrough ("You: text")
    "%@/%@",         # numeric done/total counters (string-wrapped)
    "%lld/%lld",     # numeric done/total counters (int interpolation)
    "%@.",           # numbered step prefix ("1.")
    "/", "•",        # separators
    "v%@",           # version prefix ("v1.2.3")
    "×%@",           # multiplier badge
    "×%lld",         # multiplier badge (int interpolation)
    "A",             # typography size sample glyph
    "Conduit", "GitHub", "Hermes", "HTTP", "HTTPS",  # brand/protocol names
    "https://hermes.example", "https://push.milim.dev",  # literal URLs
    "skill-name",    # example placeholder token
})

# Dynamic sites the extractor cannot see: variable-key lookups where the
# catalog key is computed at runtime. Conditional-branch literals are NOT
# here anymore — they are wrapped in AppLocalization.string at the source
# (Text(condition ? "A" : "B") binds the verbatim String overload, so raw
# ternary branches never localize) and are statically extracted now. When
# adding a new dynamic localizable site, add its key here.
REGRESSION_KEYS = (
    # ProfileConfigValueDisplay table (value → display label map)
    "Manual",
    "Smart",
    "YOLO mode",
    "Automatic",
    "Native images",
    "Text only",
    "Default",
    "Helpful",
    "Concise",
    "Technical",
    "Creative",
    "Teacher",
    "Kawaii",
    "Catgirl",
    "Pirate",
    "Shakespeare",
    "Surfer",
    "Noir",
    "Philosopher",
    "Hype",
    "Session",
    "Skills & extensions",
    # archive/restore ternary passed as a variable argument
    "archive",
    "restore",
    # Cron action verb display map (wire tokens stay raw in the URL path)
    "pause",
    "resume",
    "trigger",
)

CALL_RE = re.compile(
    r"\b(?:String\s*\(\s*localized\s*:|AppLocalization\s*\.\s*string\s*\()")
SWIFTUI_RE = re.compile(
    r"\b(" + "|".join(SWIFTUI_LOCALIZED_INITIALIZERS) + r")\s*\(")
MODIFIER_RE = re.compile(
    r"\.\s*(" + "|".join(SWIFTUI_LOCALIZED_MODIFIERS) + r")\s*\(")

# Malformed literal Unicode escapes in catalog VALUES, e.g. the text
# "\u91cd" arriving as six visible characters instead of 重. Only the
# backslash-u-hex shape is targeted; ordinary backslashes stay legal.
MALFORMED_ESCAPE_RE = re.compile("\\\\u[0-9a-fA-F]{4}")

_PLACEHOLDER_RE = re.compile(r"%(?:(\d+)\$)?([@df]|l{1,2}[diu]|lf|@|d|i|u|%)")

# Interpolation expressions that request an INTEGER runtime placeholder
# (%lld) rather than an object (%@). String-hint wins: the documented
# Conduit convention is to String()-wrap integers (avoids locale digit
# grouping), so an explicit String(...) means %@.
_STRING_HINT_RE = re.compile(
    r"\bString\s*\(|localizedDescription|\.description\b|\.name\b|\.id\b"
    r"|\.title\b|\.text\b|\.message\b|\.displayName\b|\.key\b")
_INT_HINT_RE = re.compile(
    r"\b(?:Int|UInt|Int8|Int16|Int32|Int64)\s*\("
    r"|\.\s*count\b|\.\s*index\b|\.\s*total\b"
    r"|\w*[Cc]ount\b|\w*[Ii]ndex\b|\w*[Tt]otal\b"
    r"|^\s*[\d\s+\-*/().]+\s*$")


def is_int_interpolation(expression: str) -> bool:
    """Focused heuristic: does this interpolation request %lld at runtime?

    Conservative by design - anything not matching the integer shapes below
    is treated as an object (%@) placeholder, matching the codebase
    convention of String()-wrapping non-plural interpolations.
    """
    if _STRING_HINT_RE.search(expression):
        return False
    return bool(_INT_HINT_RE.search(expression))


def typed_skeleton(literal: str, expressions) -> str:
    """Rebuild a literal with one placeholder per interpolation, typed by
    the runtime argument family (%@ object / %lld integer)."""
    parts = literal.split("%@")
    if len(parts) - 1 != len(expressions):
        return literal
    out = []
    for i, part in enumerate(parts):
        out.append(part)
        if i < len(expressions):
            out.append("%lld" if is_int_interpolation(expressions[i]) else "%@")
    return "".join(out)


def placeholder_specs(formatted: str) -> list:
    """Extract (position, type) pairs from a printf-style format string.

    %% escapes are ignored. Positional forms (%1$@) keep their index;
    non-positional forms get None. Type families: object / int / float.
    """
    specs = []
    i = 0
    while i < len(formatted):
        if formatted[i] != "%":
            i += 1
            continue
        match = _PLACEHOLDER_RE.match(formatted, i)
        if not match:
            i += 1
            continue
        i = match.end()
        if match.group(0) == "%%":
            continue
        position = int(match.group(1)) if match.group(1) else None
        body = match.group(2)
        if body == "@":
            kind = "object"
        elif body in ("f", "lf"):
            kind = "float"
        else:
            kind = "int"
        specs.append((position, kind))
    return specs


def parse_swift_string_literal(source: str, start: int):
    """Parse a Swift string literal starting at source[start] == '"'.

    Returns (skeleton, end_index, has_interpolation) or None when the
    literal is unterminated at EOF. Interpolations \\(...) collapse to a
    single placeholder; nested strings inside them are skipped.
    """
    parsed = parse_swift_literal_parts(source, start)
    if parsed is None:
        return None
    skeleton, end, exprs = parsed
    return skeleton, end, bool(exprs)


def parse_swift_literal_parts(source: str, start: int):
    """Like parse_swift_string_literal but also returns the raw text of each
    \\(...) interpolation expression, in order: (skeleton, end, exprs)."""
    assert source[start] == '"'
    out = []
    exprs = []
    i = start + 1
    while i < len(source):
        ch = source[i]
        if ch == "\\":
            if i + 1 >= len(source):
                return None
            nxt = source[i + 1]
            if nxt == "(":
                # Interpolation: skip to the matching close paren.
                depth = 1
                j = i + 2
                expr_start = j
                while j < len(source) and depth:
                    if source[j] == '"':
                        parsed = parse_swift_literal_parts(source, j)
                        if parsed is None:
                            return None
                        j = parsed[1] - 1
                    elif source[j] == "(":
                        depth += 1
                    elif source[j] == ")":
                        depth -= 1
                    j += 1
                if depth:
                    return None
                exprs.append(source[expr_start:j - 1])
                out.append("%@")
                i = j
            else:
                escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                           "\\": "\\", '"': '"', "'": "'"}
                out.append(escapes.get(nxt, nxt))
                i += 2
        elif ch == '"':
            return "".join(out), i + 1, exprs
        else:
            out.append(ch)
            i += 1
    return None


def strip_comment_lines(source: str) -> str:
    """Drop full-line // comments so doc diagrams can't look like call sites.

    Only WHOLE-LINE comments are removed - code with trailing comments is
    kept intact, and '//' inside string literals lives on code lines.
    """
    kept = []
    for line in source.split("\n"):
        if line.lstrip().startswith("//"):
            continue
        kept.append(line)
    return "\n".join(kept)


def extract_sites(source: str):
    """Yield (key_skeleton, offset) for every checkable call site.

    Skeletons are runtime-accurate: each interpolation contributes %@ or
    %lld according to the argument's type family.
    """
    source = strip_comment_lines(source)
    for regex in (CALL_RE, SWIFTUI_RE, MODIFIER_RE):
        for match in regex.finditer(source):
            i = match.end()
            while i < len(source) and source[i] in " \t\n":
                i += 1
            if i < len(source) and source[i] == '"':
                parsed = parse_swift_literal_parts(source, i)
                if parsed is not None and parsed[0]:
                    skeleton = typed_skeleton(parsed[0], parsed[2])
                    yield skeleton, match.start()
    for match in RAW_STRING_ASSIGNMENT_RE.finditer(source):
        i = match.end() - 1  # position of the opening quote
        if source[i] != '"':
            continue
        parsed = parse_swift_literal_parts(source, i)
        if parsed is not None and parsed[0]:
            skeleton = typed_skeleton(parsed[0], parsed[2])
            yield skeleton, match.start()


def catalog_has(catalog_keys: set, skeleton: str) -> bool:
    """Exact runtime-key match only. %@ and %lld are distinct type
    families and never normalized into each other."""
    return skeleton in catalog_keys


def string_unit_leaves(localization) -> list:
    """Flatten a localization dict into every stringUnit leaf."""
    if "stringUnit" in localization:
        return [localization["stringUnit"]]
    leaves = []
    for variation in localization.get("variations", {}).values():
        for unit in variation.values():
            if "stringUnit" in unit:
                leaves.append(unit["stringUnit"])
    return leaves


def placeholders_compatible(key_specs, value_specs) -> bool:
    """A translation's placeholders must substitute like the key's.

    Types are always compared as multisets. Positions matter only when BOTH
    sides are fully positional (a translation may introduce positional
    forms %1$@ to reorder non-positional key arguments, which printf
    handles). Positional indices in the translation must be valid for the
    key's argument count.
    """
    key_types = sorted(kind for _, kind in key_specs)
    value_types = sorted(kind for _, kind in value_specs)
    if key_types != value_types:
        return False
    key_positional = all(pos is not None for pos, _ in key_specs)
    value_positional = all(pos is not None for pos, _ in value_specs)
    if key_positional and value_positional:
        return sorted(key_specs) == sorted(value_specs)
    # A partially-positional translation must still use valid indices.
    for position, _ in value_specs:
        if position is not None and not 1 <= position <= len(key_specs):
            return False
    return True


def catalog_problems(catalog: dict) -> dict:
    """Return {key: [problems]} for every localization violation.

    zh-Hans must exist and be usable; EVERY language's units (en included)
    must carry placeholders compatible with the key, so a stale en value
    like "%lld" under a "%@" key cannot survive (it misformats at runtime).
    """
    problems = {}
    for key, entry in catalog.get("strings", {}).items():
        if key in EXEMPT_KEYS:
            continue
        localizations = entry.get("localizations", {})
        if REQUIRED_LANGUAGE not in localizations:
            problems.setdefault(key, []).append(
                f"missing {REQUIRED_LANGUAGE} localization")
        key_specs = placeholder_specs(key)
        for language, localization in localizations.items():
            for unit in string_unit_leaves(localization):
                value = unit.get("value")
                if unit.get("state") != "translated":
                    problems.setdefault(key, []).append(
                        f"{language} state is {unit.get('state')!r}, not 'translated'")
                elif not value or not value.strip():
                    problems.setdefault(key, []).append(
                        f"{language} value is empty")
                elif MALFORMED_ESCAPE_RE.search(value):
                    problems.setdefault(key, []).append(
                        f"{language} value contains malformed literal "
                        f"Unicode escape sequences (double-escaped authoring bug)")
                elif not placeholders_compatible(key_specs, placeholder_specs(value)):
                    problems.setdefault(key, []).append(
                        f"{language} placeholders {placeholder_specs(value)} "
                        f"do not match key placeholders {key_specs}")
    return problems


def required_key_problems(catalog: dict, required_keys) -> dict:
    """Problems for keys the extractor cannot see (REGRESSION_KEYS)."""
    problems = {}
    strings = catalog.get("strings", {})
    all_problems = catalog_problems(catalog)
    for key in required_keys:
        if key not in strings:
            problems.setdefault(key, []).append(
                "regression key absent from the catalog")
        elif key in all_problems:
            problems.setdefault(key, []).extend(all_problems[key])
    return problems


# Additional Conduit-owned catalogs that must satisfy the same zh-Hans
# requirements. Key existence is validated only against Localizable
# (call-site extraction); the others carry OS-owned Siri/InfoPlist content.
SECONDARY_CATALOGS = ("AppShortcuts.xcstrings", "InfoPlist.xcstrings")


def check(repo_root: str):
    """Full check. Returns (checked_site_count, missing_sites, catalog_problems)."""
    catalog_path = os.path.join(repo_root, "Conduit", "Localizable.xcstrings")
    with open(catalog_path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    catalog_keys = set(catalog["strings"])

    missing = {}
    checked = 0
    source_root = os.path.join(repo_root, "Conduit")
    for dirpath, _dirnames, filenames in os.walk(source_root):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            for skeleton, offset in extract_sites(source):
                checked += 1
                if skeleton in EXEMPT_KEYS:
                    continue
                if catalog_has(catalog_keys, skeleton):
                    continue
                line = source.count("\n", 0, offset) + 1
                rel = os.path.relpath(path, repo_root)
                missing.setdefault(skeleton, []).append(f"{rel}:{line}")

    key_problems = catalog_problems(catalog)
    for name in SECONDARY_CATALOGS:
        secondary_path = os.path.join(repo_root, "Conduit", name)
        if not os.path.exists(secondary_path):
            continue
        with open(secondary_path, encoding="utf-8") as handle:
            secondary = json.load(handle)
        for key, problems in catalog_problems(secondary).items():
            key_problems[f"{name}: {key}"] = problems
    return checked, missing, key_problems


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify every localizable call site resolves in "
                    "Conduit/Localizable.xcstrings with a real zh-Hans "
                    "translation.")
    parser.add_argument("--repo-root", default=".",
                        help="Repository root (default: current directory).")
    args = parser.parse_args()

    checked, missing, key_problems = check(args.repo_root)
    regression = required_key_problems(
        json.load(open(os.path.join(args.repo_root, "Conduit",
                                    "Localizable.xcstrings"),
                       encoding="utf-8")),
        REGRESSION_KEYS)

    failed = False
    if missing:
        failed = True
        print(f"FAIL: {len(missing)} localizable key(s) missing from the "
              f"String Catalog ({checked} call sites checked):")
        for skeleton in sorted(missing):
            for location in missing[skeleton]:
                print(f"  {location}")
            print(f"    key: {skeleton!r}")
    else:
        print(f"OK: {checked} localizable call sites all resolve in the catalog.")

    all_key_problems = dict(key_problems)
    for key, probs in regression.items():
        all_key_problems.setdefault(key, []).extend(probs)
    if all_key_problems:
        failed = True
        print(f"FAIL: {len(all_key_problems)} catalog key(s) lack a usable "
              f"{REQUIRED_LANGUAGE} translation:")
        for key in sorted(all_key_problems):
            print(f"    {key!r}")
            for problem in all_key_problems[key]:
                print(f"        {problem}")
    if not failed:
        print(f"OK: every catalog key has a real {REQUIRED_LANGUAGE} "
              f"translation with type-matched placeholders.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
