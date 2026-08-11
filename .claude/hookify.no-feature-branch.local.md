---
name: no-feature-branch
enabled: true
event: bash
action: warn
pattern: \bgit\s+(?:checkout\s+-b|switch\s+-c|branch\s+(?!-[adDvlr])[A-Za-z])
---

⚠️ **This repo commits straight to `main`.**

No feature branches, and no pull requests — `/commit-push-pr` is avoided for
exactly that reason. A branch here becomes a second head nobody merges: one was
left behind by an earlier session and still carried commit messages that a
history rewrite had already cleaned from `main`.

This is a **warning**, not a block: a branch is occasionally the right tool
(an isolated worktree, a rewrite staged before force-pushing). If that is what
this is, carry on — and delete it when the work lands.
