import SwiftUI
import Combine
import AppKit

// MARK: - LaunchpadItem extension
extension LaunchpadItem {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

// MARK: - Simplified Page Flip Manager
private class PageFlipManager: ObservableObject {
    @Published var isCooldown: Bool = false
    private var lastFlipTime: Date?
    var autoFlipInterval: TimeInterval = 1.2 // Battery-optimized: increased from 0.8s
    
    func canFlip() -> Bool {
        guard !isCooldown else { return false }
        guard let lastTime = lastFlipTime else { return true }
        return Date().timeIntervalSince(lastTime) >= autoFlipInterval
    }
    
    func recordFlip() {
        lastFlipTime = Date()
        isCooldown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // Battery-optimized: increased from 0.05s
            self.isCooldown = false
        }
    }
}

struct LaunchpadView: View {
    @ObservedObject var appStore: AppStore
    @State private var keyMonitor: Any?
    @State private var windowObserver: NSObjectProtocol?
    @State private var windowHiddenObserver: NSObjectProtocol?
    @State private var draggingItem: LaunchpadItem?
    @State private var dragPreviewPosition: CGPoint = .zero
    @State private var dragPreviewScale: CGFloat = 1.2
    @State private var pendingDropIndex: Int? = nil
    @StateObject private var pageFlipManager = PageFlipManager()
    @State private var folderHoverCandidateIndex: Int? = nil
    @State private var folderHoverBeganAt: Date? = nil
    @State private var selectedIndex: Int? = nil
    @State private var isKeyboardNavigationActive: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var reorderNamespace
    @State private var handoffEventMonitor: Any? = nil
    @State private var globalMouseUpMonitor: Any? = nil
    @State private var gridOriginInWindow: CGPoint = .zero
    @State private var currentContainerSize: CGSize = .zero
    @State private var currentColumnWidth: CGFloat = 0
    @State private var currentAppHeight: CGFloat = 0
    @State private var currentIconSize: CGFloat = 0
    
    // Simplified geometry caching - removed complex caching system for better performance
    private static var simpleLayoutCache: (size: CGSize, isFullscreen: Bool, result: (width: CGFloat, height: CGFloat, iconSize: CGFloat))? = nil
    @State private var isHandoffDragging: Bool = false
    @State private var isUserSwiping: Bool = false
    @State private var accumulatedScrollX: CGFloat = 0
    @State private var wheelAccumulatedSinceFlip: CGFloat = 0
    @State private var wheelLastDirection: Int = 0
    @State private var wheelLastFlipAt: Date? = nil
    private let wheelFlipCooldown: TimeInterval = 0.15

    private var isFolderOpen: Bool { appStore.openFolder != nil }
    
    private var config: GridConfig {
        GridConfig(isFullscreen: appStore.isFullscreenMode)
    }
    
