#!/usr/bin/env python3
#
#  check-localization.py
#  FinvestLens
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Gate the string catalogs against what the compiler actually emits.

Four checks, each of which has caught a real shipping defect:

  missing   a key the compiler emits with no catalog entry — the string ships
            in English in every language. 106 accumulated unnoticed, because
            nothing ever ran the extractor.
  orphan    a catalog entry no source emits — dead weight a translator still
            reads past, and a trap when two near-identical paragraphs differ
            only by a menu separator.
  coverage  a translatable entry missing a language.
  format    a translation whose `%` specifiers do not match its key's. A French
            value carrying one more `%@` than the call site passes is a crash
            inside CFStringAppendFormat, not a cosmetic defect.

**Both platforms are needed**, and the extraction has to go through
`xcodebuild`. Two traps found the hard way:

  - A plain Xcode build writes `.stringsdata` for the app target and the
    extensions but *not* for SPM package targets, where most of the strings
    live. Passing `-emit-localized-strings` through `OTHER_SWIFT_FLAGS`
    extracts every target, packages included.
  - macOS alone is not enough. `"Browse accounts"` is an accessibility label
    inside an `#else` branch of `#if os(macOS)`; a macOS-only extraction never
    compiles it, so it was missing from the catalog and shipping untranslated
    while every audit reported full coverage.

Each `.stringsdata` records the source file it came from, so entries are
assigned to a catalog by that path rather than by guessing target names. This
matters because an app extension has its own bundle: its strings resolve
against its own catalog, never the app's.

Usage:
    scripts/check-localization.py --build             # build both platforms, then check
    scripts/check-localization.py --strings-dir A --strings-dir B
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# Catalog ← the source trees whose strings it is responsible for. Order
# matters: the first matching prefix wins, so the extensions are listed before
# the app's catch-all.
SCOPES: list[tuple[str, tuple[str, ...]]] = [
    ("FinvestLensQuickLook/Localizable.xcstrings", ("FinvestLensQuickLook/",)),
    ("FinvestLensWidgets/Localizable.xcstrings", ("FinvestLensWidgets/",)),
    # Package code resolves against `Bundle.main`, which inside the app is the
    # app — so the app's catalog owns every package string too.
    ("finvestlens/Localizable.xcstrings", ("finvestlens/", "Packages/")),
]

# The directories a repo-relative source path can start with — the keys of
# SCOPES, flattened. Used to recover that relative path from the absolute one a
# `.stringsdata` records; see `repo_relative`.
REPO_ROOTS = frozenset(prefix.rstrip("/") for _, prefixes in SCOPES for prefix in prefixes)

# Both platforms, because each compiles code the other does not.
DESTINATIONS = ["platform=macOS", "generic/platform=iOS Simulator"]

LANGUAGES = {"de", "es", "fr", "it", "ja", "pt-BR", "zh-Hans"}

# A printf conversion, minus `%%`. Deliberately close to what
# CFStringAppendFormat consumes, because the count is what matters.
#
# No space in the flag class, though printf has one. A translation is prose,
# and prose writes a percent sign followed by a word: "Rendite in % pro Jahr",
# "% des frais". With ` ` a flag those read as `% p` and `% d` — one bogus
# specifier each, and a correct translation blocked at the gate. The space flag
# is unused in a string catalog; the false positive is not hypothetical, since
# the catalogs already hold "Returns % (nominal, net of fees)".
SPECIFIER = re.compile(
    r"%(?:\d+\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|q|L|z|t|j)?[@dioouxXeEfgGaAcsp]"
)

# App Intents phrases go to their own metadata table, not the catalogs.
SKIP_FILES = {"ExtractedAppShortcutsMetadata.stringsdata"}


