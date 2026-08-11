---
name: ui-review-gates
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: FinvestLensUI/(Register|Transaction|Views|AccountField|.*View)\w*\.swift$
  - field: new_text
    operator: regex_match
    pattern: (TextField|Button|List|Table|\.focused|onTapGesture|foregroundStyle)
---

♿️ **UI surface touched — the review gates apply (CLAUDE.md ▸ Review gates).**

Run **`/ui-review`** before reporting this change as finished — it executes
both gates below and demands file:line receipts. These are not optional and
not "when asked twice":

**Accessibility**
- Every non-text control has a VoiceOver label. A bare `Image(systemName:)`
  inside a `Button` has none.
- Focus order matches visual order. SwiftUI derives Tab order from *view* order,
  so a field nested inside another column's stack tabs out of sequence — that is
  exactly how the notes fields broke Tab in the register.
- Text uses `scaledFont`, not a fixed size.
- Any custom colour is checked for contrast; anything reachable by mouse is
  reachable by keyboard.

**Security / data handling**
- Nothing from `imports/` or a real book reaches fixtures, screenshots, logs or
  the website.
- No account numbers, balances or payee names in error strings that get
  surfaced or published.

State what you checked. "No accessibility issues" without having looked is the
thing this rule exists to stop.
