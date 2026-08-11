#!/usr/bin/env python3
"""Stop hook: refuse to end a turn that ignored an instruction or asserted
unevidenced work.

Two checks, built from this session's actual failures (transcript-reviewed
8 Aug 2026):

1. Directive coverage — across turns, not just the latest message. The last
   WINDOW real user turns are each scanned for directive verbs ("research",
   "consult X", "redesign", …), and each directive needs tool-use evidence
   *somewhere after the turn that gave it*. The v1 gate read only the latest
   user message, so an instruction from three turns back could be dropped
   silently. Directives do not expire.

2. Attestation — the final assistant message is scanned for completion claims
   ("tests pass", "both platforms build", "verified on screen", "committed",
   "consulted the GnuCash source") and each claim must have matching tool
   evidence since the last real user turn. One session wrote "verified" 96
   times; the handful that were false — sources cited from memory, GUI results
   never seen — are why this check exists. A claim carries its receipt.

Deliberate limits, so nobody mistakes this for more than it is:
  * Keyword and regex matching, not meaning. It cannot judge whether the work
    is any good, and a rescinded directive can false-positive once — the
    stop_hook_active loop guard caps that at one forced continuation, where
    "X does not apply because Y" is a legitimate discharge.
  * Evidence regexes match that a command string appeared, not that it
    succeeded. The floor is raised; the reviewer is still the user.

Exit 0 with no output = allow. {"decision":"block"} = force the turn on.
Never exits non-zero on its own bugs: a broken gate must not wedge the session.
"""

import json
import re
import sys

WINDOW = 5  # how many real user turns back the directive scan reaches

# (label, pattern in the user's request, what counts as evidence after it)
DIRECTIVES = [
    (
        "research / best practices",
        r"\b(research|best practice|look .{0,12}up|find out|investigate)\b",
        # context7 is the library-docs research channel; its tool calls are
        # evidence of research exactly as a WebFetch is.
        r"WebFetch|WebSearch|Claude_Browser|get_page_text|context7|query-docs|resolve-library-id",
    ),
    (
        "consult the Apple HIG",
        r"\b(hig|human interface guidelines|apple guidelines)\b",
        r"human-interface-guidelines|get_page_text",
    ),
    (
        "consult the GnuCash source",
        r"\bgnucash\b",
        r"gnucash-reference|split-register|register-core|ledger-core",
    ),
    (
        "security review",
        r"\bsecurity\b.{0,20}\b(review|audit|check)\b|\b(review|audit)\b.{0,20}\bsecurity\b",
        r"security",
    ),
    (
        "accessibility review",
        r"\b(accessibility|a11y|voiceover)\b",
        r"accessibility|VoiceOver|accessibilityLabel",
    ),
    (
        "redesign (not a patch)",
        r"\bredesign\b",
        r'"(Write|Edit|MultiEdit)"',
    ),
    (
        "commit and push",
        r"\bcommit and push\b|\bcommit & push\b|\bcommit\b.{0,12}\bpush\b",
        r"git (commit|push)",
    ),
    (
        "code review",
        r"\bcode review\b|\breview (?:the |all )?(?:code|codebase|changes)\b",
        r"ReportFindings|code-review",
    ),
]

