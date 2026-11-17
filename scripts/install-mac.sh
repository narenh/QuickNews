#!/bin/zsh
# Builds the Mac app and installs it to /Applications, so Safari lists the extension.
#
#   ./scripts/install-mac.sh
#
# Then tick QuickNews in Safari › Settings › Extensions.
set -euo pipefail

ROOT="${0:A:h}/.."
cd "$ROOT"
xcodegen generate --quiet
# A build you install yourself sends News's request headers; see OWLResolver.swift.
xcodebuild -project OpenInNews.xcodeproj -scheme OpenInNewsMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/dd \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) NEWS_CLIENT_HEADERS' build \
  | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'

APP="QuickNews.app"
OLD_APP="Open in News.app" # the app's name before QuickNews
BUILT="build/dd/Build/Products/Release/$APP"
DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$BUILT" "$DEST/"

# Xcode registers every app it builds, which would show Safari a second copy
# of the extension. Keep only the installed one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# An install under the old name carries the same extension; remove it too.
for old in "$DEST/$OLD_APP" "$ROOT/build/dd/Build/Products/"{Debug,Release}"/$OLD_APP"; do
  "$LSREGISTER" -u "$old" 2>/dev/null || true
done
rm -rf "$DEST/$OLD_APP"
"$LSREGISTER" -u "$ROOT/build/dd/Build/Products/Debug/$APP" 2>/dev/null || true
"$LSREGISTER" -u "$ROOT/$BUILT" 2>/dev/null || true
"$LSREGISTER" -f "$DEST/$APP"

open "$DEST/$APP"
echo "Installed $DEST/$APP"
