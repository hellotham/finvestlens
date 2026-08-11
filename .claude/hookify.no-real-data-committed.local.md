---
name: no-real-data-committed
enabled: true
event: bash
action: block
pattern: (?m)^\s*(?:[^|;&\n]*&&\s*)?git\s+(?:add|commit)\b[^|;&\n]*(?:imports/|\.finvestlens\b|Box-Box|/Volumes/Cloud)
---

🚫 **That command names real financial data.**

`imports/` (real bank exports), any `*.finvestlens` book, and everything under
`~/Library/CloudStorage/Box-Box` or `/Volumes/Cloud` are one real household's
accounts. They are gitignored — but `git add -f` overrides `.gitignore` without
a word, and that is the only way this has ever nearly happened.

**Why a hook and not a rule:** the repository cannot be un-published. A commit
message carrying real balances already cost this project two history rewrites
*and* a GitHub support ticket, because unreferenced objects stay served until
GitHub garbage-collects them. A file is worse: it carries every balance at once.

**Instead:** public imagery and fixtures come from the synthetic generator in
`website/scripts/demo-book/`. If you need a book to test against, generate one —
never copy the real one into the tree.

If the path really is synthetic, say so and add it by its explicit path rather
than with `-f`.
