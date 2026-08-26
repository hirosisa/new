#!/usr/bin/env bash
# Builds an unsigned MediaPlayerApp.ipa. Requires macOS with Xcode 15+.
#
#   ./scripts/build-unsigned-ipa.sh
#
# Output: MediaPlayerApp/MediaPlayerApp-unsigned.ipa
#
# The .ipa is unsigned on purpose. SideStore (or AltStore) signs it on the
# device with your own free Apple ID, so nothing here needs a paid developer
# account or a provisioning profile.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../MediaPlayerApp"
cd "$PROJECT_DIR"

APP_NAME="MediaPlayerApp"
DERIVED="build"
PRODUCT="$DERIVED/Build/Products/Release-iphoneos/$APP_NAME.app"

echo "==> Toolchain"
xcodebuild -version

echo "==> Building (unsigned, arm64 device slice)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  ONLY_ACTIVE_ARCH=NO \
  clean build

if [ ! -d "$PRODUCT" ]; then
  echo "ERROR: build product missing at $PRODUCT" >&2
  find "$DERIVED/Build/Products" -maxdepth 3 -name '*.app' >&2 || true
  exit 1
fi

echo "==> Packaging .ipa"
rm -rf payload-staging "$APP_NAME-unsigned.ipa"
mkdir -p payload-staging/Payload
cp -R "$PRODUCT" payload-staging/Payload/
( cd payload-staging && zip -qry "../$APP_NAME-unsigned.ipa" Payload )
rm -rf payload-staging

echo "==> Verifying"
lipo -info "$PRODUCT/$APP_NAME"
plutil -extract UIBackgroundModes json -o - "$PRODUCT/Info.plist"

echo
echo "Done: $PROJECT_DIR/$APP_NAME-unsigned.ipa"
echo "Transfer it to your iPhone and open it with SideStore to install."
