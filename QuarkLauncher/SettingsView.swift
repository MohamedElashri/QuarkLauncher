import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

struct SettingsView: View {
    @ObservedObject var appStore: AppStore
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    Text("QuarkLauncher")
                        .font(.title)
                    Text("v\(getVersion())")
                        .font(.footnote)
                    Spacer()
                    Button {
                        withAnimation(LNAnimations.springSnappy) {
                            appStore.isSetting = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2.bold())
                            .foregroundStyle(.placeholder)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                
                // Background info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatically run on background: add QuarkLauncher to dock or use keyboard shortcuts to open the application window")
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)
                }
                .padding()

                Divider()
                
                // Main settings
                VStack(spacing: 20) {
                    // Fullscreen mode toggle
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Classic Launchpad (Fullscreen)")
                                .fontWeight(.medium)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Expands to full screen mode similar to macOS Launchpad")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle(isOn: $appStore.isFullscreenMode) {}
                            .toggleStyle(.switch)
                            .animation(LNAnimations.springSnappy, value: appStore.isFullscreenMode)
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    
                    // Scrolling sensitivity
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Scrolling sensitivity")
                                .fontWeight(.medium)
                            Spacer()
                        }
                        VStack(spacing: 8) {
                            Slider(value: $appStore.scrollSensitivity, in: 0.01...0.99)
                            HStack {
                                Text("Low")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("High")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    
                    // Page Navigation Shortcuts
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Page Navigation Shortcuts")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        // Current shortcuts display
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current shortcuts:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(appStore.navigationKeysDescription())
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color(.separatorColor), lineWidth: 1)
                                )
                        }
                        
                        // Key selection
                        VStack(spacing: 16) {
                            HStack(spacing: 16) {
                                // Previous page key
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Previous Page")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    
                                    Picker("Previous Page Key", selection: $appStore.previousPageKey) {
                                        Text("← Left Arrow").tag(UInt16(123))
                                        Text("↑ Up Arrow").tag(UInt16(126))
                                        Text("⇥ Tab").tag(UInt16(48))
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(.separatorColor), lineWidth: 1)
                                    )
                                }
                                
                                // Next page key
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Next Page")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    
                                    Picker("Next Page Key", selection: $appStore.nextPageKey) {
                                        Text("→ Right Arrow").tag(UInt16(124))
                                        Text("↓ Down Arrow").tag(UInt16(125))
                                        Text("⎵ Space").tag(UInt16(49))
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity)
                                    .padding(10)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(.separatorColor), lineWidth: 1)
                                    )
                                }
                            }
                            
                            // Shift modifier setting
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Require Shift modifier")
                                        .fontWeight(.medium)
                                    Text("When enabled, you will need to hold the Shift key + your chosen key.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle(isOn: $appStore.useShiftModifier) {}
                                    .toggleStyle(.switch)
                            }
                            .padding(12)
                            .background(Color(.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                }
                .padding()
                
                Divider()

                // Data import/export
                VStack(spacing: 12) {
                    Text("Data Management")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    HStack(spacing: 16) {
                        Button {
                            exportDataFolder()
                        } label: {
                            Label("Export Data", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            importDataFolder()
                        } label: {
                            Label("Import Data", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding()
                
                Divider()

                // Actions
                VStack(spacing: 12) {
                    Text("Actions")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 12) {
                        Button {
                            appStore.refresh()
                        } label: {
                            Label("Refresh Apps", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            showResetConfirm = true
                        } label: {
                            Label("Reset Layout", systemImage: "arrow.counterclockwise")
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .alert("Confirm to reset layout?", isPresented: $showResetConfirm) {
                            Button("Reset", role: .destructive) { appStore.resetLayout() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will completely reset the layout: remove all folders, clear saved order, and rescan all applications. All customizations will be lost.")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                                        
                        Button {
                            exit(0)
                        } label: {
                            Label("Quit QuarkLauncher", systemImage: "xmark.circle")
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding()
                
                Spacer(minLength: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
    
    func getVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    // MARK: - Export / Import Application Support Data
    private func supportDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("QuarkLauncher", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func exportDataFolder() {
        do {
            let sourceDir = try supportDirectoryURL()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Choose a destination folder to export QuarkLauncher data"
            if panel.runModal() == .OK, let destParent = panel.url {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let folderName = "QuarkLauncher_Export_" + formatter.string(from: Date())
                let destDir = destParent.appendingPathComponent(folderName, isDirectory: true)
                try copyDirectory(from: sourceDir, to: destDir)
            }
        } catch {
            // Ignore errors or add user notification here
        }
    }

    private func importDataFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a folder previously exported from QuarkLauncher"
        if panel.runModal() == .OK, let srcDir = panel.url {
            do {
                // Verify if it's a valid exported data directory
                guard isValidExportFolder(srcDir) else { return }
                let destDir = try supportDirectoryURL()
                // If user selected the target directory itself, skip
                if srcDir.standardizedFileURL == destDir.standardizedFileURL { return }
                try replaceDirectory(with: srcDir, at: destDir)
                // Load and refresh after import is complete
                appStore.applyOrderAndFolders()
                appStore.refresh()
            } catch {
                // Ignore errors or add user notification here
            }
        }
    }

    private func copyDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func replaceDirectory(with src: URL, at dst: URL) throws {
        let fm = FileManager.default
        // Ensure parent directory exists
        let parent = dst.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }

    private func isValidExportFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let storeURL = folder.appendingPathComponent("Data.store")
        guard fm.fileExists(atPath: storeURL.path) else { return false }
        // Try to open this database and check if it has ordering data
        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(for: TopItemData.self, PageEntryData.self, configurations: config)
            let ctx = container.mainContext
            let pageEntries = try ctx.fetch(FetchDescriptor<PageEntryData>())
            if !pageEntries.isEmpty { return true }
            let legacyEntries = try ctx.fetch(FetchDescriptor<TopItemData>())
            return !legacyEntries.isEmpty
        } catch {
            return false
        }
    }
}