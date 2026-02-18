#!/bin/bash
# Build, sign, and publish a new Arcmark release
#
# Usage:
#   ./scripts/release.sh <version>        # Full release: build, tag, push, create GitHub release
#   ./scripts/release.sh <version> --dry-run  # Build and sign only, skip git/GitHub operations
#
# Example:
#   ./scripts/release.sh 0.2.0
#   ./scripts/release.sh 0.2.0 --dry-run

set -e

# Parse arguments
if [ -z "$1" ]; then
    echo "Usage: $0 <version> [--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 0.2.0           # Full release"
    echo "  $0 0.2.0 --dry-run # Build only, skip git/GitHub"
    exit 1
fi

NEW_VERSION="$1"
DRY_RUN=false
if [ "$2" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Validate version format (semver: X.Y.Z or X.Y.Z-suffix)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    echo "❌ Invalid version format: $NEW_VERSION"
    echo "   Expected: MAJOR.MINOR.PATCH (e.g., 0.2.0, 1.0.0-beta.1)"
    exit 1
fi

# Ensure we're in the project root
cd "$(dirname "$0")/.."

echo "🚀 Releasing Arcmark v${NEW_VERSION}"
if [ "$DRY_RUN" = true ]; then
    echo "   (dry-run mode — git/GitHub operations will be skipped)"
fi
echo ""

# Check prerequisites
if [ "$DRY_RUN" = false ]; then
    # Check for clean working tree (aside from VERSION and appcast which we'll change)
    if ! git diff --quiet -- ':!VERSION' ':!docs/appcast.xml' ':!Bundler.toml'; then
        echo "❌ Working tree has uncommitted changes. Commit or stash them first."
        exit 1
    fi

    # Check that gh CLI is available
    if ! command -v gh &>/dev/null; then
        echo "❌ GitHub CLI (gh) is required. Install with: brew install gh"
        exit 1
    fi

    # Check that we're on main branch
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "main" ]; then
        echo "⚠️  Warning: You're on branch '$CURRENT_BRANCH', not 'main'"
        read -p "   Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Check that tag doesn't already exist
    if git rev-parse "v${NEW_VERSION}" &>/dev/null; then
        echo "❌ Tag v${NEW_VERSION} already exists"
        exit 1
    fi
fi

# Step 1: Update version
echo "📌 Step 1: Updating version to ${NEW_VERSION}..."
echo "$NEW_VERSION" > VERSION
echo "  ✓ VERSION file updated"
echo ""

# Step 2: Build production DMG (includes EdDSA signing and appcast update)
echo "📦 Step 2: Building production DMG..."
echo "────────────────────────────────────────"
./scripts/build.sh --production --dmg
echo "────────────────────────────────────────"
echo ""

# Verify DMG was created
DMG_PATH=".build/dmg/Arcmark-${NEW_VERSION}.dmg"
if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG not found at $DMG_PATH"
    exit 1
fi
echo "  ✓ DMG ready: $DMG_PATH"

# Verify appcast was updated
if ! grep -q "sparkle:version=\"${NEW_VERSION}\"" docs/appcast.xml; then
    echo "⚠️  Warning: appcast.xml may not have been updated with v${NEW_VERSION}"
    echo "   Check docs/appcast.xml manually"
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "✅ Dry run complete!"
    echo ""
    echo "Artifacts:"
    echo "  📦 DMG: $DMG_PATH"
    echo "  📄 Appcast: docs/appcast.xml"
    echo ""
    echo "To finish the release manually:"
    echo "  git add VERSION Bundler.toml docs/appcast.xml"
    echo "  git commit -m 'Release v${NEW_VERSION}'"
    echo "  git tag -a v${NEW_VERSION} -m 'Release version ${NEW_VERSION}'"
    echo "  git push origin main v${NEW_VERSION}"
    echo "  gh release create v${NEW_VERSION} ${DMG_PATH} --title 'v${NEW_VERSION}'"
    exit 0
fi

# Step 3: Commit changes
echo ""
echo "📝 Step 3: Committing release changes..."
git add VERSION Bundler.toml docs/appcast.xml
git commit -m "Release v${NEW_VERSION}"
echo "  ✓ Changes committed"

# Step 4: Tag and push
echo ""
echo "🏷️  Step 4: Tagging and pushing..."
git tag -a "v${NEW_VERSION}" -m "Release version ${NEW_VERSION}"
git push origin main "v${NEW_VERSION}"
echo "  ✓ Pushed to origin with tag v${NEW_VERSION}"

# Step 5: Create GitHub Release
echo ""
echo "🐙 Step 5: Creating GitHub Release..."
gh release create "v${NEW_VERSION}" "$DMG_PATH" \
    --title "v${NEW_VERSION}" \
    --notes "## Arcmark v${NEW_VERSION}"
echo "  ✓ GitHub Release created"

echo ""
echo "════════════════════════════════════════"
echo "✅ Arcmark v${NEW_VERSION} released!"
echo ""
echo "  📦 DMG: $DMG_PATH"
echo "  🏷️  Tag: v${NEW_VERSION}"
echo "  🐙 Release: https://github.com/pkmdev-sec/MarklyAI/releases/tag/v${NEW_VERSION}"
echo "  📡 Appcast will update once GitHub Pages rebuilds"
echo ""
echo "Existing users will receive the update automatically via Sparkle."
echo "════════════════════════════════════════"
