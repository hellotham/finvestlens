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
Platforms, never a second New App). The version records it made said 1.0
and were edited to **1.2** on each platform's version page (11 Oct 2026), to
match `MARKETING_VERSION`; the build number is what TestFlight keys on.

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

```bash
scripts/upload-app-store.sh          # both platforms; or `macos` / `ios`
```

It archives each platform and uploads it with the team's **App Store Connect
API key** — the `.p8` in `~/.appstoreconnect/private_keys`, App Manager role
— rather than the Apple ID signed into Xcode. Xcode lost that account after
uploads twice on 19 Oct 2026: the upload refreshed the token, the next
`xcodebuild` logged "Invalid credentials in keychain … missing
Xcode-Username" and dropped the account, and the upload after it failed with
"Failed to Use Accounts". The key's ID comes from its file name, the issuer ID
from `ASC_ISSUER_ID` or `~/.appstoreconnect/issuer_id`; neither is kept in
this repository, which is public. Logs go to `build/archive-<platform>.log`
and `build/upload-<platform>.log`.

The Mac upload also needs a **Mac Installer Distribution** certificate, with
its private key, in this Mac's keychain (Xcode ▸ Settings ▸ Accounts ▸ the
team ▸ Manage Certificates ▸ + ▸ Mac Installer Distribution, once). Signed
in to Xcode as an Admin, the installer package was signed with Apple's
cloud-managed certificate; an App Manager key is refused that — "You haven't
been given access to cloud-managed distribution certificates" (checked
24 Oct 2026, when the iOS export with the key succeeded and validated with
"No errors" while the Mac export stopped there). Apple's own answer is a
local certificate: Xcode "will cloud sign … if … a local signing certificate
is not found" (*Cloud-managed certificates*, Apple Developer Account help).

Both exports use `destination: upload`, so the export step *is* the upload;
the build appears in App Store Connect ▸ TestFlight once Apple has processed
it (minutes), and the same build is attached to a version for review. The
script runs these, with `-authenticationKeyPath`, `-authenticationKeyID` and
`-authenticationKeyIssuerID` added to each:

```bash
# macOS
xcodebuild archive -scheme finvestlens -destination 'generic/platform=macOS' \
  -archivePath build/FinvestLens-macOS.xcarchive -skipPackagePluginValidation \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/FinvestLens-macOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-macOS.plist -exportPath build/export-macOS \
  -allowProvisioningUpdates
```

```bash
# iOS
xcodebuild archive -scheme finvestlens -destination 'generic/platform=iOS' \
  -archivePath build/FinvestLens-iOS.xcarchive -skipPackagePluginValidation \
  -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath build/FinvestLens-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore-iOS.plist -exportPath build/export-iOS \
  -allowProvisioningUpdates
```

