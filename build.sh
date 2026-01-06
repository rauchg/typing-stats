#!/bin/bash
set -e

APP_NAME="Typing Stats"
BUNDLE_NAME="Typing Stats.app"
BUILD_DIR=".build"

# Parse arguments
RELEASE_BUILD=false
for arg in "$@"; do
    case $arg in
        --release)
            RELEASE_BUILD=true
            shift
            ;;
    esac
done

# Get version from latest git tag
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.1")
echo "Version: $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist

if [ "$RELEASE_BUILD" = true ]; then
    echo "Building TypingStats (RELEASE)..."
    swift build -c release
else
    echo "Building TypingStats (DEV)..."
    swift build -c release -Xswiftc -DDEV_BUILD
fi

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

# Code sign the app bundle
echo "Code signing app bundle..."
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Using ad-hoc signing (set SIGNING_IDENTITY for Developer ID signing)"
else
    echo "Using signing identity: $SIGNING_IDENTITY"
fi

# Re-sign Sparkle framework first to match our signing identity
if [ -d "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework" ]; then
    echo "Re-signing Sparkle framework..."
    codesign --force --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    codesign --force --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    find "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" -name "*.xpc" -exec codesign --force --sign "$SIGNING_IDENTITY" {} \;
fi

# Use hardened runtime only for proper Developer ID signing (not ad-hoc)
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME"
else
    codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME"
fi

echo "Build complete: $BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -r '$BUNDLE_NAME' /Applications/"
echo ""
echo "Then open from /Applications or Spotlight."
echo "You'll need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility"
