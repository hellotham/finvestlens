---
name: relaunch
description: Build a signed macOS FinvestLens and relaunch it for the user's visual verification, releasing control immediately. Use after visual changes — the standing workflow is relaunch-and-release; the user does the looking.
---

# Relaunch — signed build, hand the app to the user

The standing instruction (given 24 Jul 2026): after changes, relaunch the app
and **release immediately** — the user verifies visually. Do not drive the GUI
with computer-use unless explicitly asked.

## 1. Quit any running copy — gracefully

```bash
osascript -e 'tell application "finvestlens" to quit' 2>/dev/null; sleep 2
```

One instance only. **Never `kill -9` by default**: the app holds an advisory
`.lock` beside the book, and a force-kill strands it — the next launch stops on
"locked by another FinvestLens instance". If a force-kill was truly
unavoidable, remove the stale `.lock` before relaunching.

## 2. Build signed

```bash
xcodebuild build -scheme finvestlens -destination 'platform=macOS' -allowProvisioningUpdates
```

Signed, not `CODE_SIGNING_ALLOWED=NO`: the unsigned build embeds no
entitlements, loses the App Group claim, and macOS asks "would like to access
data from other apps" on every launch (the ad-hoc signature changes per build,
so TCC never remembers).

## 3. Launch and release

```bash
open "$(xcodebuild -scheme finvestlens -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3; exit}')/finvestlens.app"
```

Then stop touching the machine. Report: built signed, relaunched, released —
**visual result unverified; over to you.** That last clause is the honest
completion report; on-screen claims require having seen the screen.

## If imagery is being captured this session

Session restore defaults to on and will silently reopen the last-used real
book: `defaults write com.hellotham.finvestlensapp finvestlens.reopenLastBook
-bool false` first, restore afterwards, and only ever capture the synthetic
demo book (`website/scripts/demo-book/`) — never `Ashley Bears.finvestlens` or
anything from `imports/`.
