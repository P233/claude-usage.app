#!/bin/bash

# ============================================================================
# Claude Usage - Test Runner Script
# ============================================================================
#
# Description:
#   Compiles and runs unit tests for the Claude Usage app.
#
# Usage:
#   ./run-tests.sh
#
# Requirements:
#   - macOS 13.0 (Ventura) or later
#   - Xcode Command Line Tools
#
# ============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$PROJECT_DIR/ClaudeUsage"
TESTS_DIR="$PROJECT_DIR/ClaudeUsageTests"
BUILD_DIR="$PROJECT_DIR/build"

echo "🧪 Building and running tests..."
echo ""

# Clean test build directory
rm -rf "$BUILD_DIR/tests"
mkdir -p "$BUILD_DIR/tests"

# Collect all source files (excluding ClaudeUsageApp.swift which has @main)
SOURCE_FILES=$(find "$SOURCE_DIR" -name "*.swift" -type f ! -name "ClaudeUsageApp.swift")

# Collect test files
TEST_FILES=$(find "$TESTS_DIR" -name "*.swift" -type f)
ARCH=$(uname -m)

echo "📝 Compiling source files and tests (arch: $ARCH)..."

# Compile everything together
swiftc \
    -o "$BUILD_DIR/tests/TestRunner" \
    -target ${ARCH}-apple-macosx13.0 \
    -sdk $(xcrun --sdk macosx --show-sdk-path) \
    -framework SwiftUI \
    -framework Security \
    -framework Combine \
    -framework AppKit \
    -parse-as-library \
    $SOURCE_FILES \
    $TEST_FILES

echo ""
echo "🚀 Running tests..."
echo ""

# Run the test executable
"$BUILD_DIR/tests/TestRunner"
