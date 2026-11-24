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
# Build number = git commit count, same as the GitHub releases (v1.1.<N>),
# so "Check for Updates…" compares like with like.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 0)
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath build \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

# Find the built .app
APP_PATH=$(find build -name "$APP_NAME.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Build failed — .app not found"
    exit 1
fi

echo "📲 Installing to /Applications..."
sudo ditto "$APP_PATH" "$INSTALL_PATH"
# Owned by you, not root, so the in-app "Check for Updates…" can replace it
# without a password prompt.
sudo chown -R "$(id -u):admin" "$INSTALL_PATH"
if [ -d "/Applications/$OLD_APP.app" ]; then
    echo "🧹 Removing the old /Applications/$OLD_APP.app"
    sudo rm -rf "/Applications/$OLD_APP.app"
fi

echo ""
echo "✅ Installed: $INSTALL_PATH"
echo ""
echo "▶️  Launching..."
open "$INSTALL_PATH"

echo ""
echo "🔐 macOS will ask to let $APP_NAME find devices on your local network — click Allow."
echo "   Browsers (Chrome, Firefox, …) need the same permission to reach a LAN proxy;"
echo "   it can't be granted from a script. Check or change it here:"
echo "   System Settings → Privacy & Security → Local Network"
echo "   open \"x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork\""
