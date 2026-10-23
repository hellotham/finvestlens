#!/bin/zsh
#
#  upload-app-store.sh — archive FinvestLens and upload it to App Store
#  Connect with the team's App Store Connect API key, not the Apple ID
#  signed into Xcode.
#
#  Usage: scripts/upload-app-store.sh [macos|ios|both]      (default: both)
#
#  Why the key: Xcode drops its signed-in Apple Account after an upload
#  refreshes the token — the next xcodebuild logs "Invalid credentials in
#  keychain … missing Xcode-Username", prunes the account, and the upload
#  after it fails with "Failed to Use Accounts" (19 Oct 2026, twice). The
#  key needs no sign-in and is not lost that way.
#
#  The key is the .p8 in ~/.appstoreconnect/private_keys, where Apple's
#  tools look for it; its ID comes from ASC_KEY_ID or the file's name
#  (AuthKey_<ID>.p8), the issuer ID from ASC_ISSUER_ID or
#  ~/.appstoreconnect/issuer_id (App Store Connect ▸ Users and Access ▸
#  Integrations). Neither is kept here: this repository is public. The key
#  needs the App Manager role or higher.
#
#  The Mac upload also needs a "Mac Installer Distribution" certificate, with
#  its private key, in this Mac's keychain. Signed in to Xcode as an Admin,
#  the installer package is signed in Apple's cloud; an App Manager key is
#  refused that ("You haven't been given access to cloud-managed
#  distribution certificates"), so the package is signed here instead.
#  Create it once: Xcode ▸ Settings ▸ Accounts ▸ the team ▸ Manage
#  Certificates ▸ + ▸ Mac Installer Distribution. iOS needs only the Apple
#  Distribution certificate, which is already here.
#
#  Bump CURRENT_PROJECT_VERSION first — App Store Connect takes each build
#  number once — and stamp (scripts/stamp_build_info.sh) after the last
#  commit, so the splash screen names the commit the build is cut from.
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail
cd "$(dirname "$0")/.."

keys="$HOME/.appstoreconnect/private_keys"
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  key_path="$keys/AuthKey_${ASC_KEY_ID}.p8"
else
  found=("$keys"/AuthKey_*.p8(N))
  if (( ${#found} != 1 )); then
    echo "Found ${#found} keys in $keys — name one with ASC_KEY_ID." >&2
    exit 1
  fi
  key_path=$found[1]
  ASC_KEY_ID=${${key_path:t:r}#AuthKey_}
fi
[[ -f $key_path ]] || { echo "No key at $key_path." >&2; exit 1; }
issuer=${ASC_ISSUER_ID:-$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)}
[[ -n $issuer ]] || {
  echo "No issuer ID: set ASC_ISSUER_ID or write it to ~/.appstoreconnect/issuer_id." >&2
  exit 1
}
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$issuer")

case ${1:-both} in
  macos) platforms=(macOS) ;;
  ios)   platforms=(iOS) ;;
  both)  platforms=(iOS macOS) ;;
  *)     echo "usage: $0 [macos|ios|both]" >&2; exit 2 ;;
esac

build=$(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' finvestlens.xcodeproj/project.pbxproj | grep -oE '[0-9]+$')
echo "Build $build from $(git rev-parse --short HEAD)"
mkdir -p build
for platform in $platforms; do
  archive=build/FinvestLens-$platform.xcarchive
  rm -rf -- "${archive:?}" "build/export-${platform:?}"
  xcodebuild archive -scheme finvestlens -destination "generic/platform=$platform" \
    -archivePath "$archive" -derivedDataPath build/dd-archive \
    -skipPackagePluginValidation "${auth[@]}" > "build/archive-$platform.log" 2>&1 || {
    echo "$platform: archive failed — build/archive-$platform.log" >&2; exit 1; }
  # `destination: upload` in the options: the export step is the upload.
  xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "ExportOptions-AppStore-$platform.plist" \
    -exportPath "build/export-$platform" "${auth[@]}" > "build/upload-$platform.log" 2>&1 || {
    echo "$platform: upload failed — build/upload-$platform.log" >&2; exit 1; }
  grep -q 'Upload succeeded' "build/upload-$platform.log" || {
    echo "$platform: the export finished without reporting an upload — build/upload-$platform.log" >&2
    exit 1; }
  echo "$platform: build $build uploaded; App Store Connect is processing it."
done
