---
name: relaunch
description: Build a signed macOS FinvestLens and relaunch it for the user's visual verification, releasing control immediately. Use after visual changes — the standing workflow is relaunch-and-release; the user does the looking.
---

# Relaunch — signed build, hand the app to the user

The standing instruction (given 24 Jul 2026): after changes, relaunch the app
and **release immediately** — the user verifies visually. Do not drive the GUI
with computer-use unless explicitly asked.

## 1. Quit any running copy — gracefully, and *wait for it*

```bash
osascript -e 'tell application "finvestlens" to quit' 2>/dev/null
for i in $(seq 1 30); do pgrep -x finvestlens >/dev/null || break; sleep 1; done
pgrep -x finvestlens >/dev/null && echo "DID NOT QUIT — see below" || echo "exited after ${i}s"
```

**`sleep 2` is not "it quit".** A quit Apple Event is *deferred while a modal
sheet is up*, so an app showing an alert never exits, the next `open` merely
re-activates the wedged instance, and the user is left with a dialog they did
not ask for and an app that will not close. This happened on 15 Aug 2026: the
app sat on "locked by another FinvestLens instance" and ignored three quit
events. Wait for the process to actually go.

If it does not exit, dismiss the modal and quit again — Escape cancels, which
never breaks a lock:

```bash
osascript -e 'tell application "finvestlens" to activate' \
  -e 'delay 1' \
  -e 'tell application "System Events" to tell process "finvestlens" to key code 53'
```

Read what the dialog says first, without stealing focus:

```bash
osascript -e 'tell application "System Events" to tell process "finvestlens" to get value of every static text of every sheet of every window'
```

One instance only. **Never `kill -9` by default**: the app holds an advisory
`.lock` beside the book, and a force-kill strands it — the next launch stops on
"locked by another FinvestLens instance". If a force-kill was truly
unavoidable, remove the stale `.lock` before relaunching. (The lock replaces the
extension rather than appending: `Ashley Bears.finvestlens` → `Ashley
Bears.lock`, `FileLock.swift:162` — so `ls *.finvestlens.lock` finds nothing and
proves nothing.)

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

Then check it actually opened the book before releasing — session restore can
land on an error sheet, and "relaunched" is not the same as "usable":

```bash
sleep 12
osascript -e 'tell application "System Events" to tell process "finvestlens" to get value of every static text of every sheet of every window'
```

Empty output is the pass. Anything else is a dialog the user would have had to
deal with — read it, fix the cause, and relaunch again. A stale
"locked by another instance" clears once the reaper removes the lock; the book
being intact can be confirmed without opening it:

```bash
sqlite3 "file:/path/to/Book.finvestlens?mode=ro&immutable=1" "pragma integrity_check;"
```

Then stop touching the machine. Report: built signed, relaunched, book opened
with no dialog — **visual result unverified; over to you.** That last clause is
the honest completion report; on-screen claims require having seen the screen.

## If imagery is being captured this session

Session restore defaults to on and will silently reopen the last-used real
book: `defaults write com.hellotham.finvestlensapp finvestlens.reopenLastBook
-bool false` first, restore afterwards, and only ever capture the synthetic
demo book (`website/scripts/demo-book/`) — never `Ashley Bears.finvestlens` or
anything from `imports/`.
