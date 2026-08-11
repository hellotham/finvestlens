#!/usr/bin/env python3
#
#  stale-build-caches.py — PostToolUse: an Engine type changed under you.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Warn when an `Engine` edit invalidates other packages' module caches.

CLAUDE.md ▸ Conventions has carried this as prose since July: after adding or
changing `Engine` types, clear dependent packages' `.build` directories and the
app's DerivedData `Build` folder, because "stale module caches will happily
link old package code". Prose did not stop it happening. On 11 Aug 2026 a new
`Engine` type read as `cannot find 'DatePlausibility' in scope` from a
dependent package while `Engine`'s own suite passed — the compiler was linking
a cached module that predated the type.

The signal is deterministic (the file path), but firing on *every* Engine edit
would be noise, and a gate that cries on ordinary work gets switched off. So it
fires only when the edit text declares or removes a type or a `public` member —
the changes that actually move the module interface. Editing a function body
inside an existing type says nothing to a dependent package.

Non-blocking by design: this is a reminder at the moment the risk is created,
not a refusal. The rebuild is cheap; the hour spent debugging a phantom
"cannot find in scope" is not.
"""

from __future__ import annotations

import json
import re
import sys

WATCHED = re.compile(r"Packages/Engine/Sources/.*\.swift$")

# Declarations that change what a dependent module sees. A body-only edit does
# not, which is why the whole text is searched rather than the path alone.
INTERFACE = re.compile(
    r"\b(?:public|package|open)\b"
    r"|\b(?:struct|enum|class|actor|protocol|typealias|extension)\s+[A-Z]",
)

CLEAR = """rm -rf Packages/*/.build
rm -rf ~/Library/Developer/Xcode/DerivedData/finvestlens-*/Build"""


def edited_text(payload: dict) -> str:
    """Every side of this tool call — what it wrote *and* what it replaced.

    `old_string` matters as much as `new_string`: deleting a public type moves
    the module interface exactly as much as adding one, and a deletion's new
    text contains none of the keywords that would give it away. Scanning only
    what was written would have missed the removal half of the very problem
    this hook exists for.
    """
    tool_input = payload.get("tool_input") or {}
    parts = [tool_input.get(key, "")
             for key in ("new_string", "old_string", "content")]
    for edit in tool_input.get("edits") or []:            # MultiEdit
        if isinstance(edit, dict):
            parts += [edit.get("new_string", ""), edit.get("old_string", "")]
    return "\n".join(p for p in parts if isinstance(p, str))


def main() -> None:
    payload = json.loads(sys.stdin.read() or "{}")
    if payload.get("tool_name") not in ("Edit", "Write", "MultiEdit"):
        return
    path = (payload.get("tool_input") or {}).get("file_path", "")
    if not WATCHED.search(path):
        return
    if not INTERFACE.search(edited_text(payload)):
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext":
                f"An Engine declaration changed ({path.split('/')[-1]}). Dependent "
                "packages and the app now hold module caches that predate it, and "
                "they fail as `cannot find 'X' in scope` from a package whose own "
                "tests pass — a symptom that reads like a missing import.\n\n"
                "Before building or testing anything downstream:\n\n"
                f"{CLEAR}\n\n"
                "CLAUDE.md ▸ Conventions. Skip this only if nothing outside "
                "Engine will be compiled before the caches are rebuilt anyway."
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open, loudly — a reminder must never wedge a session, but a
        # silent hook is indistinguishable from one that agrees with you.
        import traceback
        print("stale-build-caches.py CRASHED — hook is not running:", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
