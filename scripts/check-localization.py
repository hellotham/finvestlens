#!/usr/bin/env python3
#
#  check-localization.py
#  FinvestLens
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Gate the string catalogs against what the compiler actually emits.

Five checks, each of which has caught a real shipping defect:

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
  unseen    English a reader meets that the compiler cannot see: a phrase held
            as a `String` emits no key, so the four checks above can neither
            miss it nor call it an orphan. Several hundred shipped that way —
            every undo action's name, the toasts, most error messages — while
            this gate reported full coverage. Run with `--literals`, which
            `--build` turns on; it reads the source as well as the extraction,
            and needs both platforms' extraction to mean anything.

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
    scripts/check-localization.py --self-test         # path scoping and the source scanner
    scripts/check-localization.py --strings-dir A --no-discover --only-literals

`--build` on a Mac and the `localization` job in CI are not the same run: the
paths a `.stringsdata` records differ between them, and the scoping is by
path. `--self-test` holds the shapes both produce. To see what CI saw, fetch
its artifacts and check those:

    gh run download <run-id> -p 'stringsdata-*' -D /tmp/strings
    scripts/check-localization.py --strings-dir /tmp/strings --no-discover
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
             "-destination", destination,
             # mlx-swift carries a build-tool plug-in; a headless build has
             # nobody to press "Trust & Enable", and fails validating it.
             "-skipPackagePluginValidation", "CODE_SIGNING_ALLOWED=NO",
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
    the machine that compiled it. In CI that machine is the macOS runner
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
    # A package the project links from elsewhere — MLX, the tokenizer library
    # — is somebody else's source, checked out by Xcode under DerivedData. Its
    # strings are its own: not in our catalogs, and not to be demanded of them.
    #
    # This has to be said before the path is made repo-relative, and it is
    # here because of a run that passed on a Mac and failed in CI on the same
    # tree (12 Oct 2026). Locally DerivedData is under ~/Library, so a
    # checkout's path names no repo root and was dropped by accident. CI
    # builds with `-derivedDataPath "$PWD/DerivedData"`, the checkout itself
    # is a directory called `finvestlens`, and
    # `…/finvestlens/DerivedData/SourcePackages/checkouts/swift-transformers/…`
    # read as the app target's own source: twenty of that package's error
    # messages were reported as strings the app ships untranslated.
    if "/SourcePackages/" in source:
        return None
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
            plural_forms = {
                (form.get("stringUnit") or {}).get("value")
                for form in ((localization.get("variations") or {}).get("plural") or {}).values()
            }
            for value in values_of(localization):
                got = specifier_count(value)
                if got == expected:
                    continue
                if value in plural_forms and fewer_is_safe(value, expected):
                    continue
                problems.append(
                    f"{catalog_rel}: {key!r} [{language}] has {got} format "
                    f"specifiers, key has {expected} — {value!r}")
    return problems


def fewer_is_safe(form: str, expected: int) -> bool:
    """Whether a plural form may say fewer things than its key.

    "Every day" is the one-form of "Every %lld days": the count is the plural
    rule's to consume, and saying it again reads "Every 1 day". A form can
    leave arguments out safely only if it consumes none (nothing is read in
    the wrong place) or names every one it does read by position (`%2$@` is
    the second argument wherever it stands). Sequential specifiers that skip
    the count would read the count as the next argument — a crash for `%@`.
    """
    found = SPECIFIER.findall(re.sub(r"%#@[^@]+@", "%@", form).replace("%%", ""))
    if not found:
        return True
    positions = [re.match(r"%(\d+)\$", spec) for spec in found]
    return all(positions) and max(int(m.group(1)) for m in positions) <= expected


