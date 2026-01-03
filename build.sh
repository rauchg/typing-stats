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
mkdir -p "$BUNDLE_NAME/Contents/Frameworks"

cp "$BUILD_DIR/release/TypingStats" "$BUNDLE_NAME/Contents/MacOS/"
cp Info.plist "$BUNDLE_NAME/Contents/"
cp AppIcon.icns "$BUNDLE_NAME/Contents/Resources/"

# Copy Sparkle framework
SPARKLE_PATH=$(find "$BUILD_DIR" -name "Sparkle.framework" -type d | head -1)
if [ -n "$SPARKLE_PATH" ]; then
    cp -R "$SPARKLE_PATH" "$BUNDLE_NAME/Contents/Frameworks/"
    # Fix rpath to find framework
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_NAME/Contents/MacOS/TypingStats" 2>/dev/null || true
fi

# Code sign the app bundle (required for Sparkle signature verification)
echo "Code signing app bundle..."
codesign --force --deep --sign - "$BUNDLE_NAME"

echo "Build complete: $BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -r '$BUNDLE_NAME' /Applications/"
echo ""
echo "Then open from /Applications or Spotlight."
echo "You'll need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility"
