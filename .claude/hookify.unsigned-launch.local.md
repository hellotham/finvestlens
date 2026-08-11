---
name: unsigned-launch
enabled: true
event: bash
pattern: open\s+-a\s+.*finvestlens\.app|kill\s+-9
---

⚠️ **Two ways to lose time launching this app — check which one applies.**

**Launching:** a build made with `CODE_SIGNING_ALLOWED=NO` embeds *no
entitlements*, so it loses its `com.apple.security.application-groups` claim and
macOS asks "would like to access data from other apps" on **every** launch — the
ad-hoc signature changes each build, so TCC never remembers the grant. Use the
unsigned command only to check that it compiles. To run it:

```bash
xcodebuild build -scheme finvestlens -destination 'platform=macOS' -allowProvisioningUpdates
```

**`kill -9`:** the app holds an advisory lock beside the book
(`Ashley Bears.lock`). Force-killing leaves it behind, and the next launch stops
on "locked by another FinvestLens instance". Quit gracefully
(`osascript -e 'tell application "finvestlens" to quit'`) and give it time. If a
force-kill was genuinely unavoidable, remove the stale `.lock` before relaunching.
