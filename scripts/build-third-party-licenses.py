#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write `finvestlens/ThirdPartyLicenses.txt`: the licence and notice files of
every open-source package linked into the app, as their authors wrote them.

The MIT licence asks that its copyright notice and permission notice be
"included in all copies or substantial portions of the Software", and the
Apache License that recipients be given "a copy of this License" and any
NOTICE file. A copy of the app from the App Store has no repository beside
it, so the texts travel inside it and Settings ▸ Acknowledgements shows them.

The texts are copied, never retyped: this reads them out of the package
checkouts Xcode keeps, for the packages `Acknowledgements.linked` names in
`AcknowledgementsView.swift` and the works those carry inside them. Texts
that are word for word the same (most Apache-2.0 files are) are printed once,
under every name they apply to.

    python3 scripts/build-third-party-licenses.py           # write the file
    python3 scripts/build-third-party-licenses.py --check   # fail if it would change

Run it after the project's packages change (`AcknowledgementsTests` says when
they have). It needs the checkouts, so it needs the project to have been
resolved once: `xcodebuild -resolvePackageDependencies -scheme finvestlens`.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = REPO / "finvestlens" / "ThirdPartyLicenses.txt"

# What is linked, in the order the Acknowledgements pane lists it, each with
# where its licence files are in the checkouts. A work carried inside another
# is named with its carrier, because that is how it reaches the app.
WORKS: list[tuple[str, str]] = [
    ("GRDB.swift", "GRDB.swift"),
    ("MLX Swift", "mlx-swift"),
    ("MLX (in MLX Swift)", "mlx-swift/Source/Cmlx/mlx"),
    ("MLX C (in MLX Swift)", "mlx-swift/Source/Cmlx/mlx-c"),
    ("{fmt} (in MLX Swift)", "mlx-swift/Source/Cmlx/fmt"),
    ("JSON for Modern C++ (in MLX Swift)", "mlx-swift/Source/Cmlx/json"),
    ("metal-cpp (in MLX Swift)", "mlx-swift/Source/Cmlx/metal-cpp"),
    ("MLX Swift LM", "mlx-swift-lm"),
    ("XGrammar (in MLX Swift LM)", "mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar"),
    ("swift-transformers", "swift-transformers"),
    ("swift-jinja", "swift-jinja"),
    ("swift-huggingface", "swift-huggingface"),
    ("swift-collections", "swift-collections"),
    ("swift-numerics", "swift-numerics"),
    ("swift-crypto", "swift-crypto"),
    ("EventSource", "EventSource"),
    ("yyjson", "yyjson"),
]

PREFIXES = ("LICENSE", "LICENCE", "NOTICE", "COPYING")
RULE = "=" * 78


def checkouts() -> pathlib.Path:
    """Where Xcode keeps the project's package checkouts."""
    out = subprocess.run(
        ["xcodebuild", "-scheme", "finvestlens", "-destination", "platform=macOS", "-showBuildSettings"],
        cwd=REPO, capture_output=True, text=True, check=False).stdout
    for line in out.splitlines():
        if " BUILD_DIR =" in line:
            derived = pathlib.Path(line.split("=", 1)[1].strip()).parent.parent
            found = derived / "SourcePackages" / "checkouts"
            if found.is_dir():
                return found
    sys.exit("no package checkouts found — resolve the project's packages first")


def render(root: pathlib.Path) -> str:
    # text -> (file name, [works it applies to]), in first-seen order
    texts: dict[str, tuple[str, list[str]]] = {}
    for name, relative in WORKS:
        directory = root / relative
        files = sorted(p for p in directory.iterdir()
                       if p.is_file() and p.name.upper().startswith(PREFIXES)) if directory.is_dir() else []
        if not files:
            sys.exit(f"{name}: no licence file in {directory}")
        for file in files:
            text = "\n".join(line.rstrip() for line in file.read_text(encoding="utf-8").strip().splitlines())
            texts.setdefault(text, (file.name, []))[1].append(name)

    parts = [
        "FinvestLens is built with the open-source software below. Each text is",
        "its authors' own, copied from the package it came in.",
        "",
    ]
    for text, (file, names) in texts.items():
        parts += [RULE, ", ".join(names), f"({file})", RULE, "", text, ""]
    return "\n".join(parts).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="fail if the file would change")
    parser.add_argument("--checkouts", type=pathlib.Path, help="package checkouts (default: ask xcodebuild)")
    arguments = parser.parse_args()
    text = render(arguments.checkouts or checkouts())
    if arguments.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != text:
            sys.exit(f"{OUTPUT.relative_to(REPO)} is out of date — run this script without --check")
        print(f"{OUTPUT.relative_to(REPO)} is up to date")
        return
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(REPO)}: {len(text):,} characters")


if __name__ == "__main__":
    main()