# (label, claim pattern in the FINAL assistant message,
#  [evidence patterns since the last user turn — ALL must appear])
CLAIMS = [
    (
        "a test result",
        r"\b(?:tests?|suites?) (?:pass(?:es|ed)?|are green|succeed)"
        r"|\ball \d+ tests\b|\b\d+ tests? pass",
        [r"swift test|python3|pytest"],
    ),
    (
        "a build result",
        r"\b(?:builds?|built|compiles?) (?:pass|succeed|clean|fine|green|ok)"
        r"|\b(?:both platforms?|apps?|packages?) (?:now )?builds?\b",
        [r"xcodebuild|swift build"],
    ),
    (
        "both platforms building (needs both destinations)",
        r"\bboth platforms\b.{0,50}\bbuild",
        [r"platform=macOS", r"platform=iOS Simulator"],
    ),
    (
        "on-screen verification",
        r"\b(?:verified|confirmed) (?:visually|on[- ]screen)\b"
        r"|\bscreenshot (?:shows|confirms)\b|\bsaw (?:it|the \w+) (?:render|work|draw)\b",
        [r"screencapture|screenshot|get_page_text|read_page|zoom"],
    ),
    (
        "having consulted the GnuCash source",
        r"\b(?:consulted|read|opened|checked|inspected)\b[^.\n]{0,40}\bgnucash\b",
        [r"gnucash-reference"],
    ),
    (
        "having consulted the HIG",
        r"\b(?:consulted|read|opened|checked)\b[^.\n]{0,40}\b(?:hig\b|human interface)",
        [r"human-interface-guidelines|get_page_text"],
    ),
    (
        "a commit / push",
        r"\b(?:committed and pushed|committed to main|have committed|pushed to "
        r"(?:github|origin|main))\b",
        [r"git (?:commit|push)"],
    ),
]

# A claim preceded (within a sentence) by intent language is a plan, not a
# report. "I will make sure the tests pass" asserts nothing; "the tests pass"
# does. Fixed lookbehinds cannot span the article in "make sure THE tests
# pass", so the check reads the 60 characters before each match instead.
HYPOTHETICAL = re.compile(
    r"\b(?:will|would|should|shall|must|until|unless|ensure|make sure|making sure"
    r"|once|whether|going to|needs? to|plan(?:s|ning)? to|so that|to see if"
    r"|checks? that|verify(?:ing)? that)\b[^.\n!?]{0,50}$",
    re.I,
)


# A claim that is *denied* is not a claim. CLAUDE.md ▸ Working rules requires
# naming what was **not** run ("iOS build not attempted"), and the only way to
# write that sentence is with the same words as the claim — so a gate that
# cannot tell "both platforms build" from "both platform builds — not run"
# punishes precisely the honesty it exists to demand. The negation can sit on
# either side of the match, so both are read.
NOT_RUN = re.compile(
    r"\b(?:not|never|isn'?t|wasn'?t|weren'?t|aren'?t|didn'?t|don'?t|no)\b"
    r"[^.\n]{0,20}\b(?:re)?(?:run|ran|attempt(?:ed)?|built|build|rebuilt|needed"
    r"|required|necessary|executed|tried|touched)\b"
    r"|\bskipped\b|\bnothing to (?:re)?build\b|\bunverified\b",
    re.I)

# Compiled-from-source claims only need a fresh receipt when the turn produced
# something new to compile. Demanding a rebuild after a prose-only turn is not
# rigour, it is make-work — and it taught exactly that: two full platform
# builds were run to satisfy this gate on a turn whose only change was one
# Markdown file. The user's rule: "if you did not change code, you shouldn't
# rebuild."
BUILD_CLAIMS = {"a build result", "both platforms building (needs both destinations)"}
SOURCE_EDIT = r'"file_path"\s*:\s*"[^"]+\.swift"'


def asserted(claim_pattern, text):
    """True iff `text` states the claim as a done fact at least once."""
    for match in re.finditer(claim_pattern, text, re.I):
        window = text[max(0, match.start() - 60):match.end() + 60]
        before = text[max(0, match.start() - 60):match.start()]
        if HYPOTHETICAL.search(before) or NOT_RUN.search(window):
            continue
        return True
    return False


# User-role entries that are not the user asking for anything. Counting them as
# requests measured the wrong window; counting the compact summary would demand
# re-evidence for every directive it merely narrates.
NOT_A_REQUEST = (
    "<task-notification>",
    "[SYSTEM NOTIFICATION - NOT USER INPUT]",
    "<local-command-stdout>",
    "<local-command-caveat>",
    "This session is being continued from a previous conversation",
    # The gates' own block messages echo directive words ("research",
    # "redesign") back into the transcript as user-role entries; counting
    # them as requests makes the gate demand fresh evidence after every one
    # of its own firings — a feedback loop, not a directive.
    "Stop hook feedback:",
    "Stop hook blocking error",
)


