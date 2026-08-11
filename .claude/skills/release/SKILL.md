---
name: release
description: Cut a signed, notarized, stapled FinvestLens DMG — version bump across all four places, build stamp, release notes, then scripts/release-dmg.sh and its verification. User-invoked only; it publishes.
disable-model-invocation: true
---

# Release — cut a distributable DMG

**Never run this without an explicit instruction to release.** The user held
1.1 deliberately (*"don't release it yet though"*), and a release is the one
action in this repo that reaches other people's machines.

## 0. The version lives in four places, and nothing checks they agree

Three `MARKETING_VERSION` entries in `finvestlens.xcodeproj/project.pbxproj`
(app, widgets, Quick Look) and one `VERSION=` in `scripts/stamp_build_info.sh`.
They are edited by hand, so they drift silently and the splash screen then
disagrees with the DMG:

```bash
grep -c "MARKETING_VERSION = $NEW;" finvestlens.xcodeproj/project.pbxproj   # expect 3
grep -n '^VERSION=' scripts/stamp_build_info.sh
```

Bump all four to the same value before anything else.

## 1. Preflight and CI must both be green

Run `/preflight` in full — every package suite, both platform builds, manual
drift, catalogs, SPDX, no-real-data. Then read what CI said about the last
push (`gh run list --limit 3`): a local pass and a runner pass are different
checks, and this repo has shipped five red commits without noticing before.

## 2. Stamp the build *after* the last commit

`scripts/stamp_build_info.sh` writes the current short SHA into
`finvestlens/BuildInfo.swift`. A commit cannot contain its own hash, so this
names the commit *before* it — stamp, commit the stamp, and accept that the
splash screen cites the parent. Re-stamp after any history rewrite: a stamp
naming a commit that no longer exists is worse than a stale one.

## 3. Release notes

Write them from the commit range, not from memory:

```bash
git log --format='%s' "$(git describe --tags --abbrev=0)"..HEAD
```

The same rule as commit messages applies — **no real balances**. The figures
gate does not read release notes, so this one is on you.

## 4. Build the DMG

```bash
scripts/release-dmg.sh                 # full: archive → notarize → staple → DMG
scripts/release-dmg.sh --skip-notarize # dry run: everything but the round trip
```

It signs with `Developer ID Application: Hello Tham Pty. Ltd. (RPL5R637DS)`
and notarizes through the `hellotham-notary` keychain profile. **The script
never handles the secret** — the app-specific password is stored once, by the
user, in their own terminal:

```bash
xcrun notarytool store-credentials "hellotham-notary" --apple-id "…" --team-id RPL5R637DS
```

If that profile is missing, the script says so and stops. Storing it is the
user's step, not yours: it prompts for a password.

## 5. Verify the artefact, do not assume it

```bash
xcrun stapler validate build/release/FinvestLens.dmg
spctl -a -t open --context context:primary-signature -v build/release/FinvestLens.dmg
```

Both must pass. "Notarized" is a claim about an event; these are its receipt.

## 6. Tag and publish

```bash
git tag -a "v$NEW" -m "FinvestLens $NEW"
git push origin "v$NEW"
```

The GitHub release attaches the DMG. Publishing it is an outward-facing act —
confirm before, not after.

## Report

Version (all four sites), preflight verdict, CI verdict, notarization and
staple results, the tag, and anything **not** run with its reason.
