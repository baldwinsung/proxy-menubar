#!/bin/bash
# install.sh — install or upgrade MacProxyMenuBar from a GitHub release.
#
#   One-liner (latest release):
#     curl -fsSL https://raw.githubusercontent.com/baldwinsung/proxy-menubar/main/install.sh | bash
#   A specific release:   ... | bash -s -- v1.1.58
#   Local files (used by the app's "Check for Updates…"):
#     install.sh --zip MacProxyMenuBar.zip --sha256 MacProxyMenuBar.zip.sha256
#
# Quits the running app, removes every previous copy (MacProxyMenuBar.app and
# the pre-2026-11-18 SimpleProxyMenuBar.app, in /Applications and
# ~/Applications), verifies the zip's SHA-256, installs to /Applications and
# relaunches. Uses sudo only when /Applications or the old app isn't
# writable, then hands the app back to you so later upgrades need no password.
# Behind a proxy, export https_proxy first (curl doesn't read the PAC file).
set -euo pipefail

REPO="baldwinsung/proxy-menubar"
APP="MacProxyMenuBar"
OLD_APP="SimpleProxyMenuBar"
DEST="/Applications/$APP.app"

TAG="" ZIP="" SHA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --zip)    ZIP="$2"; shift 2 ;;
        --sha256) SHA="$2"; shift 2 ;;
        v*)       TAG="$1"; shift ;;
        *) echo "usage: install.sh [vX.Y.N] | --zip FILE --sha256 FILE" >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Darwin ] || { echo "macOS only" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$ZIP" ]; then
    if [ -z "$TAG" ]; then
        TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
               | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
        [ -n "$TAG" ] || { echo "❌ Could not find the latest release" >&2; exit 1; }
    fi
    echo "⬇️  Downloading $APP $TAG…"
    BASE="https://github.com/$REPO/releases/download/$TAG"
    curl -fsSL -o "$WORK/$APP.zip" "$BASE/$APP.zip"
    curl -fsSL -o "$WORK/$APP.zip.sha256" "$BASE/$APP.zip.sha256"
    ZIP="$WORK/$APP.zip" SHA="$WORK/$APP.zip.sha256"
fi

echo "🔒 Verifying SHA-256…"
want="$(awk '{print $1}' "$SHA")"
got="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "❌ Checksum mismatch ($got != $want)" >&2; exit 1; }

ditto -x -k "$ZIP" "$WORK/unzipped"
NEW="$WORK/unzipped/$APP.app"
[ -d "$NEW" ] || { echo "❌ $APP.app not found in the zip" >&2; exit 1; }

echo "🛑 Quitting $APP if running…"
for a in "$APP" "$OLD_APP"; do
    osascript -e "with timeout of 5 seconds" -e "quit app \"$a\"" -e "end timeout" >/dev/null 2>&1 || true
done
sleep 1
pkill -x "$APP" 2>/dev/null || true
pkill -x "$OLD_APP" 2>/dev/null || true

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    for p in /Applications "$DEST/Contents" "/Applications/$OLD_APP.app/Contents"; do
        if [ -e "$p" ] && [ ! -w "$p" ]; then SUDO="sudo"; fi
    done
fi

echo "🧹 Removing previous versions…"
for p in "/Applications/$APP.app" "/Applications/$OLD_APP.app"; do
    if [ -e "$p" ]; then $SUDO rm -rf "$p"; fi
done
for p in "$HOME/Applications/$APP.app" "$HOME/Applications/$OLD_APP.app"; do
    if [ -e "$p" ]; then rm -rf "$p"; fi
done

echo "📲 Installing to $DEST…"
$SUDO ditto "$NEW" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || $SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Hand the bundle to the user who'll run it (root ran us under sudo or the
# app's admin prompt), so the next in-app upgrade needs no password.
OWNER_UID="${OPEN_AS_UID:-${SUDO_UID:-$(id -u)}}"
if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
    ${SUDO:-} chown -R "$OWNER_UID:admin" "$DEST" 2>/dev/null || true
fi

echo "▶️  Launching…"
if [ "$(id -u)" -eq 0 ] && [ "$OWNER_UID" != 0 ]; then
    launchctl asuser "$OWNER_UID" sudo -u "#$OWNER_UID" open "$DEST"
else
    open "$DEST"
fi

version="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
build="$(defaults read "$DEST/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
echo "✅ $APP $version ($build) installed."
echo "   If macOS asks to let it find devices on your local network, click Allow."