def flat_text(msg):
    """Flatten a message's content to its typed/emitted text."""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
    return "\n".join(parts)


def load(path):
    """One pass over the transcript. Keeps, per entry:
    (kind, request_or_final_text, raw_line_for_evidence)."""
    records = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    entry = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                kind = "other"
                text = ""
                msg = entry.get("message") or {}
                if entry.get("type") == "user" and not entry.get("isSidechain"):
                    body = flat_text(msg)
                    content = msg.get("content")
                    has_tool_result = isinstance(content, list) and any(
                        isinstance(b, dict) and b.get("type") == "tool_result"
                        for b in content
                    )
                    is_reminder = ("<system-reminder>" in body
                                   and body.strip().endswith("</system-reminder>"))
                    if body.strip() and not has_tool_result and not is_reminder \
                            and not any(m in body for m in NOT_A_REQUEST):
                        # Slash-command turns carry the request in <command-args>;
                        # the surrounding template is not the user's text.
                        args = re.search(r"<command-args>(.*?)</command-args>", body, re.S)
                        if "<command-name>" in body:
                            if args and args.group(1).strip():
                                kind, text = "user", args.group(1)
                        else:
                            kind, text = "user", body
                elif entry.get("type") == "assistant" and not entry.get("isSidechain"):
                    text = flat_text(msg)
                    if text.strip():
                        kind = "assistant"
                records.append((kind, text, raw))
    except OSError:
        pass
    return records


def evidence_after(records, start, patterns):
    """True iff every pattern appears in some raw entry after index `start`.
    Sidechain (subagent) entries count — delegated research is research."""
    compiled = [re.compile(p, re.I) for p in patterns]
    remaining = list(range(len(compiled)))
    for _, _, raw in records[start + 1:]:
        remaining = [i for i in remaining if not compiled[i].search(raw)]
        if not remaining:
            return True
    return False


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return  # malformed input: never block on our own failure

    # The turn we already blocked once. Blocking again would loop forever.
    if payload.get("stop_hook_active"):
        return

    records = load(payload.get("transcript_path", ""))
    if not records:
        return

    user_idx = [i for i, (kind, _, _) in enumerate(records) if kind == "user"]
    if not user_idx:
        return
    window = user_idx[-WINDOW:]

    # 1. Directive coverage across the window.
    missing = []
    for idx in window:
        request = records[idx][1].lower()
        for label, wanted, evidence in DIRECTIVES:
            if re.search(wanted, request, re.I) \
                    and not evidence_after(records, idx, [evidence]) \
                    and label not in missing:
                missing.append(label)

    # 2. Attestation in the final assistant message.
    final = ""
    for kind, text, _ in reversed(records):
        if kind == "assistant":
            final = text
            break
    unproven = []
    last_user = user_idx[-1]
    touched_source = evidence_after(records, last_user, [SOURCE_EDIT])
    for label, claim, evidence in CLAIMS:
        if label in BUILD_CLAIMS and not touched_source:
            continue                 # nothing new to compile; no receipt owed
        if asserted(claim, final) \
                and not evidence_after(records, last_user, evidence):
            unproven.append(label)

    if not missing and not unproven:
        return

    parts = []
    if missing:
        parts.append(
            "Instructions from the last %d user turns with no evidence of being "
            "carried out: %s." % (WINDOW, "; ".join(missing))
        )
    if unproven:
        parts.append(
            "The final message claims %s, but the turn contains no tool run that "
            "proves it." % "; ".join(unproven)
        )
    reason = (
        "This turn cannot end yet. " + " ".join(parts) + "\n\n"
        "Per CLAUDE.md ▸ Working rules: a direct instruction is the task, "
        "directives do not expire, and a claim carries its receipt. Do the "
        "outstanding items now — actually open the source, actually run the "
        "command — or state explicitly what remains undone and why. Rewrite any "
        "unproven claim to say what was actually observed."
    )
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a broken gate must fail open, never wedge the session
