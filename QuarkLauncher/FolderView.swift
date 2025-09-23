import SwiftUI
import AppKit

struct FolderView: View {
    @ObservedObject var appStore: AppStore
    @Binding var folder: FolderInfo
    // If provided, will force use icon size consistent with outer layer
    var preferredIconSize: CGFloat? = nil
    @State private var folderName: String = ""
    @State private var isEditingName = false
    @State private var forceRefreshTrigger: UUID = UUID()
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var reorderNamespaceFolder
    // Keyboard navigation
    @State private var selectedIndex: Int? = nil
    @State private var isKeyboardNavigationActive: Bool = false
    @State private var keyMonitor: Any?
    // Drag and drop related state
    @State private var draggingApp: AppInfo? = nil
    @State private var dragPreviewPosition: CGPoint = .zero
    @State private var dragPreviewScale: CGFloat = 1.2
    @State private var pendingDropIndex: Int? = nil
    @State private var scrollOffsetY: CGFloat = 0
    @State private var outOfBoundsBeganAt: Date? = nil
    @State private var hasHandedOffDrag: Bool = false
    private let outOfBoundsDwell: TimeInterval = 0.0
    
    let onClose: () -> Void
    let onLaunchApp: (AppInfo) -> Void
    
    // Optimized spacing and layout parameters
    private let spacing: CGFloat = 30
    // Dynamic column count, adaptive based on window width and minimum cell width
    @State private var columnsCount: Int = 4
    private let gridPadding: CGFloat = 16
    private let titlePadding: CGFloat = 16