    var filteredItems: [LaunchpadItem] {
        let q = appStore.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return appStore.items }
        return appStore.searchResults
    }
    
    var pages: [[LaunchpadItem]] {
        let items = draggingItem != nil ? visualItems : filteredItems
        return makePages(from: items)
    }
    
    private var currentItems: [LaunchpadItem] {
        draggingItem != nil ? visualItems : filteredItems
    }
    
    private var visualItems: [LaunchpadItem] {
        guard let dragging = draggingItem else { return filteredItems }
        
        // When creating a folder, keep the current visual arrangement but don't do any reordering
        if appStore.isDragCreatingFolder {
            return filteredItems
        }
        
        guard let pending = pendingDropIndex else { return filteredItems }
        let itemsPerPage = config.itemsPerPage
        var pageSlices: [[LaunchpadItem]] = makePages(from: filteredItems)

        let sourcePage = pageSlices.firstIndex { $0.contains(dragging) }
        let sourceIndexInPage = sourcePage.flatMap { pageSlices[$0].firstIndex(of: dragging) }
        let targetPage = max(0, pending / itemsPerPage)
        let localIndexDesired = pending % itemsPerPage

        if let sPage = sourcePage, sPage == targetPage, let sIdx = sourceIndexInPage {
            pageSlices[sPage].remove(at: sIdx)
        }

        while pageSlices.count <= targetPage { pageSlices.append([]) }
        let localIndex = max(0, min(localIndexDesired, pageSlices[targetPage].count))
        pageSlices[targetPage].insert(dragging, at: localIndex)

        var p = targetPage
        while p < pageSlices.count {
            if pageSlices[p].count > itemsPerPage {
                let spilled = pageSlices[p].removeLast()
                if p + 1 >= pageSlices.count { pageSlices.append([]) }
                pageSlices[p + 1].insert(spilled, at: 0)
                p += 1
            } else {
                p += 1
            }
        }
        return pageSlices.flatMap { $0 }
    }
    
    private func makePages(from items: [LaunchpadItem]) -> [[LaunchpadItem]] {
        guard !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: config.itemsPerPage).map { start in
            let end = min(start + config.itemsPerPage, items.count)
            return Array(items[start..<end])
        }
    }
    
    var body: some View {
        GeometryReader { geo in
            let actualTopPadding = config.isFullscreen ? geo.size.height * config.topPadding : 0
            let actualBottomPadding = config.isFullscreen ? geo.size.height * config.bottomPadding : 0
            let actualHorizontalPadding = config.isFullscreen ? geo.size.width * config.horizontalPadding : 0
            
            VStack {
                // Add dynamic padding above the grid
                if config.isFullscreen {
                    Spacer()
                        .frame(height: actualTopPadding)
                }
                HStack(spacing: 8) {
                    TextField("Search", text: $appStore.searchText, prompt: Text("Search").foregroundColor(.secondary))
                    .disabled(isFolderOpen)
                    .onChange(of: appStore.searchText) {
                        guard !isFolderOpen else { return }
                        appStore.currentPage = 0
                        selectedIndex = filteredItems.isEmpty ? nil : 0
                        isKeyboardNavigationActive = false
                        clampSelection()
                        let maxPageIndex = max(pages.count - 1, 0)
                        if appStore.currentPage > maxPageIndex {
                            appStore.currentPage = maxPageIndex
                        }
                    }
                    .focused($isSearchFieldFocused)
                    .font(.title2)
                    .textFieldStyle(.roundedBorder)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.05))
                    )
                    Spacer()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Clicking empty space in the top bar removes focus from search
                            isSearchFieldFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    
                    Button {
                        AppDelegate.shared?.showSettingsAction()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(width: 32, height: 32)
                    )
                }
                .padding(.top)
                .padding(.horizontal)
                .opacity(isFolderOpen ? 0.1 : 1)
                .allowsHitTesting(!isFolderOpen)
                
                Divider()
                    .background(Color.primary.opacity(0.1))
                    .padding(.horizontal)
                    .opacity(isFolderOpen ? 0.1 : 1)
                
                GeometryReader { geo in
                    let layoutConfig = calculateOptimizedLayout(for: geo, actualTopPadding: actualTopPadding, actualBottomPadding: actualBottomPadding)
                    let appCountPerRow = config.columns
                    let _ = Int(ceil(Double(config.itemsPerPage) / Double(appCountPerRow)))
                    let _ = geo.size.width
                    let _ = geo.size.height - (actualTopPadding + actualBottomPadding)
                    
                    let appHeight = layoutConfig.height
                    let columnWidth = layoutConfig.width
                    let iconSize = layoutConfig.iconSize

                    let effectivePageWidth = geo.size.width + config.pageSpacing

                    if filteredItems.isEmpty && !appStore.searchText.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.placeholder)
                            Text("No apps found")
                                .font(.title)
                                .foregroundStyle(.placeholder)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let hStackOffset = -CGFloat(appStore.currentPage) * effectivePageWidth
                        ZStack(alignment: .topLeading) {
                            // Content
                            HStack(spacing: config.pageSpacing) {
                                ForEach(pages.indices, id: \.self) { index in
                                    VStack(alignment: .leading, spacing: 0) {
                                        // Add dynamic padding above the grid
                                        if config.isFullscreen {
                                            Spacer()
                                                .frame(height: actualTopPadding)
                                        }
                                        LazyVGrid(columns: config.gridItems, spacing: config.rowSpacing) {
                                            ForEach(Array(pages[index].enumerated()), id: \.element.id) { (localOffset, item) in
                                                let globalIndex = index * config.itemsPerPage + localOffset
                                                itemDraggable(
                                                    item: item,
                                                    globalIndex: globalIndex,
                                                    pageIndex: index,
                                                    containerSize: geo.size,
                                                    columnWidth: columnWidth,
                                                    iconSize: iconSize,
                                                    appHeight: appHeight,
                                                    labelWidth: columnWidth * 0.9,
                                                    isSelected: (!isFolderOpen && isKeyboardNavigationActive && selectedIndex == globalIndex)
                                                )
                                            }
                                        }
                                        // Separate animations to prevent conflicts and improve performance
                                        .animation(LNAnimations.gridUpdate, value: pendingDropIndex)
                                        .animation(LNAnimations.gridUpdate, value: appStore.gridRefreshTrigger)
                                        // Use the ultra-fast fullscreen transition animation
                                        .animation(LNAnimations.fullscreenTransition, value: appStore.isFullscreenMode)
                                        .frame(maxHeight: .infinity, alignment: .top)
                                    }
                                    .frame(width: geo.size.width, height: geo.size.height)
                                }
                            }
                            .offset(x: hStackOffset)
                            .opacity(isFolderOpen ? 0.1 : 1)
                            .allowsHitTesting(!isFolderOpen)
                            

                            // 将预览提升到外层坐标空间，避免受到 offset 影响
                            if let draggingItem {
                                DragPreviewItem(item: draggingItem, iconSize: iconSize, labelWidth: columnWidth * 0.9, scale: dragPreviewScale)
                                    .position(x: dragPreviewPosition.x, y: dragPreviewPosition.y)
                                    .zIndex(100)
                                    .allowsHitTesting(false)
                            }
                        }
                        
                        .coordinateSpace(name: "grid")
                        .onTapGesture {
                            // Clicking anywhere in the grid removes focus from search
                            isSearchFieldFocused = false
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                        .onAppear { }
                        
                        .onChange(of: appStore.handoffDraggingApp) {
                            if appStore.openFolder == nil, appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.openFolder) {
                            // Defocus search when opening a folder
                            if appStore.openFolder != nil {
                                isSearchFieldFocused = false
                                NSApp.keyWindow?.makeFirstResponder(nil)
                            } else if appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.currentPage) {
                            DispatchQueue.main.async {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                                
                                // 智能预加载当前页面和相邻页面的图标
                                AppCacheManager.shared.smartPreloadIcons(
                                    for: appStore.items,
                                    currentPage: appStore.currentPage,
                                    itemsPerPage: config.itemsPerPage
                                )
                            }
                        }
                        .onChange(of: geo.size) {
                            DispatchQueue.main.async {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .task {
                            await MainActor.run {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                    }
                }
                
                // Merged PageIndicator - add tap to jump to page
                if pages.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Circle()
                                .fill(appStore.currentPage == index ? Color.primary : Color.primary.opacity(0.3))
                                .frame(width: 6, height: 6)
                                .scaleEffect(appStore.currentPage == index ? 1.2 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appStore.currentPage)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Defocus search when interacting with page dots
                                    isSearchFieldFocused = false
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    navigateToPage(index)
                                }
                        }
                    }
                    .opacity(isFolderOpen ? 0.1 : 1)
                    .allowsHitTesting(!isFolderOpen)
                }
                
                // Add dynamic padding below the page indicator dots
                if config.isFullscreen {
                    Spacer()
                        .frame(height: actualBottomPadding)
                }

            }
            .padding(.horizontal, actualHorizontalPadding)
        }
        .padding()
        .background(
            LaunchpadBackgroundView(isFullscreen: appStore.isFullscreenMode)
        )
        // Add explicit animation for corner radius changes to match window animation
        .animation(LNAnimations.fullscreenTransition, value: appStore.isFullscreenMode)
        .ignoresSafeArea()
        .overlay(
            ZStack {
                // Full-window scroll capture layer (does not intercept clicks, only listens for scrolls)
                ScrollEventCatcher { deltaX, deltaY, phase, isMomentum, isPrecise in
                    let pageWidth = currentContainerSize.width + config.pageSpacing
                    handleScroll(deltaX: deltaX,
                                 deltaY: deltaY,
                                 phase: phase,
                                 isMomentum: isMomentum,
                                 isPrecise: isPrecise,
                                 pageWidth: pageWidth)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Semi-transparent background: persistent, clickability controlled by state, avoids intercepting clicks during animation exit
                Color.black
                    .opacity(isFolderOpen ? 0.1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(isFolderOpen)
                    .onTapGesture {
                        // If editing folder name, do not close folder
                        if !appStore.isFolderNameEditing {
                            let closingFolder = appStore.openFolder
                            withAnimation(LNAnimations.springFast) {
                                appStore.openFolder = nil
                            }
                            // After closing, switch the keyboard navigation selection to the folder
                            if let folder = closingFolder,
                               let idx = filteredItems.firstIndex(of: .folder(folder)) {
                                isKeyboardNavigationActive = true
                                selectedIndex = idx
                                let targetPage = idx / config.itemsPerPage
                                if targetPage != appStore.currentPage {
                                    appStore.currentPage = targetPage
                                }
                            }
                            // Do not auto-focus the search field; respect user's focus
                        }
                    }

                if let openFolder = appStore.openFolder {
                    GeometryReader { proxy in
                        let targetWidth = proxy.size.width * 0.7
                        let targetHeight = proxy.size.height * 0.7
                        let folderId = openFolder.id

                        // Use computed properties to ensure binding responds correctly to folderUpdateTrigger changes
                        let folderBinding = Binding<FolderInfo>(
                            get: {
                                // Re-find the folder each time to ensure the latest state is retrieved
                                if let idx = appStore.folders.firstIndex(where: { $0.id == folderId }) {
                                    return appStore.folders[idx]
                                }
                                return openFolder
                            },
                            set: { newValue in
                                if let idx = appStore.folders.firstIndex(where: { $0.id == folderId }) {
                                    appStore.folders[idx] = newValue
                                }
                            }
                        )
                        
                        FolderView(
                            appStore: appStore,
                            folder: folderBinding,
                            preferredIconSize: currentIconSize,
                            onClose: {
                                let closingFolder = appStore.openFolder
                                withAnimation(LNAnimations.springFast) {
                                    appStore.openFolder = nil
                                }
                                // After closing, switch the keyboard navigation selection to the folder
                                if let folder = closingFolder,
                                   let idx = filteredItems.firstIndex(of: .folder(folder)) {
                                    isKeyboardNavigationActive = true
                                    selectedIndex = idx
                                    let targetPage = idx / config.itemsPerPage
                                    if targetPage != appStore.currentPage {
                                        appStore.currentPage = targetPage
                                    }
                                }
                                // Do not auto-focus the search field; respect user's focus
                            },
                            onLaunchApp: { app in
                                launchApp(app)
                            }
                        )
                        .frame(width: targetWidth, height: targetHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .id("folder_\(folderId)") // Use stable ID to avoid view reconstruction on updates
                        
                    }
                }
            }
        )
        // Defocus search on any tap in empty areas or background
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            if isSearchFieldFocused {
                isSearchFieldFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        })
         .onChange(of: appStore.items) {
             guard draggingItem == nil else { return }
             clampSelection()
             let maxPageIndex = max(pages.count - 1, 0)
             if appStore.currentPage > maxPageIndex {
                 appStore.currentPage = maxPageIndex
             }
          }
          .onChange(of: appStore.isSetting) { _, isOpen in
              if isOpen {
                  // Defocus search when opening settings
                  isSearchFieldFocused = false
                  NSApp.keyWindow?.makeFirstResponder(nil)
              }
          }
          .onChange(of: isSearchFieldFocused) { _, focused in
             if focused { isKeyboardNavigationActive = false }
         }

           .onAppear {
               appStore.performInitialScanIfNeeded()
               setupKeyHandlers()
               setupInitialSelection()
               setupWindowShownObserver()
               setupWindowHiddenObserver()
               // Listen for global mouse up events to ensure drag state is properly cleared (when released outside the window)
               if let existing = globalMouseUpMonitor { NSEvent.removeMonitor(existing) }
               globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
                   if handoffEventMonitor != nil || draggingItem != nil {
                       finalizeHandoffDrag()
                   }
                   // Battery-optimized: increased delay for drag cleanup
                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                       if draggingItem != nil {
                           draggingItem = nil
                           pendingDropIndex = nil
                           appStore.isDragCreatingFolder = false
                           appStore.folderCreationTarget = nil
                           pageFlipManager.isCooldown = false
                           isHandoffDragging = false
                           clampSelection()
                       }
                   }
               }
               isKeyboardNavigationActive = false
               clampSelection()
               
               // Initial cache status check
               checkCacheStatus()
           }
         .onDisappear {
             [keyMonitor, handoffEventMonitor].forEach { monitor in
                 if let monitor = monitor { NSEvent.removeMonitor(monitor) }
             }
             if let monitor = globalMouseUpMonitor { NSEvent.removeMonitor(monitor) }
             [windowObserver, windowHiddenObserver].forEach { observer in
                 if let observer = observer { NotificationCenter.default.removeObserver(observer) }
             }
             keyMonitor = nil
             handoffEventMonitor = nil
             globalMouseUpMonitor = nil
             windowObserver = nil
             windowHiddenObserver = nil
         }
    }
    
    private func launchApp(_ app: AppInfo) {
        AppDelegate.shared?.hideWindow()
        // Battery-optimized: reduced frequency of app launch operations
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSWorkspace.shared.open(app.url)
        }
    }
    
    private func handleItemTap(_ item: LaunchpadItem) {
        guard draggingItem == nil else { return }
        switch item {
        case .app(let app):
            launchApp(app)
        case .folder(let folder):
            withAnimation(LNAnimations.springFast) {
                appStore.openFolder = folder
            }
        case .empty:
            break
        }
    }
    
    

    // MARK: - Handoff drag from folder
    private func startHandoffDragIfNeeded(geo: GeometryProxy, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard draggingItem == nil, let app = appStore.handoffDraggingApp else { return }
        // Update geometry context
        captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)

        // Initial position: screen -> grid local
        let screenPoint = appStore.handoffDragScreenLocation ?? NSEvent.mouseLocation
        let localPoint = convertScreenToGrid(screenPoint)

        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { draggingItem = .app(app) }
        isKeyboardNavigationActive = false
        appStore.isDragCreatingFolder = false
        appStore.folderCreationTarget = nil
        dragPreviewScale = 1.2
        dragPreviewPosition = localPoint
        // Make handoff drag consistent with normal drag: pre-create new page to support edge flipping
        isHandoffDragging = true

        // Intelligent page flipping: determine whether to jump to the appropriate page based on drag position
        if let targetIndex = indexAt(point: localPoint,
                                     in: currentContainerSize,
                                     pageIndex: appStore.currentPage,
                                     columnWidth: columnWidth,
                                     appHeight: appHeight),
           currentItems.indices.contains(targetIndex) {
            let targetPage = targetIndex / config.itemsPerPage
            if targetPage != appStore.currentPage && targetPage < pages.count {
                appStore.currentPage = targetPage
            }
        }

        if let existing = handoffEventMonitor { NSEvent.removeMonitor(existing) }
        handoffEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDragged:
                let lp = convertScreenToGrid(NSEvent.mouseLocation)
                // Reuse the same core update logic as normal drag
                applyDragUpdate(at: lp,
                                containerSize: currentContainerSize,
                                columnWidth: currentColumnWidth,
                                appHeight: currentAppHeight,
                                iconSize: currentIconSize)
                return nil
            case .leftMouseUp:
                finalizeHandoffDrag()
                return nil
            default:
                return event
            }
        }

        appStore.handoffDraggingApp = nil
        appStore.handoffDragScreenLocation = nil
    }

    private func convertScreenToGrid(_ screenPoint: CGPoint) -> CGPoint {
        guard let window = NSApp.keyWindow else { return screenPoint }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // The top of SwiftUI's .global coordinate space is the origin, while in AppKit
        // The bottom of the window is the origin, so the y-coordinate needs to be flipped.
        let windowHeight = window.contentView?.bounds.height ?? window.frame.size.height
        let x = windowPoint.x - gridOriginInWindow.x
        let yFromTop = windowHeight - windowPoint.y
        let y = yFromTop - gridOriginInWindow.y
        return CGPoint(x: x, y: y)
    }

    private func handleHandoffDragMove(to localPoint: CGPoint) {
        // Reuse the same core update logic as normal drag
        applyDragUpdate(at: localPoint,
                        containerSize: currentContainerSize,
                        columnWidth: currentColumnWidth,
                        appHeight: currentAppHeight,
                        iconSize: currentIconSize)
    }

    private func finalizeHandoffDrag() {
        guard draggingItem != nil else { return }
        defer {
            if let monitor = handoffEventMonitor { NSEvent.removeMonitor(monitor); handoffEventMonitor = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                draggingItem = nil
                pendingDropIndex = nil
                clampSelection()
                // Reset page flipping state
                pageFlipManager.isCooldown = false
                isHandoffDragging = false
                // Reset drag folder creation state to ensure normal drag functionality
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
                // Reset handoff drag state
                appStore.cleanupUnusedNewPage()
                appStore.removeEmptyPages()
                appStore.saveAllOrder()
                // Trigger grid refresh to ensure drag gesture is correctly re-added
                appStore.triggerGridRefresh()
            }
        }
        // Final update to ensure the last position is captured
        if isHandoffDragging && pendingDropIndex == nil {
            if let idx = indexAt(point: dragPreviewPosition,
                                  in: currentContainerSize,
                                  pageIndex: appStore.currentPage,
                                  columnWidth: currentColumnWidth,
                                  appHeight: currentAppHeight) {
                pendingDropIndex = idx
            } else {
                pendingDropIndex = predictedDropIndex(for: dragPreviewPosition,
                                                      in: currentContainerSize,
                                                      columnWidth: currentColumnWidth,
                                                      appHeight: currentAppHeight)
            }
        }

        // Reuse the same drag end handling logic
        finalizeDragOperation(containerSize: currentContainerSize, columnWidth: currentColumnWidth, appHeight: currentAppHeight, iconSize: currentIconSize)

        // Immediately trigger grid refresh to ensure drag gesture is correctly re-added
        appStore.triggerGridRefresh()
    }

    private func navigateToPage(_ targetPage: Int, animated: Bool = true) {
        guard targetPage >= 0 && targetPage < pages.count else { return }
        if animated {
            withAnimation(LNAnimations.springFast) {
                appStore.currentPage = targetPage
            }
        } else {
            appStore.currentPage = targetPage
        }
        
        if isKeyboardNavigationActive, selectedIndex != nil,
           let target = desiredIndexForPageKeepingPosition(targetPage: targetPage) {
            selectedIndex = target
        }
    }

    private func navigateToNextPage() {
        navigateToPage(appStore.currentPage + 1)
    }
    
    private func navigateToPreviousPage() {
        navigateToPage(appStore.currentPage - 1)
    }
    
}

