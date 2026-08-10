---
name: preflight
description: Run the full FinvestLens pre-commit gate — every package suite, both platform builds, help-manual drift, SPDX headers — and report a pass/fail table. Use before any commit; "commit and push" implies it.
---

# Preflight — the pre-commit gate

Every step below must run and be reported. A step that was skipped is reported
as **SKIPPED with a reason**, never silently omitted, and never counted as a
pass. Claims carry receipts: quote the failing output verbatim.

## 1. Package suites

```bash
for p in Engine Persistence Interchange Quotes Rules Reports Intelligence FeatureUI CLI Lab; do
  swift test --package-path "Packages/$p" || break
done
swift test --package-path Packages/Shared --skip writeReadRoundTripThroughAppGroup
```

- The Shared `--skip` is mandatory: that test round-trips the real App Group
  container and can block forever on a wedged `containermanagerd`.
- If a run hangs: `pkill swiftpm-testing-helper` frees the `.build` lock.
- Live harnesses self-skip unless `FL_PERF_FILE` / `FL_FINLENS` are set — their
  skip lines are normal, not failures.

## 2. Both platform builds

```bash
xcodebuild build -scheme finvestlens -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme finvestlens -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Both must succeed. "Both platforms build" may only be reported when both
destinations actually ran (the Stop gate checks for exactly these two strings).

## 3. Help-manual drift

Run the generator and diff its output — do not merely report that
`HelpContent.swift` changed. An echoed reminder is not a check, and CI fails
on real drift:

```bash
(cd website \
  && before=$(shasum -a 256 src/data/manual.json) \
  && node scripts/build-manual.mjs >/dev/null \
  && [ "$before" = "$(shasum -a 256 src/data/manual.json)" ]) \
  && echo "manual.json in sync" \
  || echo "DRIFT — regenerating changed manual.json; stage the new file"
```

Compare the file against **its own regenerated output**, not against `HEAD`.
`git diff --exit-code src/data/manual.json` was the obvious spelling and it is
wrong: the file is legitimately modified-and-uncommitted in exactly the case
this step exists for — a `HelpContent.swift` change in the same working tree —
so it cried DRIFT on a tree that was perfectly in sync. A check that fails when
nothing is broken is a check people learn to skip.

Real drift means the regenerated file must be staged alongside the
`HelpContent.swift` change; CI fails on it.

## 3b. String catalogs match the compiler

The catalogs are gated in CI (`.github/workflows/ci.yml`, job
`localization`). Locally, when UI strings changed:

```bash
python3 scripts/check-localization.py --build
```

It builds both platforms with the extractor on, then reports keys the compiler
emits with no catalog entry, entries nothing emits, languages missing, and
translations whose `%` specifiers do not match the key's. That last one is a
crash, not a cosmetic defect. This is slow (two full builds) — skip it when no
user-facing string changed, and say so.

## 3c. No real financial data in published files

```bash
python3 scripts/check-no-real-data.py
```

`docs/` and `website/` are public; the reference book is one real household's
accounts. This flags any figure that looks like a balance rather than an
illustration — a million or more, or ten thousand-plus with cents — in the
published files. It exists because the hand-kept rule failed: a sweep on
10 Aug 2026 found net worth, super balance, portfolio value, realised gains,
taxable income and two account names in committed documentation, written there
over months as evidence that reports "matched GnuCash to the cent".

Keep the claim, drop the number. If a large figure genuinely is invented, mark
the line `<!-- synthetic -->`.

## 4. SPDX headers on changed Swift sources

```bash
git diff HEAD --name-only --diff-filter=AM | grep '\.swift$' | grep -v '^website/' \
  | xargs grep -L "SPDX-License-Identifier: GPL-3.0-or-later" 2>/dev/null
```

Empty output = pass. Any listed file needs the header before committing.

## 4b. What CI said about the last push

**Before pushing anything new, read the previous run.** A local preflight and
CI are not the same check, and the gap between them is the whole point of
having CI: this machine is UTC+10, the runner is UTC, and a test that
hard-coded a Sydney instant passed here and failed there. Nobody looked, so
the pipeline stayed red for **five consecutive commits** while every local
preflight came back green.

```bash
gh run list --limit 3
```

Red, or red on any earlier commit? Open it and get the actual failing test —
the summary alone does not say which:

```bash
gh run view <run-id> --log-failed | grep -oE '✘ Test "[^"]+"' | sort -u
```

Fix it before adding to the pile. A red pipeline you pushed through is not a
pre-existing condition, it is an unread message.

## 4c. After pushing, watch it go green

Pushing is not the end of the task; the run is.

```bash
gh run watch "$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status
```

Report the outcome. "Pushed" without the run's verdict is a claim with no
receipt — the same rule as everything else here.

## 5. Report, then stop

Produce a table: step → PASS / FAIL (with verbatim error) / SKIPPED (with
reason), then the verdict: **safe to commit** or **not safe, because …**.
Include what CI said about the previous push.

Do not commit as part of this skill. Committing is its own instruction, and the
repo's rules apply to it: straight to `main`, no feature branches, **no
Co-Authored-By or model-attribution trailers** (do not use `/commit-push-pr` —
it opens PRs, which this repo does not use).
