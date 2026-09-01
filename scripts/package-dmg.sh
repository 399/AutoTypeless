#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_VERSION="${APP_VERSION:-0.8.5}"
BUILD_NUMBER="${BUILD_NUMBER:-23}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
ASSET_SUFFIX="${ASSET_SUFFIX:-}"
DIST_DIR="$PROJECT_DIR/dist"
APP_PATH="$DIST_DIR/AutoTypeless.app"
STAGING_DIR="$DIST_DIR/dmg-staging-${BUILD_ARCH}"
DMG_PATH="$DIST_DIR/AutoTypeless-${APP_VERSION}${ASSET_SUFFIX}.dmg"
VOLUME_NAME="AutoTypeless ${APP_VERSION}${ASSET_SUFFIX}"

APP_VERSION="$APP_VERSION" BUILD_NUMBER="$BUILD_NUMBER" BUILD_ARCH="$BUILD_ARCH" zsh "$PROJECT_DIR/scripts/package-menubar-app.sh" >/dev/null

rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/AutoTypeless.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING_DIR"
printf '%s\n' "$DMG_PATH"
