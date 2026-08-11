---
name: block-accent-color
enabled: true
event: file
action: block
conditions:
  - field: file_path
    operator: regex_match
    pattern: \.swift$
  - field: new_text
    operator: contains
    pattern: Color.accentColor
---

🚫 **`Color.accentColor` is banned in this app.**

Use `.tint` as a `ShapeStyle`, not `Color.accentColor` — see CLAUDE.md ▸ Theming.

**Why:** this app sets its theme with `.tint(…)` in `Appearance.swift` (lavender
by default, user-selectable). `Color.accentColor` does **not** read `.tint`. It
resolves `finvestlens/Assets.xcassets/AccentColor.colorset`, which is
deliberately empty, so it silently falls back to the *system* accent and draws
macOS blue into a purple app. The failure is invisible on a Mac whose system
accent happens to be blue, and it already cost a full round trip when a blue
focus ring was blamed on SwiftUI's `List` selection instead of on this call.

**Instead:**

```swift
.foregroundStyle(.tint)
.strokeBorder(.tint, lineWidth: 2)
.fill(.tint)
```

For a conditional, keep it a `ShapeStyle`:

```swift
.foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
```