// MARK: - Keyboard Navigation
extension LaunchpadView {
    private func setupWindowShownObserver() {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        windowObserver = NotificationCenter.default.addObserver(forName: .launchpadWindowShown, object: nil, queue: .main) { _ in
            isKeyboardNavigationActive = false
            selectedIndex = 0
            // Explicitly defocus search when window is shown
            isSearchFieldFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            // Don't auto-focus search field - let user manually click it if needed
            if !appStore.apps.isEmpty {
                appStore.applyOrderAndFolders()
            }
        }
    }
    
    private func setupWindowHiddenObserver() {
        if let observer = windowHiddenObserver {
            NotificationCenter.default.removeObserver(observer)
            windowHiddenObserver = nil
        }
        windowHiddenObserver = NotificationCenter.default.addObserver(forName: .launchpadWindowHidden, object: nil, queue: .main) { _ in
            // Defocus and reset selection when window hides
            isSearchFieldFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            selectedIndex = 0
        }
    }
    
    private func setupInitialSelection() {
        if selectedIndex == nil, let firstIndex = filteredItems.indices.first {
            selectedIndex = firstIndex
        }
    }

    private func setupKeyHandlers() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        if isFolderOpen {
            if event.keyCode == 53 { // esc
                let closingFolder = appStore.openFolder
                withAnimation(LNAnimations.springFast) {
                    appStore.openFolder = nil
                }
                if let folder = closingFolder,
                   let idx = filteredItems.firstIndex(of: .folder(folder)) {
                    isKeyboardNavigationActive = true
                    selectedIndex = idx
                    let targetPage = idx / config.itemsPerPage
                    if targetPage != appStore.currentPage {
                        appStore.currentPage = targetPage
                    }
                }
                // Do not auto-focus the search field; respect user's focus
                return nil
            }
            return event
        }
        
