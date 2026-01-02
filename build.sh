#!/bin/bash
set -e

APP_NAME="Typing Stats"
BUNDLE_NAME="TypingStats.app"
BUILD_DIR=".build"

echo "Building TypingStats..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

cp "$BUILD_DIR/release/TypingStats" "$BUNDLE_NAME/Contents/MacOS/"
cp Info.plist "$BUNDLE_NAME/Contents/"
cp AppIcon.icns "$BUNDLE_NAME/Contents/Resources/"

echo "Build complete: $BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -r '$BUNDLE_NAME' /Applications/"
echo ""
echo "Then open from /Applications or Spotlight."
echo "You'll need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility"