`build/` is ignored by git. Run by hand without the key flags, they use the
Apple ID signed into Xcode instead (info@hellotham.com — see the Apple
Developer account note in the maintainer's memory, not the session's own
address).

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
    -parallel-testing-enabled NO -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
  ```

  `TEST_RUNNER_FL_SHOT_PERIOD` overrides the period (default: the previous
  financial year, where the demo book's postings are); `xcrun simctl
  status_bar <udid> override --time 9:41 …` sets the status bar. Sizes that
  App Store Connect asks for: iPad Pro 13" gives 2064×2752; **iPhone 18 Pro
  gives 1206×2622, the required "iPhone with Dynamic Island (medium
  display)" slot**; iPhone 18 Pro Max gives 1320×2868 for the optional large
  slot (Media Manager). `testTourCompactDestinations` (with
  `TEST_RUNNER_FL_TOUR=1`) captures every destination the phone can reach —
  the visual pass after a change to the compact shell. Since 12 Oct 2026 it
  also opens Settings (each of the five panes), Help, and the register's
  Actions menu, and asserts along the way: a step it cannot take fails the
  test. Before that a sheet it could not close left every later step to
  skip in silence, and the tour "passed" having toured half the app.
- **iPhone Duo** — its own tab since Xcode 27.1: the outer display
  1398×2034 px (2034×1398 landscape), the inner 2007×2853 (2853×2007).
  Optional for now, and they put an "optimized for iPhone Duo" badge on the
  product page; Apple's *Screenshot specifications*: "Starting in April 2027,
  screenshots will be required for any app using the iOS 27.1 SDK or later"
  — which is every build since 27.1. The iPhone Duo simulator boots folded,
  at the outer size. The inner display needs Device Hub's open control:
  neither `simctl` nor XCTest can set a pose (checked 24 Oct 2026), so the
  open set is captured by hand there.
- **Uploading** — version page ▸ *App Previews and Screenshots* ▸ device
  tab; each zone's file input takes the whole set (under 10 MB a call) and
  saves itself; thumbnails keep upload order, so name files `01-…`. There is
  no icon upload: the product page takes the icon from the build attached
  under *Build*.

The sets are written to `screenshots/app-store/` (`mac`, `ipad`, `iphone-6.3`,
`iphone-6.9`). That folder is git-ignored: the PNGs come to 14 MB, about the
size of the whole repository, and the recipe above regenerates them.

## App Accessibility (the accessibility nutrition labels)

App Store Connect ▸ App Accessibility asks, per device, which of nine
features the app supports. Apple's bar (developer.apple.com/help/app-store-
connect/manage-app-accessibility/, read 18 Oct 2026) is that a person can
complete **all the common tasks** with the feature, and a label that does not
meet it is misleading metadata (Guideline 2.3). The owner's rule: declare only
what was verified.

The evidence comes from Xcode's accessibility audit run over the same tour the
screenshots take: `TEST_RUNNER_FL_AUDIT=1` makes `ScreenshotTests` audit every
screen it captures and write `audit.txt` beside the images (contrast, element
detection, hit regions, descriptions, Dynamic Type, clipped text, traits), and
`testAuditWelcome` adds the first-launch screen. Set the simulator first:
`xcrun simctl ui <udid> appearance dark` and `… content_size
accessibility-extra-extra-extra-large`. The audit tries other text sizes on
the app as it runs, so run a tour's assertions without it when they are what
is being checked.

Declared for 1.2, on iPhone, iPad and Mac:

- **Dark Interface** — the app follows the system appearance or its own
  setting; every iPhone and iPad screen captured in dark mode (62) measured
  dark from its pixels (mean luminance 5–49 of 255, at most 1.1% bright
  pixels). The Financial Review slides, the Passport page and the check
  preview are drawn as paper, light, and are not common tasks. Mac: the same
  views plus the register's semantic AppKit colours (by reading the code).
- **Reduced Motion** — nothing in the app spins, zooms, parallaxes or
  advances on its own: its only animations are fades, a toast's short slide
  and the system's own transitions (by reading every animation site).

Not declared, and why:

- **Larger Text** — at the largest accessibility size the Overview's charts
  overlap their own axis labels, the statements' Note column breaks a letter
  to a line, and the phone tour cannot reach a holding's row. (The welcome
  screen and the register do scale.)
- **Sufficient Contrast** — the audit found 150 contrast failures on the
  iPad's screens, among them the welcome screen's title, tagline and buttons,
  and toolbar buttons in the lavender accent on glass.
- **Differentiate Without Color Alone** — the Overview's allocation donut,
  performance lines and cash-flow bars tell series apart by colour alone, with
  no legend.
- **VoiceOver, Voice Control** — Apple asks for proficient testing with each
  on every device, which has not been done.
- **Captions, Audio Descriptions** — the app has no video or audio.

## What a sandboxed FinvestLens does differently

- A book opened before the sandbox reopens only after it is opened once
  through the panel, a drag or Finder (that stores a security-scoped
  bookmark); the same for the two document folders in Settings.
- The audit trail beside a book is now `<Book>.audit`; an older
  `<Book>.finvestlens.audit.log` stays in place, unread.
- Lock refusals are no longer silent: `/usr/bin/log show --predicate
  'subsystem == "com.hellotham.finvestlens"' --info` names the error.