        // Type-to-search: if search is not focused and user types printable characters, start focusing search
        if !isSearchFieldFocused && !isFolderOpen {
            // Ignore command/option/control shortcuts
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            // Check if this is a navigation key (arrow keys, page navigation, etc.) and skip type-to-search
            // Navigation keys: arrow keys (123,124,125,126), tab (48), return (36), space (49), escape (53)
            // Also check if it's a custom navigation key for page switching
            let isNavigationKey = [123, 124, 125, 126, 48, 36, 49, 53].contains(event.keyCode) || 
                                event.keyCode == appStore.previousPageKey || 
                                event.keyCode == appStore.nextPageKey
            if mods.isEmpty, let chars = event.charactersIgnoringModifiers, isPrintable(chars), !isNavigationKey {
                // Begin a search session: focus the field and seed with typed characters
                isSearchFieldFocused = true
                if !chars.isEmpty {
                    appStore.searchText += chars
                }
                return nil
            }
        }

        guard !filteredItems.isEmpty else { return event }
        let code = event.keyCode

        if draggingItem != nil {
            switch code {
            case 123, 124, 125, 126, 48, 36: return nil
            default: return event
            }
        }

        if code == 53 { // esc
            AppDelegate.shared?.hideWindow()
            return nil
        }

        if code == 36 { // return
            if isSearchFieldFocused, isIMEComposing() { return event }
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }

            if let idx = selectedIndex, filteredItems.indices.contains(idx) {
                let sel = filteredItems[idx]
                if case .folder = sel {
                    appStore.openFolderActivatedByKeyboard = true
                }
                handleItemTap(sel)
                return nil
            }
            return event
        }

        if code == 48 { // tab
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }
            // When activated, retain the original paging behavior (Shift for reverse)
            let backward = event.modifierFlags.contains(.shift)
            if backward {
                navigateToPreviousPage()
            } else {
                navigateToNextPage()
            }
            setSelectionToPageStart(appStore.currentPage)
            return nil
        }

        // Page navigation shortcuts - work regardless of keyboard navigation state
        let hasRequiredModifier = appStore.useShiftModifier ? event.modifierFlags.contains(.shift) : !event.modifierFlags.contains(.shift)
        
        if hasRequiredModifier {
            if code == appStore.previousPageKey {
                navigateToPreviousPage()
                // If keyboard navigation is active, set selection to page start
                if isKeyboardNavigationActive {
                    setSelectionToPageStart(appStore.currentPage)
                }
                return nil
            } else if code == appStore.nextPageKey {
                navigateToNextPage()
                // If keyboard navigation is active, set selection to page start
                if isKeyboardNavigationActive {
                    setSelectionToPageStart(appStore.currentPage)
                }
                return nil
            }
        }

        if code == 125 { // down arrow activates navigation first
            if isSearchFieldFocused, isIMEComposing() { return event }
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }
            moveSelection(dx: 0, dy: 1)
            return nil
        }

        if code == 126 { // up arrow
            guard isKeyboardNavigationActive else { return event }
            if let idx = selectedIndex {
                let columns = config.columns
                let itemsPerPage = config.itemsPerPage
                let rowInPage = (idx % itemsPerPage) / columns
                if rowInPage == 0 {
                    isKeyboardNavigationActive = false
                    selectedIndex = nil
                    return nil
                }
            }
            moveSelection(dx: 0, dy: -1)
            return nil
        }

        // Normal arrow key navigation (when no page navigation modifier is held)
        if let (dx, dy) = arrowDelta(for: code) {
            let hasPageNavModifier = appStore.useShiftModifier ? event.modifierFlags.contains(.shift) : !event.modifierFlags.contains(.shift)
            let isPageNavKey = (code == appStore.previousPageKey || code == appStore.nextPageKey)

            // If this is a page navigation key and has the correct modifier, let it be handled in the above page navigation logic
            if isPageNavKey && hasPageNavModifier {
                return event
            }
            
            // If not activated, activate keyboard navigation and select the first item of the current page
            guard isKeyboardNavigationActive else { return event }
            moveSelection(dx: dx, dy: dy)
            return nil
        }

        return event
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard let current = selectedIndex else { return }
        let columns = config.columns
        let newIndex: Int = dy == 0 ? current + dx : current + dy * columns
        guard filteredItems.indices.contains(newIndex) else { return }
        selectedIndex = newIndex
        
        let page = newIndex / config.itemsPerPage
        if page != appStore.currentPage {
            navigateToPage(page, animated: true)
        }
    }

    private func setSelectionToPageStart(_ page: Int) {
        let startIndex = page * config.itemsPerPage
        if filteredItems.indices.contains(startIndex) {
            selectedIndex = startIndex
        } else if let last = filteredItems.indices.last {
            selectedIndex = last
        } else {
            selectedIndex = nil
        }
    }

    private func desiredIndexForPageKeepingPosition(targetPage: Int) -> Int? {
        guard let current = selectedIndex else { return nil }
        let columns = config.columns
        let itemsPerPage = config.itemsPerPage
        let currentOffsetInPage = current % itemsPerPage
        let currentRow = currentOffsetInPage / columns
        let currentCol = currentOffsetInPage % columns
        let targetOffset = currentRow * columns + currentCol
        let candidate = targetPage * itemsPerPage + targetOffset

        if filteredItems.indices.contains(candidate) {
            return candidate
        }

        let startOfPage = targetPage * itemsPerPage
        let endExclusive = min((targetPage + 1) * itemsPerPage, filteredItems.count)
        let lastIndexInPage = endExclusive - 1
        return lastIndexInPage >= startOfPage ? lastIndexInPage : nil
    }
}

