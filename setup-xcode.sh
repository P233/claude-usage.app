#!/bin/bash

# ============================================================================
# Claude Usage - Xcode Project Setup Guide
# ============================================================================
#
# Description:
#   This script provides step-by-step guidance for creating an Xcode project
#   for the Claude Usage menubar app. An Xcode project is needed if you want
#   to debug, profile, or sign the app for distribution.
#
# Usage:
#   ./setup-xcode.sh
#
# What this script does:
#   1. Checks if Xcode is installed
#   2. Checks for existing Xcode project
#   3. Displays detailed instructions for manual project creation
#   4. Optionally opens Xcode to begin setup
#
# Note:
#   If you just want to build and run the app quickly, use build.sh instead.
#   This script is for developers who need full Xcode project features.
#
# ============================================================================

set -e  # Exit immediately if any command fails

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="ClaudeUsage"
BUNDLE_ID="com.claudeusage.app"

echo "🧠 Claude Usage - Xcode Project Setup"
echo "======================================"
echo ""

# ============================================================================
# Step 1: Check Xcode installation
# ============================================================================

if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Error: Xcode is not installed or xcodebuild is not in PATH"
    echo "Please install Xcode from the App Store"
    exit 1
fi

echo "✅ Xcode found: $(xcodebuild -version | head -n 1)"
echo ""

# ============================================================================
# Step 2: Check for existing project
# ============================================================================

if [ -d "$SCRIPT_DIR/$PROJECT_NAME.xcodeproj" ]; then
    echo "⚠️  Xcode project already exists at: $SCRIPT_DIR/$PROJECT_NAME.xcodeproj"
    read -p "Do you want to open it? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "$SCRIPT_DIR/$PROJECT_NAME.xcodeproj"
    fi
    exit 0
fi

# ============================================================================
# Step 3: Display setup instructions
# ============================================================================
# Since Xcode projects can't be created programmatically without complex
# tooling, we provide clear manual instructions

echo "📝 To create the Xcode project:"
echo ""
echo "1. Open Xcode"
echo "2. File → New → Project"
echo "3. Select macOS → App → Next"
echo "4. Configure:"
echo "   • Product Name: $PROJECT_NAME"
echo "   • Bundle Identifier: $BUNDLE_ID"
echo "   • Interface: SwiftUI"
echo "   • Language: Swift"
echo "   • Storage: None"
echo "   • ✗ Include Tests (uncheck)"
echo ""
echo "5. Save the project in: $SCRIPT_DIR"
echo ""
echo "6. After creation:"
echo "   • Delete ContentView.swift (the default generated file)"
echo "   • Drag all files from ClaudeUsage/ folder into Xcode"
echo "   • Keep 'Copy items if needed' unchecked"
echo "   • Keep folder references"
echo ""
echo "7. In Project Settings (click project in sidebar):"
echo "   • Set Deployment Target to macOS 13.0"
echo "   • Go to Signing & Capabilities tab"
echo "   • Add 'Outgoing Connections (Client)' capability"
echo ""
echo "8. In Info.plist, ensure these keys exist:"
echo "   • LSUIElement = YES (makes app a menubar-only agent)"
echo ""
echo "9. Build and Run (⌘+R)"
echo ""

# ============================================================================
# Step 4: Offer to open Xcode
# ============================================================================

read -p "Open Xcode now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    open -a Xcode
fi

echo ""
echo "✨ Happy coding!"
