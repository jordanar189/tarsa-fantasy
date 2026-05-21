#!/usr/bin/env bash
# Build, archive, export (ad-hoc), and distribute Tarsa Fantasy via Firebase App Distribution.
#
# Usage:
#   ./scripts/upload-firebase.sh
#
# Gets the latest build onto registered test devices fast — no App Store Connect
# processing and no review. Reuses the same Apple distribution certificate as the
# TestFlight flow; the only signing difference is an ad-hoc provisioning profile
# (auto-generated via -allowProvisioningUpdates) instead of an App Store one, which
# is why every test device's UDID must be registered in the Apple Developer portal.
#
# Requirements:
#   - .env (local) or env vars (CI): ASC_KEY_ID, ASC_ISSUER_ID, ASC_TEAM_ID, FIREBASE_APP_ID
#   - App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#   - Distribution certificate already imported into the keychain
#   - GOOGLE_APPLICATION_CREDENTIALS pointing to the Firebase service account JSON
#   - firebase CLI on PATH (npm i -g firebase-tools)
#
# Build number: auto-generated as YYYYMMDDHHMM so each run is unique.
# Tester groups: FIREBASE_GROUPS (comma-separated), defaults to "internal".

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load .env if present. In CI the values come from env vars directly,
# so a missing .env is fine as long as the required vars are already set.
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

# Validate required vars
for var in ASC_KEY_ID ASC_ISSUER_ID ASC_TEAM_ID FIREBASE_APP_ID; do
  value="${!var:-}"
  if [[ -z "$value" || "$value" == *XXXXXXXX* || "$value" == *0000-0000* ]]; then
    echo "error: $var is not set (still has placeholder value)" >&2
    exit 1
  fi
done

ASC_KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [[ ! -f "$ASC_KEY_FILE" ]]; then
  echo "error: App Store Connect API key not found at $ASC_KEY_FILE" >&2
  echo "       move it there: mkdir -p ~/.appstoreconnect/private_keys && mv AuthKey_${ASC_KEY_ID}.p8 ~/.appstoreconnect/private_keys/" >&2
  exit 1
fi

if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
  echo "error: GOOGLE_APPLICATION_CREDENTIALS must point to the Firebase service account JSON" >&2
  exit 1
fi

# Pass the API key to xcodebuild so it can fetch/create the ad-hoc provisioning
# profile without a logged-in Apple ID. Used at the export step, where signing
# happens; the archive step is built unsigned (see below).
AUTH_FLAGS=(
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  -authenticationKeyPath "$ASC_KEY_FILE"
)

SCHEME="Tarsa Fantasy"
PROJECT="Tarsa Fantasy.xcodeproj"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/TarsaFantasy.xcarchive"
EXPORT_PATH="$BUILD_DIR/export-firebase"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions-firebase.plist"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
FIREBASE_GROUPS="${FIREBASE_GROUPS:-internal}"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Generate ExportOptions.plist (kept out of git so teamID doesn't leak).
# method=release-testing is the modern name for ad-hoc distribution.
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>release-testing</string>
  <key>teamID</key><string>${ASC_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

# Archive WITHOUT code signing. With automatic signing, `xcodebuild archive`
# signs the archive using an Apple Development identity, so every fresh CI
# runner would mint a brand-new development certificate via
# -allowProvisioningUpdates and eventually exhaust Apple's per-account
# certificate limit ("maximum number of certificates"). Signing is applied
# (with the distribution cert) at the export step below instead.
echo "==> Archiving (build $BUILD_NUMBER)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  archive

echo "==> Exporting ad-hoc IPA"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH_FLAGS[@]}" \
  -allowProvisioningUpdates

IPA_PATH="$(find "$EXPORT_PATH" -name '*.ipa' -maxdepth 2 | head -1)"
if [[ -z "$IPA_PATH" ]]; then
  echo "error: no .ipa found under $EXPORT_PATH" >&2
  exit 1
fi

RELEASE_NOTES="Build $BUILD_NUMBER ($(git rev-parse --short HEAD))"

echo "==> Distributing $IPA_PATH to Firebase App Distribution (groups: $FIREBASE_GROUPS)"
firebase appdistribution:distribute "$IPA_PATH" \
  --app "$FIREBASE_APP_ID" \
  --groups "$FIREBASE_GROUPS" \
  --release-notes "$RELEASE_NOTES"

echo "==> Done. Build $BUILD_NUMBER distributed. Testers get it in the Firebase App Tester app."
