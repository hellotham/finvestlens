# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

FinvestLens is a native Apple double-entry accounting app (macOS 26 / iPadOS 26 / iOS 26): a clean Swift reimplementation of the GnuCash accounting model with its own SQLite document format (`.finvestlens`, via GRDB), GnuCash XML and Ledger 3 journals as round-trip interchange formats, and `finlens`, a strictly read-only ledger-modelled CLI. GPL-3.0-or-later, published by Hello Tham.

## Commands

Everything needs Swift 6.2 (Xcode 26). Eleven local SPM packages live under `Packages/`; each builds and tests on its own.

```bash
swift test --package-path Packages/Engine                      # one package's suite
swift test --package-path Packages/Engine --filter AutoClearTests   # one suite or test
```

The full pre-commit sweep:

```bash
for p in Engine Persistence Interchange Quotes Rules Reports Intelligence FeatureUI CLI Lab; do
  swift test --package-path "Packages/$p" || break
done
swift test --package-path Packages/Shared --skip writeReadRoundTripThroughAppGroup
```

The Shared `--skip` matters: that test round-trips through the real App Group container and can block forever on a wedged `containermanagerd`. If a test run hangs, `pkill swiftpm-testing-helper` also frees the `.build` lock. Every suite uses Swift Testing (`@Test` / `#expect`) — there is no XCTest anywhere.

The app (both platforms must build before committing):

