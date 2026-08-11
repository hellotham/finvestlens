#!/usr/bin/env python3
#
#  spdx-on-new-source.py — PostToolUse: a new Swift file without its licence.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
"""Catch a missing SPDX header when the file is written, not at commit time.

Every Swift source under `Packages/`, the app target and the extensions carries
`// SPDX-License-Identifier: GPL-3.0-or-later`; CI gates exactly those roots and
`/preflight` checks it before a commit. Both work — the count of offenders is
currently zero — but both report *late*: CI is minutes away and preflight is a
whole implementation later, by which time the file has been edited a dozen
times and the omission is a chore rather than a keystroke.

This is GPL-3.0-or-later software. A source file shipped without its licence
header is a licensing defect, not a style one, which is why it is worth a
reminder at the moment of creation.

Scoped to `Write` (a file being created or replaced wholesale). An `Edit` to an
existing file cannot introduce this defect — the header is already there or the
file already predates the rule — and firing on every edit would be noise.
"""

from __future__ import annotations

import json
import re
import sys

# Exactly the roots CI gates. `website/scripts/` tooling sits outside it.
GATED = re.compile(r"(?:^|/)(?:Packages|finvestlens|FinvestLensWidgets"
                   r"|FinvestLensQuickLook)/.*\.swift$")
SPDX = "SPDX-License-Identifier: GPL-3.0-or-later"

HEADER = """//
//  {name}
//  finvestlens
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//"""


def main() -> None:
    payload = json.loads(sys.stdin.read() or "{}")
    if payload.get("tool_name") != "Write":
        return
    tool_input = payload.get("tool_input") or {}
    path = tool_input.get("file_path", "")
    if not GATED.search(path):
        return
    content = tool_input.get("content", "")
    if not isinstance(content, str) or SPDX in content:
        return

    name = path.split("/")[-1]
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext":
                f"`{name}` was written without its SPDX header, and it sits under "
                "a root that CI gates. This is GPL-3.0-or-later software: a source "
                "file without its licence line is a licensing defect, and the "
                "cheapest moment to fix it is now rather than when preflight or CI "
                "reports it.\n\nAdd at the top of the file:\n\n"
                + HEADER.format(name=name)
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        print("spdx-on-new-source.py CRASHED — hook is not running:", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
