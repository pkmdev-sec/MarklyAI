#!/bin/bash
# Create a DMG installer for Arcmark with drag-and-drop to Applications folder

set -e  # Exit on error

echo "📦 Creating DMG installer..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Read version from VERSION file
if [ ! -f "VERSION" ]; then
    echo "❌ Error: VERSION file not found"
    exit 1
fi
VERSION=$(cat VERSION | tr -d '[:space:]')

# Verify the app bundle exists
APP_BUNDLE=".build/bundler/Arcmark.app"
if [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Error: App bundle not found at $APP_BUNDLE"
    echo "   Run ./scripts/build.sh first"
    exit 1
fi

# Create output directory
OUTPUT_DIR=".build/dmg"
mkdir -p "$OUTPUT_DIR"

# DMG configuration
DMG_NAME="Arcmark-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
VOLUME_NAME="Arcmark ${VERSION}"
TEMP_DMG="$OUTPUT_DIR/temp.dmg"

# Clean up any existing DMG files
rm -f "$DMG_PATH" "$TEMP_DMG"

# Create a temporary directory for DMG contents
DMG_STAGING="$OUTPUT_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

echo "  → Copying app bundle..."
cp -R "$APP_BUNDLE" "$DMG_STAGING/"

echo "  → Creating Applications folder symlink..."
ln -s /Applications "$DMG_STAGING/Applications"

# Create a .DS_Store file for nice window layout (optional but recommended)
# This creates a hidden file that sets the Finder window appearance
echo "  → Setting up DMG layout..."

# Calculate DMG size (app size + 50MB buffer)
APP_SIZE=$(du -sm "$APP_BUNDLE" | cut -f1)
DMG_SIZE=$((APP_SIZE + 50))

echo "  → Creating temporary DMG (${DMG_SIZE}MB)..."
hdiutil create -srcfolder "$DMG_STAGING" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE}m \
    "$TEMP_DMG" > /dev/null

# Mount the temporary DMG
echo "  → Mounting temporary DMG..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep -E '^/dev/')
DEVICE=$(echo "$MOUNT_OUTPUT" | awk '{print $1}')
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | awk '{print $3}')

echo "  → Customizing Finder window..."

# Check if background image exists and copy it if present
BACKGROUND_IMAGE="Resources/dmg-background.png"
USE_BACKGROUND=false

if [ -f "$BACKGROUND_IMAGE" ]; then
    echo "  → Adding custom background image..."
    mkdir -p "$MOUNT_POINT/.background"
    cp "$BACKGROUND_IMAGE" "$MOUNT_POINT/.background/background.png"
    USE_BACKGROUND=true
else
    echo "  ℹ️  No background image found at $BACKGROUND_IMAGE (optional)"
fi

# Use AppleScript to customize the DMG window
# Build the AppleScript with optional background image line
APPLESCRIPT="tell application \"Finder\"
    tell disk \"$VOLUME_NAME\"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 600, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128"

if [ "$USE_BACKGROUND" = true ]; then
    APPLESCRIPT="$APPLESCRIPT
        set background picture of viewOptions to file \".background:background.png\""
fi

APPLESCRIPT="$APPLESCRIPT
        set position of item \"Arcmark.app\" of container window to {125, 150}
        set position of item \"Applications\" of container window to {375, 150}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell"

osascript -e "$APPLESCRIPT"

# Ensure changes are written to disk
sync

echo "  → Unmounting temporary DMG..."
hdiutil detach "$DEVICE" > /dev/null

echo "  → Converting to compressed DMG..."
hdiutil convert "$TEMP_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" > /dev/null

# Clean up
rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"

echo ""
echo "✅ DMG created successfully!"
echo "📦 Output: $DMG_PATH"
echo "📏 Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "🧪 To test the DMG:"
echo "   open $DMG_PATH"