```bash
xcodebuild build -scheme finvestlens -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme finvestlens -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Those are build-only checks. To **run** the macOS app, build it signed instead:

```bash
xcodebuild build -scheme finvestlens -destination 'platform=macOS' -allowProvisioningUpdates
```

`CODE_SIGNING_ALLOWED=NO` embeds no entitlements at all, so the app loses its
`com.apple.security.application-groups` claim — and `publishWidgetData()` touches
`~/Library/Group Containers/…` on every open, save and close. macOS reads that as one app
reading another's data and puts up "would like to access data from other apps"; the ad-hoc
signature changes with every build, so TCC forgets the grant and asks again every launch.

The CLI builds with `swift build -c release --package-path Packages/CLI` (binary at `Packages/CLI/.build/release/finlens`); [docs/cli.md](docs/cli.md) is its manual. It is read-only **by design** — never add a command that writes to a book.

Everything headless that *writes* belongs to **`finlab`** instead (`Packages/Lab`, binary at `Packages/Lab/.build/release/finlab`, manual in [docs/lab.md](docs/lab.md)): GnuCash→book import, price refresh, document ingestion, and the open/save benchmarks. It is the only package that depends on `FeatureUI`, deliberately — it drives the real `AppModel`, so a maintenance run exercises the same matching and categorisation code the app does instead of a copy that can drift.

Website (`website/`, Astro 7 + Tailwind 4, served at `hellotham.com/finvestlens/`): `npm ci`, then `npm run dev` / `npm run build`. After editing the in-app help (`Packages/FeatureUI/Sources/FinvestLensUI/HelpContent.swift`), run `node scripts/build-manual.mjs` in `website/` and commit the regenerated `src/data/manual.json` — CI fails if it drifts. The site serves under the `/finvestlens` base path: route every internal href and asset through `url()` from `src/data/site.ts`, never a bare absolute path (those 404 on Pages).

Release DMG: `scripts/release-dmg.sh` (archive → notarize + staple the app → build, sign, notarize + staple the DMG; uses the `hellotham-notary` keychain profile).

Live harnesses in the FeatureUI test target skip themselves unless env vars are set: `FL_PERF_FILE=/path/to/Book.finvestlens` enables the real-book perf/report/planning/round-trip harnesses; `FL_FINLENS=/path/to/finlens` points the CLI parity tests at a built binary.

## Architecture

- **Dependencies point strictly downward.** `Engine` (pure accounting model — no UI or persistence imports) sits under `Persistence` (GRDB document store, NAS locking), `Interchange` (GnuCash XML, Ledger, bank-statement importers + the import matcher), `Quotes`, `Rules`, and `Reports`; `Intelligence` and `FeatureUI` (all SwiftUI surfaces) sit above those; the app target is a thin shell over `FeatureUI`. `Shared` holds App Group/widget plumbing; `CLI` wraps Engine + Persistence + Interchange read-only.
- **The in-memory `Book` is the source of truth.** Everything on screen derives from it, invalidated by `derivedRevision`; expensive derivations (report functions, register rows, autocomplete) are memoised on that revision. Pass stable parameters to memoised report calls — a live `Date()` in the key defeats the cache.
- **Undo captures only what an edit is about to change** — never whole-book snapshots.
- **Two invariants never move:** every transaction's splits balance to zero, and GnuCash XML round-trips losslessly (import → export → re-import → export is byte-identical).
- **`docs/` is the spec spine:** `prd.md` (numbered requirements), `architecture.md` (numbered decisions), `plan.md` (phases with exit criteria), `implemented.md` (what was built), `deferred.md` (what was consciously *not* built, with reasons). Check `deferred.md` before treating a missing feature as a gap — several absences are decisions, not oversights.
- **GnuCash is the correctness oracle, not our tests.** Ported behaviour is verified against GnuCash's own C/C++ source (the maintainer keeps a sparse checkout at `~/Repositories/gnucash-reference`) and against GnuCash 5.16's reports on a real book, to the cent.

## Localization

The single string catalog lives in the **app target** (`finvestlens/Localizable.xcstrings`) — SwiftUI resolves package `Text()` against `Bundle.main`, so package code needs no bundle plumbing (the Quick Look extension has its own catalog). Eight languages. The authority for the key set is the compiler: `swift build -Xswiftc -emit-localized-strings` output, not grep. Two traps silently opt strings out of localization: string concatenation inside `Text(...)` (picks the verbatim `String` initializer, emits no key) and helper parameters typed `String` where `LocalizedStringKey` is meant.

## Working rules

These are not preferences. Each one is here because it was broken, at cost.

- **A direct instruction is the task.** "Redesign it", "research X", "consult the
  GnuCash source", "check the HIG" are the work itself, not context for it. Do not
  substitute a smaller change you are more confident of. If an instruction seems
  wrong, say so in one sentence and then carry it out.
- **Never cite a source you have not opened in this session.** Naming GnuCash,
  the HIG, or any document from memory and presenting it as research is a
  fabrication. Open it, quote it, link it.
  - GnuCash: `~/Repositories/gnucash-reference`. It is a **sparse** checkout —
    the register UI is not there by default. `git sparse-checkout add
    gnucash/register` first. The register's own design is in
    `gnucash/register/ledger-core/split-register-layout.c`.
  - Apple HIG: `developer.apple.com/design/human-interface-guidelines/…` is
    JavaScript-rendered. `WebFetch` returns the page *title only* and nothing
    else — that is not a failed fetch, it is a silent empty one. Use the Browser
    pane (`preview_start` with the URL, then `get_page_text`).
- **Prove a diagnosis before asserting it, especially when blaming a framework.**
  "SwiftUI's List does that" is the shape of an excuse. Check this app's own
  values first — a wrong colour, size or spacing is nearly always ours. Saying
  "the list draws that blue selection" when the blue was `Color.accentColor` in
  our own view cost an entire round trip and was said twice.
- **Report only what was observed.** "Verified" means run and seen. If the GUI
  could not be driven, say the change is unverified and name what needs trying.
- **A prohibition binds everything you delegate.** A subagent inherits none of
  this conversation: it has the same tools and none of the instructions. Every
  constraint the user has set — no chips, do not touch `imports/`, do not commit,
  read-only — must be restated *inside the subagent's prompt*, because nothing
  else will carry it there. This was learned the hard way: chips were forbidden
  and two still appeared — the transcript shows the main loop itself spawned
  one and a delegated agent the other. A `PreToolUse` gate
  (`.claude/hooks/no-chips.py`) now blocks that tool wherever it is invoked,
  because a `Stop` hook reads only *this* session's transcript and a subagent's
  tool calls never appear in it — a rule that cannot be enforced where the work
  happens is not enforced at all.
- **A claim carries its receipt.** "Builds", "tests pass", "verified",
  "committed", "consulted X" are reports of events. Make them only in the same
  turn as the command or observation that proves them, and name what was *not*
  run ("iOS build not attempted", "unverified on screen — needs a look"). One
  session wrote "verified" 96 times; the handful that were false — sources
  cited from memory, GUI behaviour never seen — are why the user now checks.
- **Directives do not expire.** An instruction from three turns ago that was
  never carried out is still the task. A turn may only end by doing it or by
  saying explicitly "X remains undone because Y" — silence is a false
  completion report.
- **Interrogate a refusal before making it — five whys, not a checklist.**
  Every refusal in the 11 Aug 2026 session was wrong, and the user had to push
  through each one to reach work that was always possible. The failure was
  never *which* reason; it was stopping at the first one, so a list of known
  excuses is the wrong fix — it only teaches the next session to pattern-match.
  Ask instead: why did it fail, and why is *that* true? At each level, can this
  cause be fixed, overridden, or routed around? Every answer is a tool call;
  an untested reason is a guess wearing a fact's clothes. Descend until the
  cause is a **decision rather than an obstacle** — needing the user's
  authority rather than more effort, which in practice means acting as the user
  or destroying something outward-facing. Then put that decision to them with
  `AskUserQuestion` and the facts that settle it. Never narrate the wall.

Enforcement for all of the above lives in `.claude/settings.json`:
`directive-checklist.py` restates directives at prompt time,
`check-directives.py` blocks a stop that skipped a directive (scanning the last
five user turns) or asserted unevidenced work, `check-docs.py` blocks a stop
where source changed and no specification document did, `check-no-deferrals.py`
blocks a stop that ends with work named but not done — offers, skip words, and
the residual-work report (a section headed *what's still broken*), a shape that
needs no deferral vocabulary at all — `no-chips.py` blocks chips
everywhere including subagents, `no-figures-in-commits.py` blocks a commit
message carrying a real balance (by size, or by any amount on a line naming
the real book), and the `hookify.*.local.md` rules gate
`Color.accentColor`, unsigned launches, UI review gates, and framework-blame.
These gates are the user's, not yours: never weaken or bypass one except on an
explicit instruction, and treat a rejection as a defect list, not an obstacle.

Two things they deliberately allow, because the alternative is a gate people
route around. A **blocker stated next to the item it blocks** passes
`check-no-deferrals.py` ("X remains undone because Y" — the sibling gate
*requires* exactly this); a blocker far from the item does not, since one honest
sentence must not excuse a whole list. And **quoted, code-spanned and
emphasised text is not searched at all**, so discussing the gates does not trip
them — a detector that cannot tell use from mention fires on every conversation
about itself.

**Handing the user work you could do yourself is blocked, and a blocker phrase
does not excuse it.** "That's your call", "you can add a permission rule", "run
it yourself" — these read as deference and land as deferrals, and because
*"your call"* is itself blocker-shaped, the blocker exemption used to wave them
straight through. A handoff now clears the gate only on a **receipt**: an
actual refusal recorded in this turn's *tool results* (a permission denial, a
hook block), or the on-screen check the user has always done themselves. The
receipt cannot come from the assistant's own prose — writing "permission rule"
once satisfied the very rule it tripped. **A blocked tool is not a blocked
task:** exhaust the alternatives before reporting a wall.

A denial on its own is no longer enough, because a real one was used to excuse
a wall that was not there: the receipt now only clears the gate when the turn
*also* shows at least two tool calls **after** the refusal. Trying another way
is what turns a refusal into a finding; stopping at the first one is the
behaviour the receipt was meant to prevent, not license.

After editing any hook, run its regression suite — 34 cases, both directions,
every mention marker and every real deferral shape that has actually been seen:

```bash
python3 .claude/hooks/test-gates.py
```

## Theming

The app's colour is set with `.tint(…)` in `Appearance.swift` — lavender by
default, user-selectable. **`Color.accentColor` is banned in this codebase.** It
does not read `.tint`; it resolves `Assets.xcassets/AccentColor.colorset`. That
colorset is now **filled with lavender** — not for code to read, but because it
is the only thing that recolours what the *system* draws (list/table selection
emphasis, focus rings, default buttons), which otherwise painted macOS blue
into a purple app. It is static: a user-selected in-app accent moves `.tint`
but not the system-drawn parts. In code, use `.tint` as a `ShapeStyle`
(`.foregroundStyle(.tint)`, `.strokeBorder(.tint, …)`, `.fill(.tint)`), or
`Color.appAccent` where a concrete `Color` is required — never
`Color.accentColor`.

Inline editing follows the HIG pages quoted above: a cell at rest carries no
border and no fill; focus adds a ring and nothing else. A field must occupy the
same box in both states, or the row moves when it is edited. Placeholder text is
not a label — HIG *Text fields*: "it can also be useful to include a separate
label describing the field".

## Review gates

UI work is not done until both have been run and their findings reported:

- **Accessibility** — VoiceOver labels on every non-text control, focus order
  matching visual order, Dynamic Type via `scaledFont`, contrast on any custom
  colour, keyboard reachability for anything the mouse can do.
- **Security** — for this app that is mainly data handling: never let `imports/`
  or a real book reach fixtures, screenshots, logs or the website; no financial
  data in error messages that get published.

Run them before saying a change is finished, not when asked twice.

## Skills

Project skills live in `.claude/skills/`. These mappings are standing
instructions — when the moment arrives, invoking the skill *is* the requested
work, not extra scope:

- **`/preflight`** before every commit — package suites, both platform builds,
  help-manual drift, SPDX. "Commit and push" implies it.
- **`/ui-review`** before reporting any UI change finished — executes both
  Review gates above with file:line receipts.
- **`/relaunch`** after visual changes — signed build, graceful quit, relaunch,
  release immediately; the user does the looking.
- **`/code-review`** after a substantive implementation, scaled to the change.
  `/code-review ultra` (cloud, multi-agent, billed) is **user-triggered only**:
  suggest it before releases; never attempt to launch it.
- Useful installed extras: the `code-simplifier` agent after large
  implementations; `/feature-dev` for multi-file features; `frontend-design`,
  `tailwind-4`, and `seo-audit` apply to `website/` only, never the app.
  Avoid `/commit-push-pr` — it opens PRs and this repo commits straight to
  `main`.

## Conventions

- Every Swift source in `Packages/`, the app target, and the extensions carries `// SPDX-License-Identifier: GPL-3.0-or-later` — CI gates exactly those roots; the `website/scripts/` tooling sits outside the gate.
- Commit straight to `main` — no feature branches, no Co-Authored-By or model-attribution trailers. Run the package suites and both app builds first.
- After adding or changing `Engine` types, clear dependent packages' `.build` directories and the app's DerivedData `Build` folder — stale module caches will happily link old package code.
- `imports/` (real bank exports) and `Ashley Bears.finvestlens` (a real book used as the standard manual-test fixture; changes to it may be left permanent) are gitignored **real financial data**: never commit them and never let their contents reach fixtures, screenshots, or the website. Public imagery comes from the synthetic generator in `website/scripts/demo-book/`. Before capturing app imagery, disable session restore (`defaults write com.hellotham.finvestlensapp finvestlens.reopenLastBook -bool false`, restore afterwards) — it defaults to on and will silently reopen the last-used real book over a demo book.