# --------------------------------------------------------------------------
# The fifth check: English a reader meets that the compiler cannot see
# --------------------------------------------------------------------------
#
# The four checks above compare keys the compiler emitted with the catalogs.
# A `String` emits no key, so a phrase built as one — an undo action's name,
# a toast, an error, a label handed to a helper that takes `String` — is
# neither missing nor orphaned. It ships in English in every language, and on
# 12 Oct 2026 there were several hundred of them in a codebase whose gate
# reported full coverage.
#
# So the source is read too. Every string literal that reads as English must
# be accounted for: by a key the compiler emitted *for that file* (it is
# localized); by what the code just before it says it is (a defaults key, a
# log line, SQL, a date pattern — `NOT_FOR_THE_READER`); or by a line in
# `localization-exempt.tsv` saying why no reader sees it.
#
# "Reads as English" is a judgement, and this one errs towards asking. It
# does not see a single lower-case word ("accounts"), which is far more often
# a key than a label, nor text built without a literal (`kind.rawValue`
# drawn by a `Text`): those are for review, not for this.

LITERAL_ROOTS = ("Packages", "finvestlens", "FinvestLensQuickLook", "FinvestLensWidgets")
EXEMPTIONS = REPO / "scripts" / "localization-exempt.tsv"

# A conversion in an emitted key, or an App Intents parameter (`${account}`),
# each standing where the source has an interpolation.
KEY_PLACEHOLDER = re.compile(SPECIFIER.pattern + r"|\$\{\w+\}")


def swift_literals(source: str) -> list[tuple[int, str, str]]:
    r"""Every string literal in a Swift file: (line, text, code before it).

    Comments are skipped; `\(…)` interpolations become `§`, and a literal
    *inside* an interpolation is reported too (`?? "the audit log"` inside a
    phrase was one of the ones that shipped in English). Multi-line literals
    lose their indentation as the compiler strips it; raw strings
    (`#"…"#`) keep their backslashes. `before` is the code on the literal's
    first line ahead of it — what `NOT_FOR_THE_READER` reads.
    """
    found: list[tuple[int, str, str]] = []
    n = len(source)
    state = {"line": 1}

    def starts_string(j: int) -> bool:
        k = j
        while k < n and source[k] == "#":
            k += 1
        return k < n and source[k] == '"'

    def scan(i: int) -> tuple[str, int]:
        """`i` at a literal's first `#` or quote; returns (text, index after it)."""
        hashes = 0
        while source[i] == "#":
            hashes += 1
            i += 1
        multi = source.startswith('"""', i)
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        text: list[str] = []
        while i < n:
            if source.startswith(close, i):
                return "".join(text), i + len(close)
            if source.startswith(escape, i):
                j = i + len(escape)
                if j < n and source[j] == "(":
                    depth, j = 1, j + 1
                    while j < n and depth:
                        c = source[j]
                        if c == '"' or (c == "#" and starts_string(j)):
                            line_before = state["line"]
                            inner, j = scan(j)
                            found.append((line_before, inner, "\\("))
                            continue
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                        elif c == "\n":
                            state["line"] += 1
                        j += 1
                    text.append("§")
                    i = j
                    continue
                if j < n and source[j] == "\n" and multi:      # line continuation
                    state["line"] += 1
                    i = j + 1
                    while i < n and source[i] in " \t":
                        i += 1
                    continue
                if j < n:
                    c = source[j]
                    if c == "u" and source.startswith("{", j + 1):
                        end = source.find("}", j)
                        try:
                            text.append(chr(int(source[j + 2:end], 16)))
                        except ValueError:
                            pass
                        i = end + 1
                    else:
                        text.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(c, c))
                        i = j + 1
                    continue
            c = source[i]
            if c == "\n":
                if not multi:          # unterminated; give up on it
                    return "".join(text), i
                state["line"] += 1
            text.append(c)
            i += 1
        return "".join(text), i

    i, line_start = 0, 0
    while i < n:
        c = source[i]
        if c == "\n":
            state["line"] += 1
            i += 1
            line_start = i
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif source.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    if source[i] == "\n":
                        state["line"] += 1
                        line_start = i + 1
                    i += 1
        elif c == '"' or (c == "#" and starts_string(i)):
            line, before = state["line"], source[line_start:i]
            opener = source[i:i + 3 + len(source[i:]) - len(source[i:].lstrip("#"))]
            multi = '"""' in opener
            text, i = scan(i)
            if multi:
                rows = text.split("\n")
                last = rows[-1]
                indent = len(last) - len(last.lstrip(" \t")) if not last.strip() else 0
                body = rows[1:-1] if len(rows) > 1 else rows
                text = "\n".join(r[indent:] if not r[:indent].strip() else r for r in body)
            found.append((line, text, before))
            line_start = source.rfind("\n", 0, i) + 1
        else:
            i += 1
    return sorted(found, key=lambda row: row[0])


