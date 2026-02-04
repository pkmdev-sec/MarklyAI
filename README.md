# Arcmark

A macOS bookmark management application built with Swift and AppKit. Features workspace-based organization, drag-and-drop, inline editing, and sidebar attachment to browser windows.

## Features

- 🗂️ Workspace-based organization with custom colors and emojis
- 🔗 Hierarchical folders and links
- 🎨 Automatic favicon and title fetching
- 🖱️ Drag-and-drop support
- ✏️ Inline editing
- 🪟 Sidebar attachment to browser windows (Chrome, Arc, Safari, Brave)
- 🔍 Search and filtering
- 📌 Always-on-top mode

## Requirements

- macOS 13.0 or later
- Swift 6.2 or later
- [swift-bundler](https://github.com/moreSwift/swift-bundler) (for building the app bundle)

## Installation

### Install swift-bundler

```bash
mint install stackotter/swift-bundler@main
```

Or follow the installation instructions at [swiftbundler.dev](https://swiftbundler.dev).

### Clone the repository

```bash
git clone https://github.com/yourusername/arcmark.git
cd arcmark
```

## Building and Running

### Quick Start

Use the provided convenience scripts:

```bash
# Build and run the app
./scripts/run.sh

# Build only (creates .build/bundler/Arcmark.app)
./scripts/build.sh

# Clean build artifacts
./scripts/clean.sh
```

### Manual Build Commands

```bash
# Build the app bundle
swift bundler bundle --platform macOS

# Build and run immediately
swift bundler run

# Development build (faster, no bundle required)
swift build

# Run tests
swift test
```

### Build Output

The bundled app is created at:
```
.build/bundler/Arcmark.app
```

You can open it directly:
```bash
open .build/bundler/Arcmark.app
```

## Development

### Project Structure

```
arcmark/
├── Package.swift              # Swift Package Manager configuration
├── Bundler.toml              # swift-bundler configuration
├── Sources/
│   ├── ArcmarkCore/          # Core library (all app logic)
│   │   ├── AppDelegate.swift
│   │   ├── AppModel.swift
│   │   ├── Models.swift
│   │   ├── WindowAttachmentService.swift
│   │   ├── MainViewController.swift
│   │   └── ... (all app code)
│   └── ArcmarkApp/           # Minimal executable entry point
│       └── main.swift
├── Tests/
│   └── ArcmarkTests/
├── scripts/                  # Build and run scripts
└── CLAUDE.md                 # Development guidelines for AI
```

### Development Workflow

**For regular development** (fast iteration):
```bash
swift build          # Build package
swift test          # Run tests
```

**For testing macOS-specific features** (window attachment, NSWorkspace notifications):
```bash
./scripts/run.sh    # Build and run as proper .app bundle
```

### Why Two Build Methods?

1. **`swift build`** - Fast, direct executable
   - ⚡ Faster compilation
   - ✅ Perfect for TDD and quick iteration
   - ❌ NSWorkspace notifications don't work (no bundle ID)
   - ❌ Window attachment feature won't work

2. **`swift bundler run`** - Proper macOS app bundle
   - 📦 Creates complete .app bundle with Info.plist
   - ✅ NSWorkspace notifications work
   - ✅ All macOS-specific features work
   - ⏱️ Slightly slower build

**Use `swift build` for daily development, use `swift bundler` when testing macOS integration features.**

## Architecture

Arcmark follows a unidirectional data flow pattern:

- **AppModel** - Central state manager, single source of truth
- **DataStore** - Handles JSON persistence and favicon storage
- **MainViewController** - Observes AppModel, manages UI
- **Services** - FaviconService, LinkTitleService, BrowserManager, WindowAttachmentService

All state mutations go through AppModel methods. The UI never directly modifies state.

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## Testing

```bash
# Run all tests
swift test

# Run specific test
swift test --filter ModelTests.testJSONRoundTrip

# Run tests with verbose output
swift test -v
```

## Configuration

### App Settings

Settings are stored in:
```
~/Library/Application Support/Arcmark/data.json
```

### Bundler Configuration

App bundle configuration is in [Bundler.toml](Bundler.toml):

```toml
format_version = 2

[apps.Arcmark]
identifier = 'com.arcmark.app'
product = 'Arcmark'
version = '1.0.0'
category = 'public.app-category.productivity'
```

## Accessibility Permissions

For the sidebar attachment feature to work, Arcmark needs Accessibility permissions:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add and enable **Arcmark.app**

## Troubleshooting

### "NSWorkspace notifications not firing"

Make sure you're running the bundled app (`.build/bundler/Arcmark.app`), not the direct executable from `swift run`.

```bash
# ❌ Won't work for window attachment
swift run Arcmark

# ✅ Works correctly
./scripts/run.sh
```

### "swift-bundler: command not found"

Install swift-bundler:
```bash
mint install stackotter/swift-bundler@main
```

Then reload your shell:
```bash
source ~/.zshrc  # or ~/.bashrc
```

### Clean build issues

If you encounter build issues, try cleaning:
```bash
./scripts/clean.sh
swift build
```

## Contributing

See [CLAUDE.md](CLAUDE.md) for development guidelines and architecture details.

## License

[Your License Here]

## Credits

Built with:
- [Swift Package Manager](https://swift.org/package-manager/)
- [swift-bundler](https://github.com/moreSwift/swift-bundler)
- AppKit
