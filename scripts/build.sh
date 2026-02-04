#!/bin/bash
# Build Arcmark as a proper macOS app bundle

set -e  # Exit on error

echo "🔨 Building Arcmark..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Build the app bundle using swift-bundler
swift bundler bundle --platform macOS

echo "✅ Build complete!"
echo "📦 App bundle: .build/bundler/Arcmark.app"