// MARK: - Key mapping helpers
extension LaunchpadView {
    private func isIMEComposing() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    private func isPrintable(_ s: String) -> Bool {
        // Treat non-control characters as printable; exclude newlines and tabs
        if s.isEmpty { return false }
        let control = CharacterSet.controlCharacters.union(.newlines)
        return s.rangeOfCharacter(from: control) == nil
    }
}

// MARK: - View builders
extension LaunchpadView {
    @ViewBuilder
    private func itemDraggable(item: LaunchpadItem,
                               globalIndex: Int,
                               pageIndex: Int,
                               containerSize: CGSize,
                               columnWidth: CGFloat,
                               iconSize: CGFloat,
                               appHeight: CGFloat,
                               labelWidth: CGFloat,
                               isSelected: Bool) -> some View {
        if case .empty = item {
            Rectangle().fill(Color.clear)
                .frame(height: appHeight)
        } else {
            let shouldAllowHover = draggingItem == nil

            let isCenterCreatingTarget: Bool = {
                guard let draggingItem, let idx = currentItems.firstIndex(of: item) else { return false }
                guard case .app = draggingItem else { return false }
                guard appStore.isDragCreatingFolder else { return false }
                switch item {
                case .app(let targetApp):
                    return appStore.folderCreationTarget?.id == targetApp.id
                case .folder:
                    return folderHoverCandidateIndex == idx
                case .empty:
                    return false
                }
            }()

            let base = LaunchpadItemButton(
                item: item,
                iconSize: iconSize,
                labelWidth: labelWidth,
                isSelected: isSelected,
                shouldAllowHover: shouldAllowHover,
                externalScale: isCenterCreatingTarget ? 1.2 : nil,
                onTap: { if draggingItem == nil { handleItemTap(item) } }
            )
            .frame(height: appHeight)
            .matchedGeometryEffect(id: item.id, in: reorderNamespace)
            // Ensure each item has a stable identity for drag operations
            .id(item.id)


            if appStore.searchText.isEmpty && !isFolderOpen {
                let isDraggingThisTile = (draggingItem == item)

                base
                    .opacity(isDraggingThisTile ? 0 : 1)
                    .allowsHitTesting(!isDraggingThisTile)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("grid"))
                            .onChanged { value in
                                handleDragChange(value, item: item, in: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                            .onEnded { _ in
                                guard draggingItem != nil else { return }
                                
                                // Final update to ensure the last position is captured
                                finalizeDragOperation(containerSize: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)

                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                    draggingItem = nil
                                    pendingDropIndex = nil
                                    clampSelection()
                                    appStore.cleanupUnusedNewPage()
                                    appStore.removeEmptyPages()

                                    // Ensure drag operation is completed before saving
                                    appStore.saveAllOrder()
                                }
                            }
                    )
            } else {
                base
            }
        }
    }
}

// MARK: - Drag math helpers
extension LaunchpadView {
    private func pageOf(index: Int) -> Int { index / config.itemsPerPage }

    private func cellOrigin(for globalIndex: Int,
                            in containerSize: CGSize,
                            pageIndex: Int,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let columns = config.columns
        let displayedOffsetInPage: Int = {
            guard pages.indices.contains(pageIndex), currentItems.indices.contains(globalIndex) else {
                return globalIndex % config.itemsPerPage
            }
            let pageItems = pages[pageIndex]
            let item = currentItems[globalIndex]
            return pageItems.firstIndex(of: item) ?? (globalIndex % config.itemsPerPage)
        }()
        
        return GeometryUtils.cellOrigin(for: displayedOffsetInPage,
                                      containerSize: containerSize,
                                      pageIndex: pageIndex,
                                      columnWidth: columnWidth,
                                      appHeight: appHeight,
                                      columns: columns,
                                      columnSpacing: config.columnSpacing,
                                      rowSpacing: config.rowSpacing,
                                      pageSpacing: config.pageSpacing,
                                      currentPage: appStore.currentPage)
    }

    private func cellCenter(for globalIndex: Int,
                            in containerSize: CGSize,
                            pageIndex: Int,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let origin = cellOrigin(for: globalIndex, in: containerSize, pageIndex: pageIndex, columnWidth: columnWidth, appHeight: appHeight)
        return CGPoint(x: origin.x + columnWidth / 2, y: origin.y + appHeight / 2)
    }

    private func indexAt(point: CGPoint,
                         in containerSize: CGSize,
                         pageIndex: Int,
                         columnWidth: CGFloat,
                         appHeight: CGFloat) -> Int? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let pageItems = pages[pageIndex]
        
        guard let offsetInPage = GeometryUtils.indexAt(point: point,
                                                      containerSize: containerSize,
                                                      pageIndex: pageIndex,
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight,
                                                      columns: config.columns,
                                                      columnSpacing: config.columnSpacing,
                                                      rowSpacing: config.rowSpacing,
                                                      pageSpacing: config.pageSpacing,
                                                      currentPage: appStore.currentPage,
                                                      itemsPerPage: config.itemsPerPage,
                                                      pageItems: pageItems) else { return nil }
        
        let startIndexInCurrentItems = pages.prefix(pageIndex).reduce(0) { $0 + $1.count }
        let globalIndex = startIndexInCurrentItems + offsetInPage
        return currentItems.indices.contains(globalIndex) ? globalIndex : nil
    }

    private func isPointInCenterArea(point: CGPoint,
                                      targetIndex: Int,
                                      containerSize: CGSize,
                                      pageIndex: Int,
                                      columnWidth: CGFloat,
                                      appHeight: CGFloat,
                                      iconSize: CGFloat) -> Bool {
        let targetCenter = cellCenter(for: targetIndex, in: containerSize, pageIndex: pageIndex, columnWidth: columnWidth, appHeight: appHeight)
        let scale: CGFloat = 1.6
        let centerAreaSize = iconSize * scale
        let centerAreaRect = CGRect(
            x: targetCenter.x - centerAreaSize / 2,
            y: targetCenter.y - centerAreaSize / 2,
            width: centerAreaSize,
            height: centerAreaSize
        )
        return centerAreaRect.contains(point)
    }
}

