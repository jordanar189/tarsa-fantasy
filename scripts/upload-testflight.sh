#!/usr/bin/env bash
# Build, archive, export, and upload Tarsa Fantasy to TestFlight.
#
# Usage:
#   ./scripts/upload-testflight.sh
#
# Requirements:
#   - .env at the project root with ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, ASC_TEAM_ID
#   - Distribution certificate + provisioning profile already set up via Xcode
#     (try archiving once from Xcode if you've never done it for this project)
#
# Build number: auto-generated as YYYYMMDDHHMM so each run is unique.
# Marketing version: read from project (edit MARKETING_VERSION in Xcode to bump).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Load .env if present. In CI the values come from env vars directly,
# so a missing .env is fine as long as the required vars are already set.
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

# Validate required vars
for var in ASC_KEY_ID ASC_ISSUER_ID ASC_TEAM_ID; do
  value="${!var:-}"
  if [[ -z "$value" || "$value" == *XXXXXXXX* || "$value" == *0000-0000* ]]; then
    echo "error: $var is not set in .env (still has placeholder value)" >&2
    exit 1
  fi
done

ASC_KEY_FILE="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [[ ! -f "$ASC_KEY_FILE" ]]; then
  echo "error: App Store Connect API key not found at $ASC_KEY_FILE" >&2
  echo "       altool only looks in ~/.appstoreconnect/private_keys/ — move it there:" >&2
  echo "         mkdir -p ~/.appstoreconnect/private_keys" >&2
  echo "         mv /path/to/AuthKey_${ASC_KEY_ID}.p8 ~/.appstoreconnect/private_keys/" >&2
  exit 1
fi

# Pass the API key to xcodebuild so it can fetch/create provisioning profiles
# without needing a logged-in Apple ID. Works both locally (.env) and in CI
# (secrets). The flags are honored by both `archive` and `-exportArchive`.
AUTH_FLAGS=(
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  -authenticationKeyPath "$ASC_KEY_FILE"
)

SCHEME="Tarsa Fantasy"
PROJECT="Tarsa Fantasy.xcodeproj"
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/TarsaFantasy.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Generate ExportOptions.plist (kept out of git so teamID doesn't leak).
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${ASC_TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

echo "==> Archiving (build $BUILD_NUMBER)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH_FLAGS[@]}" \
  -allowProvisioningUpdates \
  archive

echo "==> Exporting IPA"
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

echo "==> Uploading $IPA_PATH to App Store Connect"
xcrun altool --upload-app \
  --type ios \
  --file "$IPA_PATH" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "==> Done. Build $BUILD_NUMBER is processing in App Store Connect."
echo "    TestFlight builds usually appear within 5–30 minutes."
