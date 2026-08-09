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

```bash
git diff HEAD --name-only | grep -q "HelpContent.swift" \
  && echo "HelpContent changed → run: (cd website && node scripts/build-manual.mjs) and commit src/data/manual.json" \
  || echo "no help changes"
```

CI fails if `manual.json` drifts from `HelpContent.swift`.

## 4. SPDX headers on changed Swift sources

```bash
git diff HEAD --name-only --diff-filter=AM | grep '\.swift$' | grep -v '^website/' \
  | xargs grep -L "SPDX-License-Identifier: GPL-3.0-or-later" 2>/dev/null
```

Empty output = pass. Any listed file needs the header before committing.

## 5. Report, then stop

Produce a table: step → PASS / FAIL (with verbatim error) / SKIPPED (with
reason), then the verdict: **safe to commit** or **not safe, because …**.

Do not commit as part of this skill. Committing is its own instruction, and the
repo's rules apply to it: straight to `main`, no feature branches, **no
Co-Authored-By or model-attribution trailers** (do not use `/commit-push-pr` —
it opens PRs, which this repo does not use).
