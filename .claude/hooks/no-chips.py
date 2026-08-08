#!/usr/bin/env python3
"""PreToolUse hook: refuse to spawn background-task chips.

The user asked for work to run as subagents in this session and explicitly ruled
out chips. That prohibition was honoured in the main loop and then broken twice
by *delegated* subagents, which had the tool and no instruction not to use it.

A Stop hook cannot catch that — it reads this session's transcript, and a
subagent's tool calls never appear there. A PreToolUse gate can, because it runs
wherever the tool is invoked. This is the difference between a rule written down
and a rule enforced.

Emits the modern `hookSpecificOutput.permissionDecision` form, plus the legacy
top-level `decision` for older harnesses. Fails open on its own errors.
"""

import json
import sys

BLOCKED = "spawn_task"

REASON = (
    "Chips are prohibited for this work — the user asked that it run as "
    "subagents in this session instead, so no context is lost. Do the work now, "
    "or delegate it with the Agent tool. If you are a subagent: return the "
    "finding in your report and let the main loop decide; do not spawn a chip."
)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return

    name = payload.get("tool_name") or ""
    if BLOCKED not in name:
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASON,
        },
        "decision": "block",
        "reason": REASON,
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