WORD = re.compile(r"[A-Za-z][A-Za-z’']+")


def reads_as_english(text: str) -> bool:
    """Whether a literal reads as words for a person rather than as a key.

    Without a space it is an identifier, a key path, a pattern or a code —
    unless it is one capitalised word ("Summary", "Today"), which is how a
    label looks. With spaces, a date pattern ("d MMM yyyy") is every "word"
    one letter repeated; anything else with a lower-case word of two letters
    or more reads as prose ("§ (§ of §)" included).
    """
    words = WORD.findall(text.replace("§", " "))
    if not words:
        return False
    stripped = text.strip()
    if not re.search(r"\s", stripped):
        return bool(re.fullmatch(r"[A-Z][a-z’']{2,}[.…:!?]?", stripped))
    if all(len(set(word.lower())) == 1 for word in words):
        return False
    return any(len(word) >= 2 and re.fullmatch(r"[A-Za-z]?[a-z’']+", word) for word in words)


# What the code just before a literal says about who reads it. Each of these
# is a place a person never sees the text: a key, a log, a comparison, a
# pattern, a model's prompt, an identifier, or the default of a keyed
# localization (whose key is the literal before it).
NOT_FOR_THE_READER = re.compile(r"""(?:
      forKey:\s* | forHTTPHeaderField:\s* | kvp\[\s* | \[\s* | cachedReport\(\s*
    | \bprint\(\s* | \bdebugPrint\(\s* | Logger\([^)]*? | \b(?:log|logger|persistenceLog)\.\w+\(\s* | os_log\(\s*
    | SheetTrace\.\w+\(\s* | preconditionFailure\(\s* | fatalError\(\s* | assertionFailure\(\s*
    | precondition\([^"]*? | assert\([^"]*?
    | hasPrefix\(\s* | hasSuffix\(\s* | \.contains\(\s* | [=!]=\s* | \bcase\s+(?:[^:"]*,\s*)?
    | \.range\(of:\s* | replacingOccurrences\(of:\s* | with:\s* | components\(separatedBy:\s* | separator:\s*
    | dateFormat\s*=\s* | @Guide\(description:\s* | systemImage:\s* | systemName:\s* | Image\(\s*
    | URL\(string:\s* | forResource:\s* | withExtension:\s* | appendingPathComponent\(\s* | appending\(path:\s*
    | sql:\s* | accessibilityIdentifier\(\s* | \bcase\s+\w+\s*=\s* | keywords:\s*
    | defaultValue:\s* | comment:\s* | table:\s* | URLQueryItem\(name:\s* | identifier:\s*
    | subsystem:\s* | category:\s* | @AppStorage\(\s* | NSDeviceDescriptionKey\(\s* | \#Preview\(\s*
    | pattern:\s* | format:\s* | TimeZone\(identifier:\s* | Locale\(identifier:\s* | malformedResponse\(\s*
    )$""", re.VERBOSE)


def load_exemptions() -> list[tuple[str, str, str]]:
    """`localization-exempt.tsv`: path, literal (or `*` for the whole file),
    why. A literal ending in `…` matches any literal it begins; `\n` is a
    newline. Lines starting with `#` are comments."""
    if not EXEMPTIONS.exists():
        return []
    rows: list[tuple[str, str, str]] = []
    for raw in EXEMPTIONS.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) != 3 or not parts[2].strip():
            sys.exit(f"{EXEMPTIONS.name}: needs path, literal and a reason, tab-separated: {raw!r}")
        rows.append((parts[0], parts[1].replace("\\n", "\n"), parts[2]))
    return rows


