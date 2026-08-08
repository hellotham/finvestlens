#!/usr/bin/env python3
"""UserPromptSubmit hook: restate explicit directives as a checklist up front.

The Stop gate catches a dropped instruction at the end. This catches it at the
start, which is cheaper: it reads the prompt, names the directives it contains,
and puts them back into context as a checklist that has to be discharged.

Prints plain text on stdout, which the harness appends to the turn's context.
Silent when the prompt carries no directive.
"""

import json
import re
import sys

DIRECTIVES = [
    (r"\bredesign\b",
     "REDESIGN — rework the design, not a patch on the existing one."),
    (r"\b(research|best practice|investigate)\b",
     "RESEARCH — fetch real sources this session; do not answer from memory."),
    (r"\b(hig|human interface guidelines)\b",
     "APPLE HIG — the pages are JS-rendered: WebFetch returns the title only. "
     "Use the Browser pane (preview_start + get_page_text) and quote what it says."),
    (r"\bgnucash\b",
     "GNUCASH SOURCE — ~/Repositories/gnucash-reference, sparse: run "
     "`git sparse-checkout add gnucash/register` before claiming to have read it."),
    (r"\b(security)\b.{0,20}\b(review|audit|check)\b",
     "SECURITY REVIEW — run it and report findings."),
    (r"\b(accessibility|a11y|voiceover)\b",
     "ACCESSIBILITY REVIEW — labels, focus order, Dynamic Type, contrast, keyboard."),
    (r"\bdo not|don'?t\b",
     "PROHIBITION — the user has ruled something out; re-read it before acting."),
    (r"\bcommit\b.{0,12}\bpush\b|\bcommit and push\b",
     "COMMIT — run /preflight first (all package suites + both platform builds "
     "+ help drift + SPDX). Straight to main, no trailers, no /commit-push-pr."),
    (r"\bcode review\b|\breview (?:the |all )?(?:code|codebase|changes)\b",
     "CODE REVIEW — run /code-review and report its findings. `/code-review "
     "ultra` (cloud) is user-triggered and billed: suggest it, never launch it."),
    (r"\b(?:implement|rewrite|refactor)\b",
     "AFTER IMPLEMENTING — before reporting done: /ui-review if UI was touched, "
     "/preflight if a commit follows, /code-review scaled to the change."),
]


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    prompt = payload.get("prompt") or ""
    hits = [note for pattern, note in DIRECTIVES if re.search(pattern, prompt, re.I)]
    if not hits:
        return
    print("Explicit directives in this request — each must be discharged, "
          "and a Stop hook checks for evidence:")
    for note in hits:
        print("  - " + note)
    print("A claim carries its receipt: state \"builds\", \"tests pass\", "
          "\"verified\", \"consulted X\" only in the same turn as the command "
          "or observation that proves it, and name what was not run. "
          "Directives do not expire — the Stop gate scans the last five user "
          "turns, not just this one.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
