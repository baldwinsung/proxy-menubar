#!/bin/bash
# build.sh — Build MacProxyMenuBar and install to /Applications
set -e

APP_NAME="MacProxyMenuBar"           # product (.app) name
OLD_APP="SimpleProxyMenuBar"         # name before 2026-11-18
SCHEME="SimpleProxyMenuBar"          # Xcode target/scheme keep the old name
PROJECT="SimpleProxyMenuBar.xcodeproj"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "🛑 Quitting $APP_NAME if running..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
osascript -e "quit app \"$OLD_APP\"" 2>/dev/null || true

rm -rf ~/Library/Developer/Xcode/DerivedData/$SCHEME-*

echo "🔨 Building $APP_NAME..."

# Build with xcodebuild
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath build \
    build

# Find the built .app
APP_PATH=$(find build -name "$APP_NAME.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Build failed — .app not found"
    exit 1
fi

echo "📲 Installing to /Applications..."
sudo ditto "$APP_PATH" "$INSTALL_PATH"
if [ -d "/Applications/$OLD_APP.app" ]; then
    echo "🧹 Removing the old /Applications/$OLD_APP.app"
    sudo rm -rf "/Applications/$OLD_APP.app"
fi

echo ""
echo "✅ Installed: $INSTALL_PATH"
echo ""
echo "▶️  Launching..."
open "$INSTALL_PATH"