def exempts(literal: str, text: str) -> bool:
    if literal == "*":
        return True
    if literal.endswith("…") and len(literal) > 1:
        return text.startswith(literal[:-1])
    return text == literal


def emitted_by_source(roots: list[pathlib.Path]) -> dict[str, set[str]]:
    """Each source's emitted keys, normalised to `§` for every placeholder."""
    found: dict[str, set[str]] = {}
    for root in roots:
        for path in root.rglob("*.stringsdata"):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            rel = repo_relative(data.get("source", ""))
            if rel is None:
                continue
            keys = found.setdefault(rel, set())
            for entries in (data.get("tables") or {}).values():
                for entry in entries:
                    # An App Shortcut lists every phrase under `values`; the
                    # key is only the first of them.
                    for key in [entry.get("key"), *(entry.get("values") or [])]:
                        if key:
                            keys.add(KEY_PLACEHOLDER.sub("§", key).replace("%%", "%"))
    return found


# App Shortcuts phrases are their own table, `AppShortcuts`, and their own
# catalog beside the app's: each language lists every phrase a person can say,
# and each phrase must name the app. They were in English only — Siri and
# Shortcuts offered "FinvestLens net worth" to a reader of any language.
SHORTCUTS_CATALOG = "finvestlens/AppShortcuts.xcstrings"
APP_NAME_TOKEN = "${applicationName}"


def check_shortcuts(roots: list[pathlib.Path]) -> list[str]:
    phrases: dict[str, list[str]] = {}
    for root in roots:
        for path in root.rglob("ExtractedAppShortcutsMetadata.stringsdata"):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            if scope_for(data.get("source", "")) is None:
                continue
            for entry in (data.get("tables") or {}).get("AppShortcuts", []):
                if key := entry.get("key"):
                    phrases[key] = list(entry.get("values") or [key])
    if not phrases:
        return []
    path = REPO / SHORTCUTS_CATALOG
    if not path.exists():
        return [f"{SHORTCUTS_CATALOG}: no such catalog, but the app declares "
                f"{len(phrases)} App Shortcuts — their phrases exist in English only"]
    entries = json.loads(path.read_text())["strings"]
    problems = [f"{SHORTCUTS_CATALOG}: missing shortcut {key!r}" for key in sorted(set(phrases) - set(entries))]
    problems += [f"{SHORTCUTS_CATALOG}: orphan shortcut {key!r} — declared by nothing"
                 for key in sorted(set(entries) - set(phrases))]
    for key in sorted(set(phrases) & set(entries)):
        localizations = entries[key].get("localizations") or {}
        english = ((localizations.get("en") or {}).get("stringSet") or {}).get("values")
        if english is not None and english != phrases[key]:
            problems.append(f"{SHORTCUTS_CATALOG}: {key!r} lists {english}, the code says {phrases[key]}")
        for language in sorted(LANGUAGES):
            values = ((localizations.get(language) or {}).get("stringSet") or {}).get("values") or []
            if not values:
                problems.append(f"{SHORTCUTS_CATALOG}: {key!r} has no phrases in {language}")
            problems += [f"{SHORTCUTS_CATALOG}: {key!r} [{language}] does not name the app once — {value!r}"
                         for value in values if value.count(APP_NAME_TOKEN) != 1]
    return problems


def shipped_sources() -> list[pathlib.Path]:
    """The Swift files whose strings a reader can meet."""
    out = []
    for root in LITERAL_ROOTS:
        for path in sorted((REPO / root).rglob("*.swift")):
            rel = path.relative_to(REPO).as_posix()
            if path.name == "Package.swift" or "/.build/" in f"/{rel}" or "/Tests/" in f"/{rel}" \
                    or rel.startswith(("Packages/CLI/", "Packages/Lab/")):
                continue
            out.append(path)
    return out


