#!/bin/bash
# Clean build artifacts for Arcmark

set -e  # Exit on error

echo "🧹 Cleaning build artifacts..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Remove SPM build directory
if [ -d ".build" ]; then
    echo "  Removing .build directory..."
    rm -rf .build
fi

# Remove derived data
if [ -d "DerivedData" ]; then
    echo "  Removing DerivedData directory..."
    rm -rf DerivedData
fi

echo "✅ Clean complete!"
