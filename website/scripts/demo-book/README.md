# Demo book generator

Builds a synthetic `.finvestlens` book for screenshots and marketing.

**Why this exists:** the app's screenshots must never show real financial data.
This generates an entirely invented book — invented employer, payees, balances
and holdings — that is large and varied enough for the dashboard, register and
reports to look like real use.

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