def check_literals(roots: list[pathlib.Path]) -> list[str]:
    emitted = emitted_by_source(roots)
    if not any(rel.startswith("Packages/") for rel in emitted):
        return ["unseen: no package sources in the extraction — build with "
                "--build, or pass both platforms' --strings-dir"]
    exemptions = load_exemptions()
    used: set[int] = set()
    problems: list[str] = []
    for path in shipped_sources():
        rel = path.relative_to(REPO).as_posix()
        keys = emitted.get(rel, set())
        for line, text, before in swift_literals(path.read_text(encoding="utf-8")):
            if not reads_as_english(text) or text.replace("%%", "%") in keys:
                continue
            if NOT_FOR_THE_READER.search(before):
                continue
            matched = [index for index, (where, literal, _) in enumerate(exemptions)
                       if where == rel and exempts(literal, text)]
            if matched:
                used.update(matched)
                continue
            shown = text if len(text) <= 120 else text[:117] + "…"
            problems.append(f"{rel}:{line}: English the compiler cannot see — {shown!r}")
    for index, (where, literal, _) in enumerate(exemptions):
        if index not in used:
            problems.append(f"{EXEMPTIONS.name}: exempts nothing any more — {where} {literal!r}")
    return problems


def literal_self_test() -> list[str]:
    """The scanner and the judgement, on the shapes that tripped them."""
    failures: list[str] = []
    source = r"""
let a = "plain"            // "a comment"
let b = "No rate for \(rates.missing.joined(separator: ", ")) — holdings."
let c = \"\"\"
    First line \(x)
    second "quoted" line
    \"\"\"
/* a "block" */ let d = #"raw \d+ "inner" \#(v)"#
let e = String(localized: "FY \(String(fromYear))–\(String(format: "%02d", toYear % 100))")
Text("Each edit is recorded in \(url ?? "the audit log").")
""".replace('\\"\\"\\"', '"""')
    got = [(line, text) for line, text, _ in swift_literals(source)]
    want = [(2, "plain"), (3, "No rate for § — holdings."), (3, ", "),
            (4, "First line §\nsecond \"quoted\" line"), (8, 'raw \\d+ "inner" §'),
            (9, "FY §–§"), (9, "%02d"), (10, "Each edit is recorded in §."), (10, "the audit log")]
    if sorted(got) != sorted(want):
        failures.append(f"swift_literals: got {got}, expected {want}")
    english = ["Today", "Summary", "Couldn’t save “§”: §", "§ (§ of §)", "§ via §",
               "Undo §", "D/M/Y — Australian", "no data"]
    not_english = ["finvestlens.recentBookPaths", "yyyy-MM-dd", "dd MMM yyyy", "AUD",
                   "FinvestLens", "session.period:§", "accounts", "%@ · %@", "§", "Finance::Quote:§"]
    failures += [f"reads_as_english({t!r}) is False" for t in english if not reads_as_english(t)]
    failures += [f"reads_as_english({t!r}) is True" for t in not_english if reads_as_english(t)]
    ignored = ['UserDefaults.standard.set(x, forKey: ', 'let row = try db.execute(sql: ',
               'if name == ', 'logger.error(', '@Guide(description: ',
               'String(localized: "Money in (cash flow)", defaultValue: ']
    shown = ['showToast(.info, ', 'DocumentError(message: ', 'Text(', 'label: ']
    failures += [f"NOT_FOR_THE_READER misses {b!r}" for b in ignored if not NOT_FOR_THE_READER.search(b)]
    failures += [f"NOT_FOR_THE_READER takes {b!r}" for b in shown if NOT_FOR_THE_READER.search(b)]
    safe = [("Every day", 1), ("Every day, from %2$@", 2), ("Jeden Tag", 1)]
    unsafe = [("Every day, from %@", 2), ("%3$@", 2)]
    failures += [f"fewer_is_safe({f!r}, {n}) is False" for f, n in safe if not fewer_is_safe(f, n)]
    failures += [f"fewer_is_safe({f!r}, {n}) is True" for f, n in unsafe if fewer_is_safe(f, n)]
    return failures


