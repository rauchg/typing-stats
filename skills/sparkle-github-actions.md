# Implementing Sparkle Auto-Updates with GitHub Actions

This guide covers how to set up Sparkle for macOS app auto-updates using GitHub releases and Actions for signing.

---

## ⚠️ CRITICAL: Preserve Symlinks or Gatekeeper Will Reject Your App

**The Sparkle.framework uses symlinks internally. If you break them, Gatekeeper rejects the app with: "bundle format is ambiguous (could be app or framework)"**

Two commands will silently destroy your app bundle:

| ❌ WRONG | ✅ CORRECT |
|----------|-----------|
| `cp -R Sparkle.framework dest/` | `cp -a Sparkle.framework dest/` |
| `zip -r App.zip App.app` | `ditto -c -k --keepParent App.app App.zip` |

- `cp -R` dereferences symlinks, copying file contents instead
- `zip -r` also dereferences symlinks by default
- `cp -a` preserves symlinks (archive mode)
- `ditto` is macOS-native and handles symlinks correctly

**Always verify your framework structure has symlinks:**
```bash
ls -la YourApp.app/Contents/Frameworks/Sparkle.framework/
# Should show symlinks like:
# Headers -> Versions/Current/Headers
# Sparkle -> Versions/Current/Sparkle
# Resources -> Versions/Current/Resources
```

If you see actual directories/files instead of symlinks, your bundle is broken.

---

## Overview

- **Sparkle**: macOS framework for app updates
- **EdDSA (ed25519)**: Cryptographic signing for update verification
- **appcast.xml**: RSS feed describing available updates
- **GitHub Actions**: Automates signing and release publishing

## 1. Add Sparkle Dependency

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [
            .product(name: "Sparkle", package: "Sparkle")
        ]
    )
]
```

## 2. Create UpdateChecker Class

```swift
import Foundation
import Sparkle

class UpdateChecker: NSObject {
    static let shared = UpdateChecker()
    private var updaterController: SPUStandardUpdaterController!

