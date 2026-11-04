# Demo book generator

Builds a synthetic `.finvestlens` book for screenshots and marketing.

**Why this exists:** the app's screenshots must never show real financial data.
This generates an entirely invented book — invented employer, payees, balances,
holdings and an invented index — that is large and varied enough for the
dashboard, register and reports to look like real use: sixteen months of everyday
life to the end of October 2026, daily prices from July 2024 so Price History has
averages, crosses and a benchmark, franked distributions, and two parcels sold
(one held over twelve months, one under) so Capital Gains has both to show. Move
the end date forward when the screenshots are retaken, or the current financial
year reads empty.

```bash
swift run --package-path website/scripts/demo-book demo /tmp/Demo.finvestlens
open -a finvestlens /tmp/Demo.finvestlens
```

Two things to know before capturing screenshots:

- The app reopens the last book on launch. Set
  `finvestlens.reopenLastBook` to `false` in its defaults first, or it will
  restore your real book over the demo — then put the setting back.
- The book balances to exactly zero at cost (`finlens -f … bal -B`), which is
  worth re-checking after any edit to the generator.

## Screenshots

Both appearances ship (`-light.png` / `-dark.png`), and `Screenshot.astro`
swaps them on the reader's colour scheme. Take them from the release app, on
this book, with launch arguments, so that nothing is written to the app's
settings to choose them:

```bash
BOOK=/tmp/Demo.finvestlens   # the standardized path: no /private in front
NAV='{"mode":"dashboard","tabs":{"accounts":["generalLedger"],"reports":["report:Income Statement","report:Capital Gains","report:Price History"]},"selections":{},"active":{"accounts":1,"reports":1}}'
open -a /Volumes/FinvestLens/FinvestLens.app "$BOOK" --args \
  -finvestlens.reopenLastBook NO -ApplePersistenceIgnoreState YES \
  -appearance.colorScheme light \
  "-session.navigation:$BOOK" "\"${NAV//\"/\\\"}\"" \
  "-session.period:$BOOK" "<$(printf '%s' '{"last12Months":{}}' | xxd -p | tr -d '\n')>"
```

- An argument's value is read as a plist, so the JSON is quoted as a plist string
  and `Data` is given as `<hex>`. Tab 0 in Reports is All Reports, so `active`
  counts from there.
- Walk the destinations with **targeted menu clicks** through System Events:
  View ▸ Accounts, View ▸ Reports, View ▸ Next Tab. Keystrokes land wherever
  the person at the Mac is typing.
- `screencapture -l<windowID> -o -x` works on a window on another desktop
  (find the id with `CGWindowListCopyWindowInfo(.optionAll)`). An inactive
  window greys its bars and buttons, and `open -a` from the background does not
  activate it: `set frontmost of process "finvestlens" to true` before each one.
- The run still saves window and split-view frames to the app's settings. Export
  them first and restore them after: `defaults export` and `defaults import`.
- A capture comes out at 2560×1640 in Display P3 at up to 1.4 MB. Compress it
  with `sharp` from `website/node_modules`, which converts to sRGB as it goes:
  `sharp(file).png({ palette: true, quality: 95, effort: 10, dither: 0.6 })`.
  It takes a fifth of the size, and a colour compared against ColorSync's own
  conversion comes out the same.

The phone images are `testCaptureStoreScreenshots` (`docs/app-store.md` ▸
Screenshots) on this book, with `TEST_RUNNER_FL_SHOT_PERIOD='{"last12Months":{}}'`,
scaled to 804 wide with `sips` and compressed the same way.

## Social card

`website/scripts/og-card.swift` regenerates `public/images/og-card.png`
(1200×630):

```bash
swiftc -O website/scripts/og-card.swift -o /tmp/ogcard
/tmp/ogcard website/public/images/icon-256.png website/public/images/og-card.png
```
