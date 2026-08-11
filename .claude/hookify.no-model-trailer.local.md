---
name: no-model-trailer
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: (?m)^\s*(?:[^|;&\n]*&&\s*)?git\s+commit\b
  - field: command
    operator: regex_match
    pattern: (?i)co-authored-by|generated with \[?claude|🤖
---

🚫 **No model attribution in commit messages.**

This repo's commits carry no `Co-Authored-By` trailer, no "Generated with…"
line, and no robot emoji. An early session asked for one; the user reversed it
— *"you can remove model attribution (Fable vs Opus etc)"* — and the later
instruction wins.

**Why a hook:** a commit message is published the moment it is pushed and
cannot be corrected without rewriting history *and* asking GitHub to collect
the orphaned objects. Catching it before the commit costs nothing; catching it
after costs a support ticket.

Write the message as the project's own, in its own voice.