    private var visualApps: [AppInfo] {
        guard let dragging = draggingApp, let pending = pendingDropIndex else { return folder.apps }
        var apps = folder.apps
        if let from = apps.firstIndex(of: dragging) {
            apps.remove(at: from)
            let insertIndex = pending
            let clamped = min(max(0, insertIndex), apps.count)
            apps.insert(dragging, at: clamped)
        }
        return apps
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Optimized folder title section
            folderTitleSection
            
            // App grid section
            GeometryReader { geo in
                appGridSection(geometry: geo)
            }
        }
        .padding()
        .background(
            FolderBackgroundView()
        )
        .transition(LNAnimations.folderOpenTransition)
        .onTapGesture {
            // When clicking non-edit area of folder view, exit edit mode if currently editing name
            if isEditingName {
                finishEditing()
            }
        }
        .onAppear {
            folderName = folder.name
            setupKeyHandlers()
            setupInitialSelection()
            // If folder was opened via Enter key, automatically enable navigation and select first item
            if appStore.openFolderActivatedByKeyboard {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                appStore.openFolderActivatedByKeyboard = false
            } else {
                isKeyboardNavigationActive = false
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if !focused && isEditingName {
                finishEditing()
            }
        }
        .onChange(of: folder.apps) { _, _ in
            clampSelection()
            // Force refresh view when app list changes
            forceRefreshTrigger = UUID()
        }
        .onChange(of: folder.name) { oldValue, newValue in
            // Listen for folder name changes, ensure UI updates immediately
            if !isEditingName {
                folderName = newValue
                // Force refresh view
                forceRefreshTrigger = UUID()
            }
        }
        .onChange(of: appStore.folderUpdateTrigger) {
            // Force refresh folder view to ensure icons and names display latest state
            forceRefreshTrigger = UUID()
            // Trigger view re-rendering
            folderName = folder.name
        }
        .onChange(of: appStore.gridRefreshTrigger) {
            // Force refresh grid view to ensure app icons and layout display latest state
            forceRefreshTrigger = UUID()
            // Trigger view re-rendering
            folderName = folder.name
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
    
    @ViewBuilder
    private var folderTitleSection: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                if isEditingName {
                    TextField("Folder Name", text: $folderName)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.title)
                        .foregroundColor(.primary)
                        .focused($isTextFieldFocused)
                        .padding()
                        .onSubmit {
                            finishEditing()
                        }
                        .onTapGesture(count: 2) {
                            finishEditing()
                        }
                        .onTapGesture {
                            finishEditing()
                        }
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded { _ in
                                    // Prevent event bubbling to parent view when clicking edit box
                                }
                        )
                } else {
                    Text(folder.name)
                        .font(.title)
                        .foregroundColor(.primary)
                        .padding()
                        .contentShape(Rectangle()) // Ensure entire area is clickable
                        .onTapGesture(count: 2) {
                            startEditing()
                        }
                        .onTapGesture {
                            // Do nothing on single click to avoid accidental triggers
                        }
                        .id(forceRefreshTrigger) // Use forceRefreshTrigger to force refresh
                }
            }
            Spacer()
        }
        .padding(.horizontal, titlePadding)
    }
    
    @ViewBuilder
    private func appGridSection(geometry geo: GeometryProxy) -> some View {
        // Initial estimation (using current column count)
        let baseColumnWidth = computeColumnWidth(containerWidth: geo.size.width, columns: columnsCount)
        let baseAppHeight = computeAppHeight(containerHeight: geo.size.height, columns: columnsCount)
        let computedIcon = min(baseColumnWidth, baseAppHeight) * 0.75
        let iconSize: CGFloat = preferredIconSize ?? computedIcon
        // Fixed to 6 columns
        let desiredColumns = 6
        // Use adaptive column count to recalculate dimensions
        let recomputedColumnWidth = computeColumnWidth(containerWidth: geo.size.width, columns: desiredColumns)
        let recomputedAppHeight = computeAppHeight(containerHeight: geo.size.height, columns: desiredColumns)
        // Ensure cell can at least contain passed icon size and label area
        let columnWidth = max(recomputedColumnWidth, iconSize)
        let appHeight = max(recomputedAppHeight, iconSize + 32)
        let labelWidth: CGFloat = columnWidth * 0.9

        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: desiredColumns), spacing: spacing) {
                    ForEach(Array(visualApps.enumerated()), id: \.element.id) { (idx, app) in
                        appDraggable(
                            app: app,
                            appIndex: idx,
                            containerSize: geo.size,
                            columnWidth: columnWidth,
                            appHeight: appHeight,
                            iconSize: iconSize,
                            labelWidth: labelWidth,
                            isSelected: isKeyboardNavigationActive && selectedIndex == idx
                        )
                    }
                }
                .animation(LNAnimations.gridUpdate, value: pendingDropIndex)
                .animation(LNAnimations.gridUpdate, value: folder.apps)
                .id(forceRefreshTrigger) // Use forceRefreshTrigger to force refresh app grid
                .padding(EdgeInsets(top: gridPadding, leading: gridPadding, bottom: gridPadding, trailing: gridPadding))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: FolderScrollOffsetPreferenceKey.self,
                            value: -proxy.frame(in: .named("folderGrid")).origin.y
                        )
                    }
                )
            }
            .scrollIndicators(.hidden)
            .disabled(isEditingName) // Disable scrolling in edit mode
            .onAppear { columnsCount = desiredColumns }
            .onChange(of: geo.size) {
                columnsCount = desiredColumns
            }
            
            // Drag preview layer
            if let draggingApp {
                DragPreviewItem(item: .app(draggingApp),
                                iconSize: iconSize,
                                labelWidth: labelWidth,
                                scale: dragPreviewScale)
                    .position(x: dragPreviewPosition.x, y: dragPreviewPosition.y)
                    .zIndex(100)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "folderGrid")
        .onPreferenceChange(FolderScrollOffsetPreferenceKey.self) { scrollOffset in
            scrollOffsetY = scrollOffset
        }
    }
    
    // Drag visual reordering
    
    private func startEditing() {
        isEditingName = true
        folderName = folder.name
        isTextFieldFocused = true
        appStore.isFolderNameEditing = true
    }
    
    private func finishEditing() {
        isEditingName = false
        appStore.isFolderNameEditing = false
        if !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let newName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName != folder.name {
                appStore.renameFolder(folder, newName: newName)
            }
        } else {
            folderName = folder.name
        }
    }
    
}

// MARK: - Drag helpers & builders (mirror outer logic, without folder creation)
extension FolderView {
    private func computeAppHeight(containerHeight: CGFloat, columns: Int) -> CGFloat {
        // Estimate row height under adaptive column count
        let maxRowsPerPage = Int(ceil(Double(folder.apps.count) / Double(max(columns, 1))))
        let totalRowSpacing = spacing * CGFloat(max(0, maxRowsPerPage - 1))
        let height = (containerHeight - totalRowSpacing) / CGFloat(maxRowsPerPage == 0 ? 1 : maxRowsPerPage)
        return max(60, min(120, height)) // Optimize height range
    }
    
    private func computeColumnWidth(containerWidth: CGFloat, columns: Int) -> CGFloat {
        let cols = max(columns, 1)
        let totalColumnSpacing = spacing * CGFloat(max(0, cols - 1))
        let width = (containerWidth - totalColumnSpacing) / CGFloat(cols)
        return max(50, width) // Optimize minimum width
    }

    // Drag hit testing and cell geometry calculation (implemented in extension below)

