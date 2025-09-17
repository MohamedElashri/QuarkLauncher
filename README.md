# QuarkLauncher

A modern, customizable Launchpad replacement for macOS that gives you better control over application organization and launching experience. It works on macOS 26. 


Here is a screen capture of QuarkLauncher in action:
<div style="text-align: center;">
  <img src="/img/app_screenshot.png" alt="QuarkLauncher Demo" style="width: 50%; max-width: 300px; height: auto;">
</div>



## Features

- **Customizable Layout**: Organize apps in folders and arrange them exactly how you want
- **Two Display Modes**: 
  - Classic fullscreen mode (similar to macOS Launchpad)
  - Windowed mode for multitasking
- **Keyboard Navigation**: Navigate and launch apps using customizable keyboard shortcuts
- **Folder Management**: Create folders to organize  applications
- **Drag & Drop**: Rearrange apps and create folders by dragging apps together
- **Search Integration**: Automatically scans multiple application directories including:
  - `/Applications`
  - `~/Applications` 
  - System applications
  - `Homebrew Cask` installations
- **Import/Export**: Backup and restore layout configurations
- **Auto-refresh**: Automatically detects new applications as they're installed

## Requirements

- macOS 26.0 (Tahoe) or later
- Xcode 26+ (for building from source)

## Building from Source

Since pre-built binaries are not yet available, you'll need to compile QuarkLauncher yourself:

1. **Clone the repository**:
   ```bash
   git clone https://github.com/MohamedElashri/QuarkLauncher
   cd QuarkLauncher
   ```

2. **Open in Xcode**:
   ```bash
   open QuarkLauncher.xcodeproj
   ```

3. **Build and Run**:
   - Select a target device (Mac Device)
   - Press `Cmd + R` to build and run
   - Or use `Cmd + B` to build only

4. **Create Release Build** (Optional):
   - In Xcode, go to Product → Archive
   - Follow the archive process to create a distributable app

## Usage

### First Launch
- When you first run QuarkLauncher, it will automatically scan your system for applications
- The app runs in the background - add it to your Dock or use the menu bar to access it

### Navigation
- **Page Navigation**: Use arrow keys (customizable in settings) to move between pages
- **App Launch**: Click on any app icon to launch it
- **Folder Access**: Click on folders to open them and browse contained apps
- **Search**: Start typing to filter applications

### Creating Folders
- Drag one app onto another to create a folder
- Double-click folder names to rename them
- Drag apps in and out of folders to organize them

### Settings
- Access settings/preferences through the app menu or by clicking on three dots in the top right corner of the window
- Customize keyboard shortcuts for page navigation
- Toggle between windowed and fullscreen modes
- Adjust scroll sensitivity
- Import/export layout configuration

### Keyboard Shortcuts
- **Arrow Keys**: Navigate between pages (customizable, but default is left/right arrows)
- **Enter/Return**: Launch selected app
- **Escape**: Close folders or exit fullscreen mode
- **Tab**: Navigate between pages

## Configuration

QuarkLauncher stores its configuration and layout data in:
```
~/Library/Application Support/QuarkLauncher/
```

You can backup this folder to preserve your custom layouts and settings.

## Coming Soon

- Pre-built binary releases for easier installation
- Additional customization options
- Enhanced search capabilities
- More keyboard shortcuts
- Performance optimizations (to make it faster and more responsive)

## Support

For questions, bug reports, or feature requests please open an issue on the [GitHub repository](https://github.com/MohamedElashri/QuarkLauncher/issues).


## License

This project is source-available but not open source. See the [LICENSE](LICENSE) file for details.