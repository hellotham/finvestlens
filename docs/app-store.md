# App Store Connect & TestFlight runbook

> Started 11 Oct 2026. The App Store Connect record exists; this is the recipe
> for getting a build onto TestFlight and, later, into review. The DMG path
> (`scripts/release-dmg.sh`, Developer ID, notarised) is separate and
> unchanged — the two distribution channels sign differently and the export
> option files are not interchangeable.

## The record

| Field | Value |
|---|---|
| App Store Connect App ID | `6821468191` |
| Platforms | iOS and macOS, one record (universal purchase) |
| Name | FinvestLens |
| Primary language | English (Australia) |
| Bundle ID | `com.hellotham.finvestlens` (extensions `…finvestlens.FinvestLensWidgets`, `…finvestlens.FinvestLensQuickLook`) |
| SKU | `FINVESTLENS-001` |
| User access | Full Access |
| Team | Hello Tham Pty. Ltd., `RPL5R637DS` |

Created from App Store Connect ▸ Apps ▸ ＋ ▸ New App with every platform
ticked at creation (adding one later goes through App Information ▸
Platforms, never a second New App). The version records it made say 1.0;
the build number is what TestFlight keys on, and the App Store version is
edited on the version page before submission.

## What the build has to carry

- **App Sandbox on every target** (`ENABLE_APP_SANDBOX = YES`): the Mac App
  Store and macOS TestFlight require it. The entitlements and the
  related-item declarations for the `.lock` and `.audit` sidecars are in
  [provisioning.md](provisioning.md) § App Sandbox; the sidecars' types must
  stay `CFBundleTypeRole = Editor` or the sandbox grants them read-only.
- `ITSAppUsesNonExemptEncryption = false` in `finvestlens/Info.plist`, so
  App Store Connect does not ask about export compliance on every upload.
- Automatic signing with the **Apple Distribution** certificate (present in
  the keychain; `security find-identity -v -p codesigning`).
- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.pbxproj`: every
  upload needs a build number App Store Connect has not seen for that
  version. Bump `CURRENT_PROJECT_VERSION` before each upload.

## Archive and upload

Both exports use `destination: upload`, so the export step *is* the upload;
the build appears in App Store Connect ▸ TestFlight once Apple has processed
it (minutes), and the same build is attached to a version for review.

```bash
# macOS
xcodebuild archive -scheme finvestlens -destination 'generic/platform=macOS' \
  -archivePath build/FinvestLens-macOS.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/FinvestLens-macOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-macOS.plist -exportPath build/export-macOS \
  -allowProvisioningUpdates
```

```bash
# iOS
xcodebuild archive -scheme finvestlens -destination 'generic/platform=iOS' \
  -archivePath build/FinvestLens-iOS.xcarchive -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/FinvestLens-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-iOS.plist -exportPath build/export-iOS \
  -allowProvisioningUpdates
```

`build/` is ignored by git. The upload uses the Apple ID signed into Xcode
(info@hellotham.com — see the Apple Developer account note in the
maintainer's memory, not the session's own address).

## After the upload

1. App Store Connect ▸ the app ▸ TestFlight: the build is "Processing", then
   ready. A build that fails processing shows the reason there and in email.
2. Internal testers see it at once; external groups need Beta App Review.
3. Before a version goes to review: screenshots per platform, the
   description, keywords, the privacy nutrition labels (App Privacy), the age
   rating, and the review notes. HelloNotes' `docs/app-store-listing.md` is
   the model for keeping that copy in a file the tests can check.

## What a sandboxed FinvestLens does differently

- A book opened before the sandbox reopens only after it is opened once
  through the panel, a drag or Finder (that stores a security-scoped
  bookmark); the same for the two document folders in Settings.
- The audit trail beside a book is now `<Book>.audit`; an older
  `<Book>.finvestlens.audit.log` stays in place, unread.
- Lock refusals are no longer silent: `/usr/bin/log show --predicate
  'subsystem == "com.hellotham.finvestlens"' --info` names the error.
