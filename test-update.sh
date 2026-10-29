#!/bin/bash
# Test the Sparkle auto-update flow end to end against the published appcast.
#
# Builds the current checkout as "Typing Stats.app" (release name and bundle ID, which Sparkle
# requires to match the update archive) but labels it with an older version, so Sparkle offers
# the latest release. Then it makes the last update check look overdue and launches the copy.
#
#   ./test-update.sh [fake-version]     # default: one patch below the latest tag
#
# Expected: within ~30s the update downloads silently and the menu shows
# "Restart to Update (vX)". Clicking it installs and relaunches with no Sparkle dialog.
# The test copy lives in the repo folder (gitignored) and shares the release app's settings,
# so quit your installed Typing Stats first to avoid counting keystrokes twice.
set -e
cd "$(dirname "$0")"

LATEST=$(git describe --tags --abbrev=0 | sed 's/^v//')
FAKE="${1:-$(echo "$LATEST" | awk -F. -v OFS=. '{ if ($3 > 0) $3 -= 1; else if ($2 > 0) $2 -= 1; else $1 -= 1; print }')}"
APP="Typing Stats.app"

if pgrep -f "/Applications/$APP/Contents/MacOS/TypingStats" >/dev/null; then
    echo "Quit the installed Typing Stats first (it shares settings with the test copy)." >&2
    exit 1
fi

echo "Latest release: $LATEST, test copy labeled: $FAKE"
./build.sh --release
git checkout -- Info.plist   # build.sh stamps the version into the tracked plist

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FAKE" -c "Set :CFBundleShortVersionString $FAKE" "$APP/Contents/Info.plist"
codesign --force --deep --options runtime --sign "${SIGNING_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"

# Make the scheduled check overdue so Sparkle checks right after launch.
defaults write com.typing-stats.app SULastCheckTime -date "2000-01-01 00:00:00 +0000"
open "$PWD/$APP"

echo "Launched $APP ($FAKE). Watch Sparkle with:"
echo "  /usr/bin/log stream --predicate 'subsystem BEGINSWITH \"org.sparkle-project\"' --style compact"