def extract(into: pathlib.Path) -> None:
    """Build both platforms with the extractor on, writing `.stringsdata`.

    The per-destination directory name must carry **no space**. `xcodebuild`
    word-splits `OTHER_SWIFT_FLAGS` before handing it to the compiler, so a
    path built from `generic/platform=iOS Simulator` arrived as
    `-emit-localized-strings-path …/generic_platform-iOS` plus a stray
    `Simulator`, which the frontend reported as `error: Unexpected input file:
    …/Simulator`. `--build` — the mode `/preflight` tells you to run — could
    never get past the iOS destination.
    """
    for destination in DESTINATIONS:
        # No spaces in the directory name. `OTHER_SWIFT_FLAGS` is one string
        # that Xcode splits on whitespace, so a path built from
        # "generic/platform=iOS Simulator" broke in two: the compiler got
        # `-emit-localized-strings-path …/generic_platform-iOS` and then tried
        # to compile a source file called `Simulator`. `--build` — the command
        # the preflight skill runs — could never get past the iOS destination.
        out = into / destination.replace("/", "_").replace("=", "-").replace(" ", "-")
        out.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["xcodebuild", "build", "-scheme", "finvestlens",
             "-destination", destination, "CODE_SIGNING_ALLOWED=NO",
             "OTHER_SWIFT_FLAGS=$(inherited) -emit-localized-strings "
             f"-emit-localized-strings-path {out}"],
            cwd=REPO, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            sys.exit(f"build failed for {destination}:\n{result.stdout[-3000:]}")


def derived_data_intermediates() -> pathlib.Path | None:
    """Where Xcode puts the app's and extensions' own `.stringsdata`.

    Targets that own a String Catalog are extracted automatically, into
    DerivedData — the `OTHER_SWIFT_FLAGS` path above only adds the package
    targets, which own no catalog and so are never extracted on their own.
    Both sources are therefore needed.
    """
    out = subprocess.run(
        ["xcodebuild", "-scheme", "finvestlens", "-destination", "platform=macOS",
         "-showBuildSettings"],
        cwd=REPO, capture_output=True, text=True, check=False).stdout
    for line in out.splitlines():
        if " BUILD_DIR =" in line:
            path = pathlib.Path(line.split("=", 1)[1].strip()).parent.parent
            intermediates = path / "Build" / "Intermediates.noindex"
            return intermediates if intermediates.is_dir() else None
    return None


def repo_relative(source: str) -> str | None:
    """The repo-relative path of a compiled source, or None if it is outside.

    A `.stringsdata` records the **absolute** path of the file it came from, on
    the machine that compiled it. In CI that machine is the `macos-26` runner
    (`/Users/runner/work/…`) and this script runs on `ubuntu-latest`
    (`/home/runner/work/…`), so resolving against this checkout raised
    `ValueError` for *every* source: each key was dropped, each catalog then
    reported "no strings extracted", and the gate failed on every run — the
    comparison could never have passed, let alone caught anything.

    The last repo root in the path is the same on any machine, so match on that
    instead. Scanning from the **end** matters: the checkout itself is called
    `finvestlens`, and scanning forward would find the wrapping directory
    rather than the app target inside it.
    """
    parts = pathlib.PurePosixPath(source).parts
    for index in range(len(parts) - 1, -1, -1):
        if parts[index] in REPO_ROOTS:
            return "/".join(parts[index:])
    return None


def scope_for(source: str) -> str | None:
    """Which catalog owns a source file, or None if it ships no strings."""
    rel = repo_relative(source)
    if rel is None:
        return None
    # `.build/checkouts/…` is somebody else's package vendored under ours; its
    # strings are not in — and must not be demanded of — our catalogs.
    if "/Tests/" in f"/{rel}" or "/.build/" in f"/{rel}" \
            or rel.startswith("Packages/CLI/") \
            or rel.startswith("Packages/Lab/"):
        return None
    for catalog, prefixes in SCOPES:
        if any(rel.startswith(prefix) for prefix in prefixes):
            return catalog
    return None


def emitted_by_scope(roots: list[pathlib.Path]) -> dict[str, set[str]]:
    found: dict[str, set[str]] = {catalog: set() for catalog, _ in SCOPES}
    for root in roots:
        for path in root.rglob("*.stringsdata"):
            if path.name in SKIP_FILES:
                continue
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            catalog = scope_for(data.get("source", ""))
            if catalog is None:
                continue
            for entries in (data.get("tables") or {}).values():
                for entry in entries:
                    if key := entry.get("key"):
                        found[catalog].add(key)
    return found


