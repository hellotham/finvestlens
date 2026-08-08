---
name: ui-review
description: Execute the two mandatory FinvestLens review gates — accessibility and financial-data security — on recently changed UI code and report findings with receipts. Use before reporting any UI change as finished.
---

# UI review — the two gates, executed

CLAUDE.md ▸ Review gates says UI work is not done until both gates have been
**run and their findings reported**. This skill is the execution. "No issues"
without naming what was checked is the failure this skill exists to prevent.

## 0. Scope

```bash
{ git diff HEAD --name-only -- 'Packages/FeatureUI/**' 'finvestlens/**'
  git ls-files --others --exclude-standard -- 'Packages/FeatureUI/**' 'finvestlens/**'
} | grep '\.swift$'
```

Untracked files are part of the scope — brand-new views are exactly the ones
most likely to carry the findings (`git diff` alone silently skipped the two
new register files on this skill's first run). If the list is empty, review
the files changed in this conversation instead. Open every file in scope —
greps below locate candidates; the judgement happens in the file.

## 1. Accessibility gate

Check each item and record file:line evidence or "checked — none found":

- **Labels.** `rg -n "Image\(systemName:" <scope>` — every hit inside a
  `Button`/`Toggle`/tap target needs an `accessibilityLabel` (a bare symbol
  has none). `rg -n "accessibilityLabel" <scope>` to cross-check.
- **Dynamic Type.** `rg -n "Font\.system\(size:" <scope> | rg -v relativeTo` —
  fixed sizes break Dynamic Type (this is exactly how iOS lost it once).
  Custom text goes through `scaledFont` (Appearance.swift, 10pt floor).
- **Focus order.** SwiftUI derives Tab order from view order — fields must be
  declared in visual order (nesting a field in another column's stack broke
  Tab in the register).
- **Keyboard.** Everything the mouse can do is keyboard-reachable, and no
  shortcut is double-bound (`rg -n "keyboardShortcut" <scope> finvestlens/` —
  ⌘D was once bound to both Duplicate and Dashboard).
- **Colour.** `.tint` as ShapeStyle, never `Color.accentColor` (banned —
  hookify blocks new ones, but inspect conditionals); contrast on any custom
  colour; focus ring is a ring only, no fill (CLAUDE.md ▸ Theming).
- **Announcements.** Transient UI (toasts, progress) posts a VoiceOver
  announcement or is invisible to VoiceOver users.

## 2. Security gate (financial data handling)

- **No real data outbound.** `imports/` and `Ashley Bears.finvestlens` are real
  financial data. `rg -n "imports/" Packages finvestlens website --glob '!*.md'`
  and check nothing changed writes book contents into fixtures, screenshots,
  logs, or `website/`. Public imagery only from `website/scripts/demo-book/`.
- **Error strings.** For changed error/log messages: no account numbers,
  balances, or payee names in anything that could be surfaced or published.
- **Attachment paths.** New file-access code resolves inside the configured
  attachment roots — no book-supplied absolute path escapes (open finding H1;
  do not widen it).

## 3. Report

A findings list — `file:line`, what, severity — followed by the checklist with
each item marked found/none-found. Unverifiable items (needs VoiceOver on
hardware, needs a visual pass) are named as **unverified**, not passed. The
user does visual verification; this skill never claims on-screen results.
