import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData

// MARK: - Main Settings View
struct SettingsView: View {
    @ObservedObject var appStore: AppStore
    @State private var showResetConfirm = false
    @State private var selectedTab: Int? = 0
    
    var body: some View {
        NavigationView {
            // Sidebar navigation
            List {
                NavigationLink("General", destination: GeneralSettingsView(appStore: appStore))
                NavigationLink("Appearance", destination: AppearanceSettingsView(appStore: appStore))
                NavigationLink("Navigation", destination: NavigationSettingsView(appStore: appStore))
                NavigationLink("Data", destination: DataManagerView(appStore: appStore))
                NavigationLink("Actions", destination: ActionSettingsView(appStore: appStore, showResetConfirm: $showResetConfirm))
            }
            .listStyle(SidebarListStyle())
            .navigationTitle("Settings")
            
            // Default view when no tab is selected
            GeneralSettingsView(appStore: appStore)
        }
        .alert("Confirm to reset layout?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { appStore.resetLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will completely reset the layout: remove all folders, clear saved order, and rescan all applications. All customizations will be lost.")
        }
        .frame(minWidth: 700, minHeight: 500) // Set minimum size
    }
}

// MARK: - Reusable Components
struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content
    
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }
}

// MARK: - General Settings View
struct GeneralSettingsView: View {
    @ObservedObject var appStore: AppStore
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("QuarkLauncher")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("v\(getVersion())")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Text("A modern launcher for macOS")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 10)
                
                // Info section
                SettingsCard("About") {
                    Text("Automatically run in background: add QuarkLauncher to dock or use keyboard shortcuts to open the application window")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                // General settings
                SettingsCard("Display") {
                    Toggle("Classic Launchpad (Fullscreen)", isOn: $appStore.isFullscreenMode)
                        .toggleStyle(.switch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("Expands to full screen mode similar to macOS Launchpad")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                // Scrolling settings
                SettingsCard("Scrolling") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Sensitivity")
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(Int(appStore.scrollSensitivity * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $appStore.scrollSensitivity, in: 0.01...0.99)
                        
                        HStack {
                            Text("Low")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("High")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("General")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    func getVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }
}

// MARK: - Appearance Settings View
struct AppearanceSettingsView: View {
    @ObservedObject var appStore: AppStore
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Theme") {
                    Picker("Appearance", selection: $appStore.themePreference) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Appearance")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Navigation Settings View
struct NavigationSettingsView: View {
    @ObservedObject var appStore: AppStore
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Shortcuts") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Current shortcuts display
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current navigation shortcuts:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
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
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    
                                    Picker("Previous Page Key", selection: $appStore.previousPageKey) {
                                        Text("← Left Arrow").tag(UInt16(123))
                                        Text("↑ Up Arrow").tag(UInt16(126))
                                        Text("⇥ Tab").tag(UInt16(48))
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                                
                                // Next page key
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Next Page")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    
                                    Picker("Next Page Key", selection: $appStore.nextPageKey) {
                                        Text("→ Right Arrow").tag(UInt16(124))
                                        Text("↓ Down Arrow").tag(UInt16(125))
                                        Text("⎵ Space").tag(UInt16(49))
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity)
                                    .padding(8)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                            
                            // Shift modifier setting
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle("Require Shift modifier", isOn: $appStore.useShiftModifier)
                                    
                                    Text("When enabled, you will need to hold the Shift key + your chosen key.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Navigation")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Data Manager View
struct DataManagerView: View {
    @ObservedObject var appStore: AppStore
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Data Management") {
                    VStack(spacing: 16) {
                        Button(action: exportDataFolder) {
                            Label("Export Data", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Button(action: importDataFolder) {
                            Label("Import Data", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Data")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Action Settings View
struct ActionSettingsView: View {
    @ObservedObject var appStore: AppStore
    @Binding var showResetConfirm: Bool
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Actions") {
                    VStack(spacing: 16) {
                        Button(action: {
                            appStore.refresh()
                        }) {
                            Label("Refresh Apps", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        
                        Button(action: {
                            showResetConfirm = true
                        }) {
                            Label("Reset Layout", systemImage: "arrow.counterclockwise")
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        
                        Button(action: {
                            exit(0)
                        }) {
                            Label("Quit QuarkLauncher", systemImage: "xmark.circle")
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Actions")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(appStore: AppStore())
    }
}