    var updater: SPUUpdater {
        updaterController.updater
    }

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
```

## 3. Generate EdDSA Keys

Download Sparkle tools and generate a key pair:

```bash
# Download Sparkle
curl -L -o /tmp/sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
cd /tmp && tar xf sparkle.tar.xz

# Generate keys (stores key in Keychain and prints SUPublicEDKey XML)
/tmp/bin/generate_keys

# Export the private key for GitHub Actions
/tmp/bin/generate_keys -x /tmp/sparkle_private_key
cat /tmp/sparkle_private_key && rm /tmp/sparkle_private_key
```

**Important**:
- Add the private key as a GitHub secret: `SPARKLE_PRIVATE_KEY`
- Keep the public key for Info.plist

## 4. Configure Info.plist

Add these keys to your `Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://raw.githubusercontent.com/OWNER/REPO/main/appcast.xml</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

## 5. Build Script with Code Signing

**Critical**: The app must be properly code signed for Sparkle to verify updates. Without this, `Info.plist` won't be sealed and Sparkle can't read `SUPublicEDKey`.

```bash
#!/bin/bash
set -e

BUNDLE_NAME="YourApp.app"
BUILD_DIR=".build"

swift build -c release

# Create app bundle
rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"
mkdir -p "$BUNDLE_NAME/Contents/Frameworks"

cp "$BUILD_DIR/release/YourApp" "$BUNDLE_NAME/Contents/MacOS/"
cp Info.plist "$BUNDLE_NAME/Contents/"

# Copy Sparkle framework (MUST use cp -a to preserve symlinks!)
SPARKLE_PATH=$(find "$BUILD_DIR" -name "Sparkle.framework" -type d | head -1)
if [ -n "$SPARKLE_PATH" ]; then
    cp -a "$SPARKLE_PATH" "$BUNDLE_NAME/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_NAME/Contents/MacOS/YourApp" 2>/dev/null || true
fi

# CRITICAL: Code sign the app bundle
# This seals Info.plist so Sparkle can read SUPublicEDKey
codesign --force --deep --sign - "$BUNDLE_NAME"
```

Verify code signing sealed resources:

```bash
codesign -dv --verbose=4 YourApp.app 2>&1 | grep -E "Info.plist|Sealed Resources"
# Should show:
# Info.plist entries=XX
# Sealed Resources version=2 rules=XX files=XX
```

## 6. Create Initial appcast.xml

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Your App</title>
    <item>
      <title>Version 1.0.0</title>
      <sparkle:version>1.0.0</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <pubDate>Mon, 01 Jan 2025 00:00:00 +0000</pubDate>
      <enclosure url="https://github.com/OWNER/REPO/releases/download/v1.0.0/YourApp.zip"
                 type="application/octet-stream"
                 length="0"
                 sparkle:edSignature=""/>
    </item>
  </channel>
</rss>
```

## 7. GitHub Actions Release Workflow

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: macos-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: ./build.sh

      - name: Create zip
        # MUST use ditto, NOT zip! zip dereferences symlinks and breaks Sparkle.framework
        run: ditto -c -k --keepParent YourApp.app YourApp.zip

      - name: Get version
        id: version
        run: echo "version=${GITHUB_REF#refs/tags/v}" >> $GITHUB_OUTPUT

      - name: Download Sparkle
        run: |
          curl -L -o /tmp/sparkle.tar.xz "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
          cd /tmp && tar xf sparkle.tar.xz

      - name: Sign update
        id: sign
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          echo "$SPARKLE_PRIVATE_KEY" > /tmp/sparkle_key
          OUTPUT=$(/tmp/bin/sign_update YourApp.zip -f /tmp/sparkle_key)
          SIGNATURE=$(echo "$OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
          LENGTH=$(echo "$OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
          echo "signature=$SIGNATURE" >> $GITHUB_OUTPUT
          echo "length=$LENGTH" >> $GITHUB_OUTPUT
          rm /tmp/sparkle_key

      - name: Update appcast.xml
        run: |
          VERSION="${{ steps.version.outputs.version }}"
          DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
          SIGNATURE="${{ steps.sign.outputs.signature }}"
          LENGTH="${{ steps.sign.outputs.length }}"
          cat > appcast.xml << EOF
          <?xml version="1.0" encoding="utf-8"?>
          <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
              <title>Your App</title>
              <item>
                <title>Version ${VERSION}</title>
                <sparkle:version>${VERSION}</sparkle:version>
                <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
                <pubDate>${DATE}</pubDate>
                <enclosure url="https://github.com/OWNER/REPO/releases/download/v${VERSION}/YourApp.zip"
                           type="application/octet-stream"
                           length="${LENGTH}"
                           sparkle:edSignature="${SIGNATURE}"/>
              </item>
            </channel>
          </rss>
          EOF

      - name: Commit updated appcast
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add appcast.xml
          git commit -m "Update appcast for v${{ steps.version.outputs.version }}"
          git push origin HEAD:main

      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: YourApp.zip
          generate_release_notes: true
```

## 8. Creating a Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the workflow which:
1. Builds the app with proper code signing
2. Signs the zip with your EdDSA private key
3. Updates appcast.xml with the signature
4. Creates a GitHub release with the zip

## Common Issues

### "bundle format is ambiguous (could be app or framework)"

**Cause**: Sparkle.framework symlinks were dereferenced during copy or zip.

**Fix**:
- Use `cp -a` instead of `cp -R` when copying the framework
- Use `ditto -c -k --keepParent` instead of `zip -r` when creating archives

**Verify**: Check framework structure:
```bash
ls -la YourApp.app/Contents/Frameworks/Sparkle.framework/
# Must show symlinks (->), not directories
```

### "Update is improperly signed"

**Cause**: App bundle not properly code signed, so `Info.plist` isn't sealed.

**Fix**: Add `codesign --force --deep --sign - "$BUNDLE_NAME"` to build script.

**Verify**: Check that `codesign -dv --verbose=4 YourApp.app` shows:
- `Info.plist entries=XX` (not "not bound")
- `Sealed Resources version=2`

### Signature extraction fails

**Cause**: Wrong sed pattern extracting signature from sign_update output.

**Fix**: Use this pattern:
```bash
SIGNATURE=$(echo "$OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
```

### Keys don't match

**Cause**: Different key used in CI vs what generated the public key.

**Fix**: Ensure `SPARKLE_PRIVATE_KEY` GitHub secret matches the private key that generated the `SUPublicEDKey` in Info.plist.

### Verify signature manually

```bash
/path/to/sign_update --verify YourApp.zip "SIGNATURE_FROM_APPCAST"
```

No output = success. Any error = failure.

## Testing Updates Locally

1. Build an older version (e.g., 0.0.1) and install it
2. Ensure appcast.xml points to a newer version
3. Launch the app and check for updates
4. Verify the update installs and relaunches correctly