    @ViewBuilder
    private func appDraggable(app: AppInfo,
                              appIndex: Int,
                              containerSize: CGSize,
                              columnWidth: CGFloat,
                              appHeight: CGFloat,
                              iconSize: CGFloat,
                              labelWidth: CGFloat,
                              isSelected: Bool) -> some View {
        let base = LaunchpadItemButton(
            item: .app(app),
            iconSize: iconSize,
            labelWidth: labelWidth,
            isSelected: isSelected,
            shouldAllowHover: draggingApp == nil,
            onTap: { 
                // Don't launch app in edit mode
                if draggingApp == nil && !isEditingName { 
                    onLaunchApp(app) 
                }
            }
        )
        .frame(height: appHeight)
        .matchedGeometryEffect(id: app.id, in: reorderNamespaceFolder)

        let isDraggingThisTile = (draggingApp == app)

        base
            .opacity(isDraggingThisTile ? 0 : 1)
            .allowsHitTesting(!isDraggingThisTile)
            .animation(LNAnimations.springFast, value: isSelected)
            .simultaneousGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("folderGrid"))
                    .onChanged { value in
                        // Disable dragging in edit mode
                        if isEditingName { return }
                        
                        if draggingApp == nil {
                            var tx = Transaction(); tx.disablesAnimations = true
                            withTransaction(tx) { draggingApp = app }
                            isKeyboardNavigationActive = false // Disable keyboard navigation

                            // Center drag preview with pointer position, avoid any offset
                            dragPreviewPosition = value.location
                        }

                        // Preview follows pointer position (no initial offset), ensure cursor aligns with icon center
                        dragPreviewPosition = value.location

                        // Detect if dragged outside folder bounds and dwell
                        let isOutside: Bool = (value.location.x < 0 || value.location.y < 0 ||
                                               value.location.x > containerSize.width ||
                                               value.location.y > containerSize.height)
                        let now = Date()
                        if isOutside {
                            if outOfBoundsBeganAt == nil { outOfBoundsBeganAt = now }
                            if !hasHandedOffDrag, let start = outOfBoundsBeganAt, now.timeIntervalSince(start) >= outOfBoundsDwell, let dragging = draggingApp {
                                // Hand off to outer layer: move app out of folder and close folder
                                hasHandedOffDrag = true
                                pendingDropIndex = nil
                                appStore.handoffDraggingApp = dragging
                                appStore.handoffDragScreenLocation = NSEvent.mouseLocation
                                appStore.removeAppFromFolder(dragging, folder: folder)
                                // Clean up internal drag state and close folder
                                draggingApp = nil
                                outOfBoundsBeganAt = nil
                                withAnimation(LNAnimations.springFast) {
                                    onClose()
                                }
                                return
                            }
                        } else {
                            outOfBoundsBeganAt = nil
                        }

                        if let hoveringIndex = indexAt(point: dragPreviewPosition,
                                                       containerSize: containerSize,
                                                       columnWidth: columnWidth,
                                                       appHeight: appHeight) {
                            // Treat "hovering over last cell" as insertion at end, pushing last one forward
                            let count = visualApps.count
                            if count > 0,
                               hoveringIndex == count - 1,
                               let dragging = draggingApp,
                               dragging != visualApps[hoveringIndex] {
                                pendingDropIndex = count // End slot
                            } else {
                                // If hit "end slot" (== count), keep as count; otherwise use cell index
                                pendingDropIndex = hoveringIndex
                            }
                        } else {
                            pendingDropIndex = nil
                        }
                    }
                    .onEnded { _ in
                        // Don't handle drag end in edit mode
                        if isEditingName { return }
                        
                        guard let dragging = draggingApp else { return }
                        defer {
                            // Battery-optimized: increased delay for cleanup operations
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                draggingApp = nil
                                pendingDropIndex = nil
                                // Don't automatically restore keyboard navigation after drag ends, maintain consistent experience
                            }
                        }

                        // If already handed off to outer layer, don't handle drop here
                        if hasHandedOffDrag {
                            hasHandedOffDrag = false
                            outOfBoundsBeganAt = nil
                            return
                        }

                        if let finalIndex = pendingDropIndex {
                            // Visual snap position: use finalIndex directly, ensure accurate snap to target position
                            let dropDisplayIndex = finalIndex
                            let targetCenter = cellCenter(for: dropDisplayIndex,
                                                          containerSize: containerSize,
                                                          columnWidth: columnWidth,
                                                          appHeight: appHeight)
                            withAnimation(LNAnimations.dragPreview) {
                                dragPreviewPosition = targetCenter
                                dragPreviewScale = 1.0
                            }
                            if let from = folder.apps.firstIndex(of: dragging) {
                                var apps = folder.apps
                                apps.remove(at: from)
                                // Completely consistent with visual preview: use hover index directly
                                let insertIndex = finalIndex
                                let clamped = min(max(0, insertIndex), apps.count)
                                apps.insert(dragging, at: clamped)
                                folder.apps = apps
                                appStore.saveAllOrder()
                                
                                // Battery-optimized: also trigger compaction after folder internal drag ends
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    appStore.compactItemsWithinPages()
                                }
                            }
                        }
                    }
            )
    }
}