// MARK: - Scroll handling (mouse wheel and trackpad)
extension LaunchpadView {
    private func handleScroll(deltaX: CGFloat,
                              deltaY: CGFloat,
                              phase: NSEvent.Phase,
                              isMomentum: Bool,
                              isPrecise: Bool,
                              pageWidth: CGFloat) {
        guard !isFolderOpen && !appStore.isSetting else { return } // Check both folder and settings state
        // Mouse wheel (non-precise): accumulate distance; apply small cooldown to avoid multi-page flips
        if !isPrecise {
            // Map vertical wheel to horizontal direction like precise scroll
            let primaryDelta = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY
            if primaryDelta == 0 { return }
            let direction = primaryDelta > 0 ? 1 : -1
            if wheelLastDirection != direction { wheelAccumulatedSinceFlip = 0 }
            wheelLastDirection = direction
            wheelAccumulatedSinceFlip += abs(primaryDelta)
            let threshold: CGFloat = 2.0 / CGFloat(appStore.scrollSensitivity / 0.15)
            let now = Date()
            if wheelAccumulatedSinceFlip >= threshold {
                if let last = wheelLastFlipAt, now.timeIntervalSince(last) < wheelFlipCooldown { return }
                if direction > 0 { navigateToNextPage() } else { navigateToPreviousPage() }
                wheelLastFlipAt = now
                wheelAccumulatedSinceFlip = 0
            }
            return
        }

        // Trackpad precise scroll: accumulate and flip after threshold
        if isMomentum { return }
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY
        switch phase {
        case .began:
            isUserSwiping = true
            accumulatedScrollX = 0
        case .changed:
            isUserSwiping = true
            accumulatedScrollX += delta
        case .ended, .cancelled:
            let threshold = pageWidth * (0.0225 / max(appStore.scrollSensitivity, 0.001))
            if accumulatedScrollX <= -threshold {
                navigateToNextPage()
            } else if accumulatedScrollX >= threshold {
                navigateToPreviousPage()
            }
            accumulatedScrollX = 0
            isUserSwiping = false
        default:
            break
        }
    }
}

// MARK: - AppKit Scroll catcher
struct ScrollEventCatcher: NSViewRepresentable {
    typealias NSViewType = ScrollEventCatcherView
    let onScroll: (CGFloat, CGFloat, NSEvent.Phase, Bool, Bool) -> Void

    func makeNSView(context: Context) -> ScrollEventCatcherView {
        let view = ScrollEventCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollEventCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollEventCatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, NSEvent.Phase, Bool, Bool) -> Void)?
        private var eventMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // Prefer primary phase; fallback to momentum
            let phase = event.phase != [] ? event.phase : event.momentumPhase
            let isMomentum = event.momentumPhase != []
            let isPreciseOrTrackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
            onScroll?(event.scrollingDeltaX,
                      event.scrollingDeltaY,
                      phase,
                      isMomentum,
                      isPreciseOrTrackpad)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
            // Global listener for scroll events in the current window, without consuming events
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                let phase = event.phase != [] ? event.phase : event.momentumPhase
                let isMomentum = event.momentumPhase != []
                let isPreciseOrTrackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
                self?.onScroll?(event.scrollingDeltaX,
                                event.scrollingDeltaY,
                                phase,
                                isMomentum,
                                isPreciseOrTrackpad)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Make this view transparent to mouse events
            return nil
        }

        deinit {
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Drag preview view


// MARK: - Selection Helpers
extension LaunchpadView {
    private func clampSelection() {
        guard isKeyboardNavigationActive else { return }
        let count = filteredItems.count
        if count == 0 {
            selectedIndex = nil
            return
        }
        if let idx = selectedIndex {
            if idx >= count { selectedIndex = count - 1 }
            if idx < 0 { selectedIndex = 0 }
        } else {
            selectedIndex = 0
        }
        
        if let idx = selectedIndex, filteredItems.indices.contains(idx) {
            let page = idx / config.itemsPerPage
            if page != appStore.currentPage {
                navigateToPage(page, animated: true)
            }
        } else {
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
    }
}

// MARK: - Geometry & Drag helpers
extension LaunchpadView {
    // Simplified layout calculation - removed complex caching for better performance
    private func calculateOptimizedLayout(for geo: GeometryProxy, actualTopPadding: CGFloat, actualBottomPadding: CGFloat) -> (width: CGFloat, height: CGFloat, iconSize: CGFloat) {
        // Simple cache check based on size and fullscreen state only
        if let cache = Self.simpleLayoutCache,
           cache.size == geo.size && cache.isFullscreen == config.isFullscreen {
            return cache.result
        }
        
        // Calculate layout
        let appCountPerRow = config.columns
        let maxRowsPerPage = Int(ceil(Double(config.itemsPerPage) / Double(appCountPerRow)))
        let availableWidth = geo.size.width
        let availableHeight = geo.size.height - (actualTopPadding + actualBottomPadding)
        
        let appHeight: CGFloat = {
            let totalRowSpacing = config.rowSpacing * CGFloat(maxRowsPerPage - 1)
            let height = (availableHeight - totalRowSpacing) / CGFloat(maxRowsPerPage)
            return max(56, height)
        }()

        let columnWidth: CGFloat = {
            let totalColumnSpacing = config.columnSpacing * CGFloat(appCountPerRow - 1)
            let width = (availableWidth - totalColumnSpacing) / CGFloat(appCountPerRow)
            return max(40, width)
        }()

        let iconSize: CGFloat = min(columnWidth, appHeight) * 0.8
        let result = (width: columnWidth, height: appHeight, iconSize: iconSize)
        
        // Update simple cache
        Self.simpleLayoutCache = (size: geo.size, isFullscreen: config.isFullscreen, result: result)
        return result
    }

    fileprivate func captureGridGeometry(_ geo: GeometryProxy, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        gridOriginInWindow = geo.frame(in: .global).origin
        currentContainerSize = geo.size
        currentColumnWidth = columnWidth
        currentAppHeight = appHeight
        currentIconSize = iconSize
    }

    fileprivate func flipPageIfNeeded(at point: CGPoint, in containerSize: CGSize) -> Bool {
        let edgeMargin: CGFloat = config.pageNavigation.edgeFlipMargin
        
        // Update page flip manager state
        pageFlipManager.autoFlipInterval = config.pageNavigation.autoFlipInterval
        guard pageFlipManager.canFlip() else { return false }
                
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            navigateToPreviousPage()
            pageFlipManager.recordFlip()
            return true
        } else if point.x >= containerSize.width - edgeMargin {
            // Check if a new page needs to be created
            let nextPage = appStore.currentPage + 1
            let itemsPerPage = config.itemsPerPage
            let nextPageStart = nextPage * itemsPerPage
            
            // If dragging to a new page, ensure the new page has enough items
            if nextPageStart >= currentItems.count {
                let neededItems = nextPageStart + itemsPerPage - currentItems.count
                for _ in 0..<neededItems {
                    appStore.items.append(.empty(UUID().uuidString))
                }
            }
            
            navigateToNextPage()
            pageFlipManager.recordFlip()
            return true
        }
        
        return false
    }

    fileprivate func predictedDropIndex(for point: CGPoint, in containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat) -> Int? {
        if let predicted = indexAt(point: point,
                                   in: containerSize,
                                   pageIndex: appStore.currentPage,
                                   columnWidth: columnWidth,
                                   appHeight: appHeight) {
            return predicted
        }
        
        let edgeMargin: CGFloat = config.pageNavigation.edgeFlipMargin
        let itemsPerPage = config.itemsPerPage
        
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            let prevPage = appStore.currentPage - 1
            let prevPageStart = prevPage * itemsPerPage
            let prevPageEnd = min(prevPageStart + itemsPerPage, currentItems.count)
            return max(prevPageStart, prevPageEnd - 1)
        } else if point.x >= containerSize.width - edgeMargin {
            let nextPage = appStore.currentPage + 1
            let nextPageStart = nextPage * itemsPerPage

            // If dragging to a new page, ensure the new page has enough items
            if nextPageStart >= currentItems.count {
                // Dragging to a completely new page, return the first position of the new page
                return nextPageStart
            } else {
                return min(nextPageStart, currentItems.count - 1)
            }
        } else {
            if point.x <= edgeMargin {
                return appStore.currentPage * itemsPerPage
            } else {
                let currentPageEnd = min((appStore.currentPage + 1) * itemsPerPage, currentItems.count)
                return max(appStore.currentPage * itemsPerPage, currentPageEnd - 1)
            }
        }
    }
}

