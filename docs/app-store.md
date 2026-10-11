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

## Screenshots

Every image comes from the synthetic book: `website/scripts/demo-book`
writes `Demo.finvestlens` (its `Package.swift` needs the current macOS
platform). Never a real book, never `imports/`.

- **Mac** — launch the dev app on the demo book with session restore off
  (`defaults write com.hellotham.finvestlens finvestlens.reopenLastBook -bool
  false`; the sandboxed app reads its container's defaults, and `defaults`
  writes there), size the window to 1280×800 pt and capture it with
  `screencapture -l<windowID> -o -x` — 2560×1600 on a Retina display, one of
  the accepted Mac sizes. ⌘1…⌘7 switch modes; to select a sidebar row from
  a script use the accessibility API (`set selected of row N of outline 1 …`
  in System Events) — a synthetic click toggles chevrons and presses cards
  but never selects a row.
- **iPad and iPhone** — `finvestlensUITests/ScreenshotTests` drives a
  simulator and writes full-resolution PNGs. Nothing is seeded into the
  simulator: the test opens a private copy of the book and hands the app its
  path and the reporting period as launch arguments, which `UserDefaults`
  reads ahead of anything stored.

  ```bash
  TEST_RUNNER_FL_SHOT_DIR=/path/to/shots \
  TEST_RUNNER_FL_SHOT_BOOK=/path/to/Demo.finvestlens \
  xcodebuild test -project finvestlens.xcodeproj -scheme finvestlens \
    -destination 'platform=iOS Simulator,id=<udid>' \
    -only-testing:finvestlensUITests/ScreenshotTests/testCaptureStoreScreenshots \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
  ```

  `TEST_RUNNER_FL_SHOT_PERIOD` overrides the period (default: the previous
  financial year, where the demo book's postings are); `xcrun simctl
  status_bar <udid> override --time 9:41 …` sets the status bar. Sizes that
  App Store Connect asks for: iPad Pro 13" gives 2064×2752; **iPhone 18 Pro
  gives 1206×2622, the required "iPhone with Dynamic Island (medium
  display)" slot**; iPhone 18 Pro Max gives 1320×2868 for the optional large
  slot (Media Manager). `testTourCompactDestinations` (with
  `TEST_RUNNER_FL_TOUR=1`) captures every destination the phone can reach —
  the visual pass after a change to the compact shell.
- **Uploading** — version page ▸ *App Previews and Screenshots* ▸ device
  tab; each zone's file input takes the whole set (under 10 MB a call) and
  saves itself; thumbnails keep upload order, so name files `01-…`. There is
  no icon upload: the product page takes the icon from the build attached
  under *Build*.

The sets are written to `screenshots/app-store/` (`mac`, `ipad`, `iphone-6.3`,
`iphone-6.9`). That folder is git-ignored: the PNGs come to 14 MB, about the
size of the whole repository, and the recipe above regenerates them.

## What a sandboxed FinvestLens does differently

- A book opened before the sandbox reopens only after it is opened once
  through the panel, a drag or Finder (that stores a security-scoped
  bookmark); the same for the two document folders in Settings.
- The audit trail beside a book is now `<Book>.audit`; an older
  `<Book>.finvestlens.audit.log` stays in place, unread.
- Lock refusals are no longer silent: `/usr/bin/log show --predicate
  'subsystem == "com.hellotham.finvestlens"' --info` names the error.
