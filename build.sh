#!/bin/bash

# ============================================================================
# Claude Usage - Build Script
# ============================================================================
#
# Description:
#   Compiles the Claude Usage menubar app directly using swiftc, without
#   requiring an Xcode project. This is useful for quick builds and CI/CD.
#
# Usage:
#   ./build.sh
#
# Requirements:
#   - macOS 13.0 (Ventura) or later
#   - Xcode Command Line Tools (for swiftc compiler)
#   - Apple Silicon Mac (arm64) - modify -target flag for Intel Macs
#
# Output:
#   - Creates build/ClaudeUsage.app bundle
#   - Optionally runs the app after build
#
# Note:
#   The built app is unsigned and may require allowing it in System Settings
#   → Privacy & Security when first launched.
#
# ============================================================================

set -e  # Exit immediately if any command fails

# ============================================================================
# Configuration
# ============================================================================

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$PROJECT_DIR/ClaudeUsage"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="ClaudeUsage"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🧠 Building Claude Usage..."
echo ""

# ============================================================================
# Step 1: Clean build directory
# ============================================================================

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ============================================================================
# Step 2: Collect and compile Swift files
# ============================================================================

SWIFT_FILES=$(find "$SOURCE_DIR" -name "*.swift" -type f)

echo "📝 Compiling Swift files..."

# Compile with swiftc
# -target: Specifies arm64 architecture and minimum macOS version
# -sdk: Uses the macOS SDK from Xcode
# -framework: Links required frameworks (SwiftUI, WebKit, Security, etc.)
# -parse-as-library: Treats the code as a library (required for @main entry point)
swiftc \
    -o "$BUILD_DIR/$APP_NAME" \
    -target arm64-apple-macosx13.0 \
    -sdk $(xcrun --sdk macosx --show-sdk-path) \
    -framework SwiftUI \
    -framework WebKit \
    -framework Security \
    -framework Combine \
    -framework AppKit \
    -parse-as-library \
    $SWIFT_FILES

# ============================================================================
# Step 3: Create macOS app bundle structure
# ============================================================================
# A macOS .app bundle has the following structure:
#   ClaudeUsage.app/
#   └── Contents/
#       ├── MacOS/         <- Executable goes here
#       ├── Resources/     <- Assets, localization files
#       ├── Info.plist     <- App metadata
#       └── PkgInfo        <- Package type identifier

echo "📦 Creating app bundle..."

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Move compiled executable into the bundle
mv "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Info.plist from source
cp "$SOURCE_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Create PkgInfo file (standard for macOS apps: APPL + 4 char creator code)
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# ============================================================================
# Step 4: Update Info.plist with required values
# ============================================================================
# Using PlistBuddy to ensure all required keys are set correctly

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.claudeusage.app" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.claudeusage.app" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundlePackageType APPL" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP_BUNDLE/Contents/Info.plist"

# ============================================================================
# Step 5: Code sign the app (ad-hoc signing for local development)
# ============================================================================
# Ad-hoc signing allows the app to access Keychain without repeated prompts.
# For distribution, use a proper Apple Developer certificate.

echo "🔏 Signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

# ============================================================================
# Done
# ============================================================================

echo ""
echo "✅ Build successful!"
echo ""
echo "📍 App location: $APP_BUNDLE"
echo ""
echo "To run the app:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "To install to Applications:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo ""

# Ask user if they want to run the app immediately
read -p "🚀 Run the app now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open "$APP_BUNDLE"
fi