def values_of(localization: dict) -> list[str]:
    """Every value whose specifiers must match the key's.

    Three shapes, and only the last is subtle:

      plain              the `stringUnit` value
      plural variations  each form — every one is a whole sentence
      substitutions      each form of each substitution. The outer template is
                         *not* checked: it is `%#@count@`, which stands in for
                         the whole sentence and legitimately carries a
                         different number of specifiers than the key.
    """
    if substitutions := localization.get("substitutions"):
        out: list[str] = []
        for substitution in substitutions.values():
            plural = (substitution.get("variations") or {}).get("plural") or {}
            for form in plural.values():
                if (value := (form.get("stringUnit") or {}).get("value")) is not None:
                    # `%arg` is the substituted argument itself.
                    out.append(value.replace("%arg", "%lld"))
        return out

    out = []
    if unit := localization.get("stringUnit"):
        if (value := unit.get("value")) is not None:
            out.append(value)
    plural = (localization.get("variations") or {}).get("plural") or {}
    for form in plural.values():
        if (value := (form.get("stringUnit") or {}).get("value")) is not None:
            out.append(value)
    return out


def specifier_count(text: str) -> int:
    """Format specifiers, counting a `%#@substitution@` token as one.

    `%%` is dropped first: it is an escaped literal percent, not a conversion,
    and the regex above has no way to tell the second `%` from the start of one
    ("100%% done" counted a `% d`).
    """
    text = re.sub(r"%#@[^@]+@", "%@", text)
    return len(SPECIFIER.findall(text.replace("%%", "")))


def check(catalog_rel: str, emitted: set[str]) -> list[str]:
    path = REPO / catalog_rel
    problems: list[str] = []
    if not path.exists():
        if emitted:
            problems.append(
                f"{catalog_rel}: no such catalog, but its sources emit "
                f"{len(emitted)} keys — they ship untranslated")
        return problems
    if not emitted:
        return [f"{catalog_rel}: no strings extracted for its sources — "
                "run with --build, or the comparison is meaningless"]

    entries = json.loads(path.read_text())["strings"]

    for key in sorted(emitted - set(entries)):
        problems.append(f"{catalog_rel}: missing key {key!r}")
    for key in sorted(set(entries) - emitted):
        problems.append(f"{catalog_rel}: orphan key {key!r} — emitted by nothing")

    for key, entry in sorted(entries.items()):
        localizations = entry.get("localizations") or {}
        if entry.get("shouldTranslate") is not False:
            if missing := LANGUAGES - set(localizations):
                problems.append(
                    f"{catalog_rel}: {key!r} missing {', '.join(sorted(missing))}")
        expected = specifier_count(key)
        for language, localization in sorted(localizations.items()):
            for value in values_of(localization):
                if (got := specifier_count(value)) != expected:
                    problems.append(
                        f"{catalog_rel}: {key!r} [{language}] has {got} format "
                        f"specifiers, key has {expected} — {value!r}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true",
                        help="build both platforms with the extractor on, then check")
    parser.add_argument("--strings-dir", action="append", default=[],
                        help="directory of .stringsdata to scan (repeatable)")
    parser.add_argument("--derived-data", help="DerivedData root (default: ask xcodebuild)")
    parser.add_argument("--no-discover", action="store_true",
                        help="don't look for DerivedData; --strings-dir already has everything")
    args = parser.parse_args()

    roots = [pathlib.Path(d).expanduser().resolve() for d in args.strings_dir]
    temp: str | None = None
    if args.build:
        temp = tempfile.mkdtemp(prefix="finvestlens-l10n-")
        extract(pathlib.Path(temp))
        roots.append(pathlib.Path(temp))
    if args.derived_data:
        intermediates = pathlib.Path(args.derived_data).expanduser().resolve() \
            / "Build" / "Intermediates.noindex"
        if intermediates.is_dir():
            roots.append(intermediates)
    elif not args.no_discover:
        if (intermediates := derived_data_intermediates()) is not None:
            roots.append(intermediates)

    try:
        if not roots:
            sys.exit("nothing to scan — pass --build or --strings-dir")
        emitted = emitted_by_scope(roots)
        problems: list[str] = []
        for catalog_rel, _ in SCOPES:
            problems += check(catalog_rel, emitted[catalog_rel])
    finally:
        if temp:
            shutil.rmtree(temp, ignore_errors=True)

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} localization problem(s).")
        return 1
    print("Localization catalogs match the compiler's output.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