struct GridConfig {
    let isFullscreen: Bool
    
    init(isFullscreen: Bool = false) {
        self.isFullscreen = isFullscreen
    }
    
    var itemsPerPage: Int { 35 }
    var columns: Int { 7 }
    var rows: Int { 5 }
    
    let maxBounce: CGFloat = 80
    let pageSpacing: CGFloat = 100
    let rowSpacing: CGFloat = 16
    let columnSpacing: CGFloat = 24
    
    struct PageNavigation {
        let edgeFlipMargin: CGFloat = 15
        let autoFlipInterval: TimeInterval = 0.8 // Dragging to the edge flip page interval is 0.8 seconds
        let scrollPageThreshold: CGFloat = 0.75
        let scrollFinishThreshold: CGFloat = 0.5
    }
    
    let pageNavigation = PageNavigation()
    let folderCreateDwell: TimeInterval = 0
    
    var horizontalPadding: CGFloat { isFullscreen ? 0.05 : 0 }
    var topPadding: CGFloat { isFullscreen ? 0.05 : 0 }
    var bottomPadding: CGFloat { isFullscreen ? 0.1 : 0 }
    
    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: columns)
    }
}
 

//

struct DragPreviewItem: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    var scale: CGFloat = 1.2
    
    // Computed property to get the appropriate icon
    private var displayIcon: NSImage {
        switch item {
        case .app(let app):
            return app.icon
        case .folder(let folder):
            return folder.icon(of: iconSize)
        case .empty:
            return item.icon
        }
    }

    var body: some View {
        switch item {
        case .app(let app):
            VStack(spacing: 6) {
                Image(nsImage: displayIcon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: iconSize, height: iconSize)
                Text(app.name)
                    .font(.default)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .scaleEffect(scale)
            .animation(LNAnimations.springFast, value: scale)

        case .folder(let folder):
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: iconSize * 0.2)
                        .foregroundStyle(Color.clear)
                        .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                        .background(
                            VisualEffectView(material: .selection, blendingMode: .withinWindow)
                                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.2))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: iconSize * 0.2)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                    Image(nsImage: folder.icon(of: iconSize))
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: iconSize, height: iconSize)
                }
                
                Text(folder.name)
                    .font(.default)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .scaleEffect(scale)
            .animation(LNAnimations.springFast, value: scale)
            
        case .empty:
            EmptyView()
        }
    }
}

func arrowDelta(for keyCode: UInt16) -> (dx: Int, dy: Int)? {
    switch keyCode {
    case 123: return (-1, 0) // left
    case 124: return (1, 0)  // right
    case 126: return (0, -1) // up
    case 125: return (0, 1)  // down
    default: return nil
    }
}

// MARK: - Cache checking

