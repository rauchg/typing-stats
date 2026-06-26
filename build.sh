#!/bin/bash
set -e

BUILD_DIR=".build"

# Parse arguments
RELEASE_BUILD=false
NOTARIZE=false
for arg in "$@"; do
    case $arg in
        --release)
            RELEASE_BUILD=true
            shift
            ;;
        --notarize)
            NOTARIZE=true
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
    APP_NAME="Typing Stats"
    BUNDLE_NAME="Typing Stats.app"
    echo "Building TypingStats (RELEASE)..."
    swift build -c release
else
    APP_NAME="Typing Stats (Dev)"
    BUNDLE_NAME="Typing Stats (Dev).app"
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
if [ "$RELEASE_BUILD" != true ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.typing-stats.app.dev" "$BUNDLE_NAME/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Typing Stats (Dev)" "$BUNDLE_NAME/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Typing Stats (Dev)" "$BUNDLE_NAME/Contents/Info.plist"
fi
cp AppIcon.icns "$BUNDLE_NAME/Contents/Resources/"

# Copy Sparkle framework (use cp -a to preserve symlinks)
SPARKLE_PATH=$(find "$BUILD_DIR" -name "Sparkle.framework" -type d | head -1)
if [ -n "$SPARKLE_PATH" ]; then
    cp -a "$SPARKLE_PATH" "$BUNDLE_NAME/Contents/Frameworks/"
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

# Use hardened runtime only for proper Developer ID signing (not ad-hoc).
# The iCloud container entitlement is only applied for real Developer ID builds —
# ad-hoc signing can't carry iCloud entitlements (needs a provisioning profile),
# so those builds fall back to local Application Support storage at runtime.
ENTITLEMENTS="TypingStats.entitlements"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME"
else
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "$BUNDLE_NAME"
fi

# Notarize if requested
if [ "$NOTARIZE" = true ]; then
    if [ -z "$APP_STORE_CONNECT_KEY" ] || [ -z "$APP_STORE_CONNECT_KEY_ID" ] || [ -z "$APP_STORE_CONNECT_ISSUER_ID" ]; then
        echo "Error: Notarization requires APP_STORE_CONNECT_KEY, APP_STORE_CONNECT_KEY_ID, and APP_STORE_CONNECT_ISSUER_ID environment variables"
        exit 1
    fi

    echo "Notarizing app..."
    # Write API key to temp file
    KEY_FILE=$(mktemp)
    echo "$APP_STORE_CONNECT_KEY" > "$KEY_FILE"

    # Create zip for notarization
    ditto -c -k --keepParent "$BUNDLE_NAME" "${BUNDLE_NAME%.app}.zip"

    # Submit for notarization
    xcrun notarytool submit "${BUNDLE_NAME%.app}.zip" \
        --key "$KEY_FILE" \
        --key-id "$APP_STORE_CONNECT_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
        --wait

    # Staple the notarization ticket
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$BUNDLE_NAME"

    # Clean up
    rm "$KEY_FILE"
    rm "${BUNDLE_NAME%.app}.zip"

    echo "Notarization complete!"
fi

echo "Build complete: $BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -r '$BUNDLE_NAME' /Applications/"
echo ""
echo "Then open from /Applications or Spotlight."
echo "You'll need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility"
