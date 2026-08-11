---
name: verify-before-blaming-framework
enabled: true
event: prompt
conditions:
  - field: user_prompt
    operator: regex_match
    pattern: (still|again|not working|no longer|nothing happens|broken|keeps|multiple attempts|failed|does ?n'?t\s+(work|make|do|open|show|appear)|does not\s+(work|make|do|open|show|appear))
---

🔁 **A repeat failure is being reported. Do not explain it from memory.**

This fires when the user says something is *still* wrong. Every time that
happened in this project, the reflex was to attribute the defect to a framework
— "SwiftUI's `List` swallows the click", "the `List` draws that blue selection"
— and every time the cause was in this app's own code. The blue was
`Color.accentColor` in our view. The slowness was two O(140,000) passes per body
update in our own computed properties.

**Before writing a single word of explanation:**

1. **Check our values first.** Grep for the actual colour, width, or call in
   `Packages/` and `finvestlens/`. A wrong colour, size, or spacing is nearly
   always ours, not the platform's.
2. **Reproduce or measure.** Read the code path that produces the symptom. If
   claiming a performance cause, name the specific line and its complexity.
3. **Only then** name a framework — and say what you checked that rules our own
   code out.

If the previous attempt failed, do not retry a variation of it without first
naming *why* it failed. Three attempts at click-to-edit failed in a row because
the same wrong assumption was re-applied each time.