def self_test() -> int:
    """Which catalog a source belongs to, on a Mac and on the runner.

    The scoping is by path, and paths differ between the machine this is
    written on and the one CI builds on — which is how a gate came to pass
    in one place and fail in the other. These are the shapes both produce.
    """
    app = "finvestlens/Localizable.xcstrings"
    runner = "/Users/runner/work/finvestlens/finvestlens"
    mac = "/Volumes/Work/finvestlens"
    derived = "/Users/someone/Library/Developer/Xcode/DerivedData/finvestlens-abcdefgh"
    cases: list[tuple[str, str | None]] = [
        (f"{runner}/finvestlens/ContentView.swift", app),
        (f"{mac}/finvestlens/ContentView.swift", app),
        (f"{runner}/Packages/FeatureUI/Sources/FinvestLensUI/Views.swift", app),
        (f"{mac}/Packages/Intelligence/Sources/FinvestLensIntelligence/LanguageModels.swift", app),
        (f"{runner}/FinvestLensWidgets/Widgets.swift", "FinvestLensWidgets/Localizable.xcstrings"),
        (f"{runner}/FinvestLensQuickLook/Preview.swift", "FinvestLensQuickLook/Localizable.xcstrings"),
        # Tests, and the two command-line tools, ship no strings.
        (f"{runner}/Packages/FeatureUI/Tests/FinvestLensUITests/SomeTests.swift", None),
        (f"{runner}/Packages/CLI/Sources/finlens/Main.swift", None),
        (f"{runner}/Packages/Lab/Sources/finlab/Main.swift", None),
        # Somebody else's package, wherever Xcode checked it out: inside the
        # checkout on the runner, under ~/Library on a Mac, under a package's
        # own `.build` for `swift build`.
        (f"{runner}/DerivedData/SourcePackages/checkouts/swift-transformers/Sources/Hub/Hub.swift", None),
        (f"{derived}/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/Load.swift", None),
        (f"{mac}/Packages/Persistence/.build/checkouts/GRDB.swift/GRDB/Core/Database.swift", None),
        # And a path that names no part of this repository at all.
        ("/usr/lib/swift/Something.swift", None),
    ]
    failures = [(source, expected, scope_for(source))
                for source, expected in cases if scope_for(source) != expected]
    for source, expected, got in failures:
        print(f"scope_for({source!r}) is {got!r}, expected {expected!r}")
    literal_failures = literal_self_test()
    for failure in literal_failures:
        print(failure)
    if failures or literal_failures:
        print(f"\n{len(failures)} of {len(cases)} scoping cases wrong; "
              f"{len(literal_failures)} scanner case(s) wrong.")
        return 1
    print(f"Scoping: all {len(cases)} cases right. Scanner: every case right.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", action="store_true",
                        help="build both platforms with the extractor on, then check")
    parser.add_argument("--strings-dir", action="append", default=[],
                        help="directory of .stringsdata to scan (repeatable)")
    parser.add_argument("--derived-data", help="DerivedData root (default: ask xcodebuild)")
    parser.add_argument("--no-discover", action="store_true",
                        help="don't look for DerivedData; --strings-dir already has everything")
    parser.add_argument("--self-test", action="store_true",
                        help="check the path scoping and the source scanner, and stop")
    parser.add_argument("--literals", action="store_true",
                        help="also read the source for English the compiler cannot see "
                             "(on by default with --build)")
    parser.add_argument("--only-literals", action="store_true",
                        help="read the source for English the compiler cannot see, and nothing else")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

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
        problems: list[str] = []
        if not args.only_literals:
            emitted = emitted_by_scope(roots)
            for catalog_rel, _ in SCOPES:
                problems += check(catalog_rel, emitted[catalog_rel])
            problems += check_shortcuts(roots)
        if args.literals or args.only_literals or args.build:
            problems += check_literals(roots)
    finally:
        if temp:
            shutil.rmtree(temp, ignore_errors=True)

    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} localization problem(s).")
        return 1
    if args.only_literals:
        print("No English a reader meets is out of the compiler's sight.")
    else:
        print("Localization catalogs match the compiler's output.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