// MARK: - Drag geometry & hit-testing (folder internal)
extension FolderView {
    private func cellOrigin(for index: Int,
                            containerSize: CGSize,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        return GeometryUtils.cellOrigin(for: index,
                                      containerSize: containerSize,
                                      pageIndex: 0,
                                      columnWidth: columnWidth,
                                      appHeight: appHeight,
                                      columns: max(columnsCount, 1),
                                      columnSpacing: spacing,
                                      rowSpacing: spacing,
                                      pageSpacing: 0,
                                      currentPage: 0,
                                      gridPadding: gridPadding,
                                      scrollOffsetY: scrollOffsetY)
    }

    private func cellCenter(for index: Int,
                            containerSize: CGSize,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let origin = cellOrigin(for: index, containerSize: containerSize, columnWidth: columnWidth, appHeight: appHeight)
        return CGPoint(x: origin.x + columnWidth / 2, y: origin.y + appHeight / 2)
    }

    private func indexAt(point: CGPoint,
                         containerSize: CGSize,
                         columnWidth: CGFloat,
                         appHeight: CGFloat) -> Int? {
        guard let offsetInPage = GeometryUtils.indexAt(point: point,
                                                      containerSize: containerSize,
                                                      pageIndex: 0,
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight,
                                                      columns: max(columnsCount, 1),
                                                      columnSpacing: spacing,
                                                      rowSpacing: spacing,
                                                      pageSpacing: 0,
                                                      currentPage: 0,
                                                      itemsPerPage: visualApps.count,
                                                      gridPadding: gridPadding,
                                                      scrollOffsetY: scrollOffsetY) else { return nil }
        
        let count = visualApps.count
        // Allow returning count as "end slot" to enable dropping after the last item
        if count == 0 { return 0 }
        return min(max(offsetInPage, 0), count)
    }
}

// MARK: - Folder scroll offset preference key
private struct FolderScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
// MARK: - Keyboard navigation (mirror outer behavior)
extension FolderView {
    private func setupKeyHandlers() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyEvent(event)
        }
    }

    private func setupInitialSelection() {
        if selectedIndex == nil, folder.apps.indices.first != nil {
            selectedIndex = 0
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Allow input when editing folder name
        if isTextFieldFocused { return event }

        // Esc closes folder
        if event.keyCode == 53 {
            onClose()
            return nil
        }

        // Enter: activate or launch selection
        if event.keyCode == 36 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            if let idx = selectedIndex, folder.apps.indices.contains(idx) {
                onLaunchApp(folder.apps[idx])
                return nil
            }
            return event
        }

        // Tab: same as Enter, activate keyboard navigation first
        if event.keyCode == 48 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            return event
        }

        // Down arrow: activate navigation first
        if event.keyCode == 125 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            moveSelection(dx: 0, dy: 1)
            return nil
        }

        // Left/right/general arrows
        if let (dx, dy) = arrowDelta(for: event.keyCode) {
            guard isKeyboardNavigationActive else { return event }
            moveSelection(dx: dx, dy: dy)
            return nil
        }

        return event
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard let current = selectedIndex else { return }
        let columnsCount = max(columnsCount, 1)
        let newIndex: Int = dy == 0 ? current + dx : current + dy * columnsCount
        guard folder.apps.indices.contains(newIndex) else { return }
        selectedIndex = newIndex
    }

    private func setSelectionToStart() {
        if let first = folder.apps.indices.first {
            selectedIndex = first
        } else {
            selectedIndex = nil
        }
    }

    private func clampSelection() {
        let count = folder.apps.count
        if count == 0 { selectedIndex = nil; return }
        if let idx = selectedIndex {
            if idx >= count { selectedIndex = count - 1 }
            if idx < 0 { selectedIndex = 0 }
        } else {
            selectedIndex = 0
        }
    }
}

// MARK: - Folder Background View (Original macOS Style)
struct FolderBackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Background with original Launchpad folder styling
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 30))
                .overlay(
                    RoundedRectangle(cornerRadius: 30)
                        .strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.20), 
                            lineWidth: 0.5
                        )
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.8 : 0.3),
                    radius: 20,
                    y: 12
                )
        }
    }
}
