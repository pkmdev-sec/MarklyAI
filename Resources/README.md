# Resources Directory

This directory contains assets for the Arcmark application.

## Required Assets

### App Icon

Place your app icon here in one of these formats:

**Option 1: PNG (Simplest)**
- File: `AppIcon.png`
- Size: 1024x1024 pixels
- Format: PNG with transparency

**Option 2: ICNS (Recommended for production)**
- File: `AppIcon.icns`
- Format: Native macOS icon bundle with multiple resolutions
- Generate from PNG using: `../scripts/create-icns.sh AppIcon.png`

### DMG Background (Optional)

For a professional DMG installer appearance:

- File: `dmg-background.png`
- Size: 600x400 pixels
- Format: PNG with transparency
- Layout: Leave space at (125, 150) and (375, 150) for app icon and Applications folder

If this file is not present, the DMG will still be created with a default appearance.

## Adding Your Assets

1. **Add App Icon to Bundler.toml:**
   ```toml
   [apps.Arcmark]
   icon = 'Resources/AppIcon.png'
   # or
   icon = 'Resources/AppIcon.icns'
   ```

2. **Place DMG background:**
   ```bash
   cp your-background.png Resources/dmg-background.png
   ```

3. **Rebuild:**
   ```bash
   ./scripts/build.sh --dmg
   ```

## Asset Guidelines

See [../docs/ASSETS.md](../docs/ASSETS.md) for detailed specifications and design guidelines.
