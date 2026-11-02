#!/bin/bash
set -e

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

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
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$BUNDLE_NAME/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE_NAME/Contents/Info.plist"
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
    if [[ ! "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        RESOLVED_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$SIGNING_IDENTITY" | head -n 1 | awk '{print $2}')
        if [ -n "$RESOLVED_HASH" ]; then
            echo "Using signing identity: $SIGNING_IDENTITY ($RESOLVED_HASH)"
            SIGNING_IDENTITY="$RESOLVED_HASH"
        else
            echo "Using signing identity: $SIGNING_IDENTITY"
        fi
    else
        echo "Using signing identity: $SIGNING_IDENTITY"
    fi
fi

# Re-sign Sparkle framework first to match our signing identity
CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [ "$SIGNING_IDENTITY" != "-" ]; then
    CODESIGN_ARGS+=(--options runtime --timestamp)
fi

if [ -d "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework" ]; then
    echo "Re-signing Sparkle framework..."
    find "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" -name "*.xpc" -exec codesign "${CODESIGN_ARGS[@]}" {} \;
    if [ -f "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" ]; then
        codesign "${CODESIGN_ARGS[@]}" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    fi
    codesign "${CODESIGN_ARGS[@]}" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    codesign "${CODESIGN_ARGS[@]}" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
fi

# Sign the outer app bundle and verify signature integrity
codesign --deep "${CODESIGN_ARGS[@]}" "$BUNDLE_NAME"
codesign --verify --deep --strict --verbose=2 "$BUNDLE_NAME"

# Notarize if requested
if [ "$NOTARIZE" = true ]; then
    if [ -z "$APP_STORE_CONNECT_KEY" ] || [ -z "$APP_STORE_CONNECT_KEY_ID" ] || [ -z "$APP_STORE_CONNECT_ISSUER_ID" ]; then
        echo "Error: Notarization requires APP_STORE_CONNECT_KEY, APP_STORE_CONNECT_KEY_ID, and APP_STORE_CONNECT_ISSUER_ID environment variables"
        exit 1
    fi

    echo "Notarizing app..."
    # Write API key to restricted temp file and guarantee cleanup on exit
    KEY_FILE=$(umask 077 && mktemp)
    trap 'rm -f "$KEY_FILE" "${BUNDLE_NAME%.app}.zip"' EXIT
    printf '%s\n' "$APP_STORE_CONNECT_KEY" > "$KEY_FILE"

    # Create zip for notarization
    ditto -c -k --keepParent "$BUNDLE_NAME" "${BUNDLE_NAME%.app}.zip"

    # Submit for notarization
    xcrun notarytool submit "${BUNDLE_NAME%.app}.zip" \
        --key "$KEY_FILE" \
        --key-id "$APP_STORE_CONNECT_KEY_ID" \
        --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
        --wait

    # Staple and validate the notarization ticket + Gatekeeper assessment
    echo "Stapling and validating notarization ticket..."
    xcrun stapler staple "$BUNDLE_NAME"
    xcrun stapler validate "$BUNDLE_NAME"
    spctl --assess --type execute --verbose=4 "$BUNDLE_NAME"

    # Clean up
    rm -f "$KEY_FILE" "${BUNDLE_NAME%.app}.zip"
    trap - EXIT

    echo "Notarization complete!"
fi

echo "Build complete: $BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -r '$BUNDLE_NAME' /Applications/"
echo ""
echo "Then open from /Applications or Spotlight."
echo "You'll need to grant Accessibility permissions in System Settings > Privacy & Security > Accessibility"