extension LaunchpadView {
    /// Check cache status
    private func checkCacheStatus() {
        // If the cache is invalid, trigger a re-scan
        if !AppCacheManager.shared.isCacheValid {
    
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.appStore.performInitialScanIfNeeded()
            }
        }
    }
    
    // MARK: - Drag handling helpers
    private func handleDragChange(_ value: DragGesture.Value, item: LaunchpadItem, in containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        // Initialize drag
        if draggingItem == nil {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { draggingItem = item }
            isKeyboardNavigationActive = false
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            dragPreviewPosition = value.location
        }
        applyDragUpdate(at: value.location,
                        containerSize: containerSize,
                        columnWidth: columnWidth,
                        appHeight: appHeight,
                        iconSize: iconSize)
    }

    // Unified drag end handling logic (common for normal drag and relay drag)
    private func finalizeDragOperation(containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard let dragging = draggingItem else { return }
        
        // Handle special case: drag to create folder
        if appStore.isDragCreatingFolder, case .app(let app) = dragging {
            if let targetApp = appStore.folderCreationTarget {
                // Use the current items (which includes visual reordering) to find the correct insertion position
                let insertAt = currentItems.firstIndex(of: .app(targetApp))
                let newFolder = appStore.createFolder(with: [app, targetApp], insertAt: insertAt)
                
                // Find the folder in the updated items after creation
                if let folderIndex = appStore.items.firstIndex(of: .folder(newFolder)) {
                    let targetCenter = cellCenter(for: folderIndex,
                                                  in: containerSize,
                                                  pageIndex: pageOf(index: folderIndex),
                                                  columnWidth: columnWidth,
                                                  appHeight: appHeight)
                    withAnimation(LNAnimations.springFast) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                    }
                }
            } else {
                if let hoveringIndex = indexAt(point: dragPreviewPosition,
                                               in: containerSize,
                                               pageIndex: appStore.currentPage,
                                               columnWidth: columnWidth,
                                               appHeight: appHeight),
                   currentItems.indices.contains(hoveringIndex),
                   case .folder(let folder) = currentItems[hoveringIndex] {
                    appStore.addAppToFolder(app, folder: folder)
                    let targetCenter = cellCenter(for: hoveringIndex,
                                                  in: containerSize,
                                                  pageIndex: appStore.currentPage,
                                                  columnWidth: columnWidth,
                                                  appHeight: appHeight)
                    withAnimation(LNAnimations.springFast) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                    }
                }
            }
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            return
        }
        
        // Normal drag end handling
        if let finalIndex = pendingDropIndex,
           let _ = filteredItems.firstIndex(of: dragging) {
            // Check if it's a cross-page drag
            let sourceIndexInItems = appStore.items.firstIndex(of: dragging) ?? 0
            let targetPage = finalIndex / config.itemsPerPage
            let sourcePage = sourceIndexInItems / config.itemsPerPage
            
            // Animate drag preview to the target cell
            let dropDisplayIndex = finalIndex
            let finalPage = pageOf(index: dropDisplayIndex)
            let targetCenter = cellCenter(for: dropDisplayIndex,
                                          in: containerSize,
                                          pageIndex: finalPage,
                                          columnWidth: columnWidth,
                                          appHeight: appHeight)
            withAnimation(LNAnimations.springFast) {
                dragPreviewPosition = targetCenter
                dragPreviewScale = 1.0
            }
            
            if targetPage == sourcePage {
                // Same-page move: use the original in-page sorting logic
                let pageStart = (finalIndex / config.itemsPerPage) * config.itemsPerPage
                let pageEnd = min(pageStart + config.itemsPerPage, appStore.items.count)
                var newItems = appStore.items
                var pageSlice = Array(newItems[pageStart..<pageEnd])
                let localFrom = sourceIndexInItems - pageStart
                let localTo = max(0, min(finalIndex - pageStart, pageSlice.count - 1))
                let moving = pageSlice.remove(at: localFrom)
                pageSlice.insert(moving, at: localTo)
                newItems.replaceSubrange(pageStart..<pageEnd, with: pageSlice)
                withAnimation(LNAnimations.springFast) {
                    appStore.items = newItems
                }
                appStore.saveAllOrder()

                // Battery-optimized: same-page drag end compaction
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    appStore.compactItemsWithinPages()
                }
            } else {
                // Cross-page drag: use cascading insert logic
                appStore.moveItemAcrossPagesWithCascade(item: dragging, to: finalIndex)
            }
        } else {
            // Fallback logic: if no valid target index, place the app at the end of the current page
            if filteredItems.firstIndex(of: dragging) != nil {
                let currentPageStart = appStore.currentPage * config.itemsPerPage
                let currentPageEnd = min(currentPageStart + config.itemsPerPage, appStore.items.count)
                let targetIndex = currentPageEnd
                
                // Animate drag preview to the target cell
                appStore.moveItemAcrossPagesWithCascade(item: dragging, to: targetIndex)
            }
        }
    }

    // Simplified drag update logic (common for normal drag and relay drag)
    private func applyDragUpdate(at point: CGPoint,
                                 containerSize: CGSize,
                                 columnWidth: CGFloat,
                                 appHeight: CGFloat,
                                 iconSize: CGFloat) {
        // Simple movement threshold to reduce update frequency
        let distance = sqrt(pow(dragPreviewPosition.x - point.x, 2) + pow(dragPreviewPosition.y - point.y, 2))
        if distance < 3.0 { return } // If movement is less than 3 pixels, skip update
        
        dragPreviewPosition = point
        
        if let hoveringIndex = indexAt(point: dragPreviewPosition,
                                       in: containerSize,
                                       pageIndex: appStore.currentPage,
                                       columnWidth: columnWidth,
                                       appHeight: appHeight),
           currentItems.indices.contains(hoveringIndex) {
            handleHoveringLogic(hoveringIndex: hoveringIndex, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
        } else {
            clearHoveringState()
        }

        if flipPageIfNeeded(at: point, in: containerSize) {
            pendingDropIndex = predictedDropIndex(for: point, in: containerSize, columnWidth: columnWidth, appHeight: appHeight)
        }
    }
    
    private func handleHoveringLogic(hoveringIndex: Int, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        let hoveringItem = currentItems[hoveringIndex]
        guard pageOf(index: hoveringIndex) == appStore.currentPage else {
            clearHoveringState()
            return
        }

        let isInCenterArea = isPointInCenterArea(
            point: dragPreviewPosition,
            targetIndex: hoveringIndex,
            containerSize: currentContainerSize,
            pageIndex: appStore.currentPage,
            columnWidth: columnWidth,
            appHeight: appHeight,
            iconSize: iconSize
        )

        guard let dragging = draggingItem else { return }

        switch hoveringItem {
        case .app(let targetApp):
            handleAppHover(dragging: dragging, targetApp: targetApp, hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea)
        case .folder(_):
            handleFolderHover(dragging: dragging, hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea)
        case .empty:
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func handleAppHover(dragging: LaunchpadItem, targetApp: AppInfo, hoveringIndex: Int, isInCenterArea: Bool) {
        if dragging == .app(targetApp) {
            clearHoveringState()
            pendingDropIndex = hoveringIndex
        } else if case .app = dragging {
            handleAppToAppHover(hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea, targetApp: targetApp)
        } else {
            clearHoveringState()
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func handleAppToAppHover(hoveringIndex: Int, isInCenterArea: Bool, targetApp: AppInfo) {
        let now = Date()
        let candidateChanged = folderHoverCandidateIndex != hoveringIndex || !isInCenterArea
        
        if candidateChanged {
            folderHoverCandidateIndex = isInCenterArea ? hoveringIndex : nil
            folderHoverBeganAt = isInCenterArea ? now : nil
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
        }
        
        if isInCenterArea {
            appStore.isDragCreatingFolder = true
            appStore.folderCreationTarget = targetApp
            pendingDropIndex = nil
        } else {
            if !isInCenterArea || folderHoverCandidateIndex == nil {
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
                pendingDropIndex = hoveringIndex
            } else {
                pendingDropIndex = nil
            }
        }
    }
    
    private func handleFolderHover(dragging: LaunchpadItem, hoveringIndex: Int, isInCenterArea: Bool) {
        if case .app = dragging {
            let now = Date()
            let candidateChanged = folderHoverCandidateIndex != hoveringIndex || !isInCenterArea
            
            if candidateChanged {
                folderHoverCandidateIndex = isInCenterArea ? hoveringIndex : nil
                folderHoverBeganAt = isInCenterArea ? now : nil
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
            }
            
            if isInCenterArea {
                appStore.isDragCreatingFolder = true
                appStore.folderCreationTarget = nil
                pendingDropIndex = nil
            } else {
                if !isInCenterArea || folderHoverCandidateIndex == nil {
                    appStore.isDragCreatingFolder = false
                    appStore.folderCreationTarget = nil
                    pendingDropIndex = hoveringIndex
                } else {
                    pendingDropIndex = nil
                }
            }
        } else {
            clearHoveringState()
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func clearHoveringState() {
        appStore.isDragCreatingFolder = false
        appStore.folderCreationTarget = nil
        pendingDropIndex = nil
        folderHoverCandidateIndex = nil
        folderHoverBeganAt = nil
    }
}

// MARK: - Launchpad Background View (macOS Launchpad Style)
struct LaunchpadBackgroundView: View {
    let isFullscreen: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            // Base background - adapts to system appearance
            if isFullscreen {
                // Fullscreen mode: Launchpad-style background with subtle texture
                ZStack {
                    // Main background color
                    (colorScheme == .dark ? 
                     Color(NSColor.controlBackgroundColor).opacity(0.95) : 
                     Color(NSColor.controlBackgroundColor))
                        .ignoresSafeArea()
                    
                    // Subtle noise texture overlay for authenticity
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.02),
                                    Color.clear,
                                    Color.primary.opacity(0.01)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .ignoresSafeArea()
                        .blendMode(colorScheme == .dark ? .multiply : .overlay)
                }
            } else {
                // Window mode: translucent background with system material, matching original style
                VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30)
                            .strokeBorder(
                                Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.15), 
                                lineWidth: 0.5
                            )
                    )
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.7 : 0.25),
                        radius: 25,
                        y: 15
                    )
            }
        }
    }
}
