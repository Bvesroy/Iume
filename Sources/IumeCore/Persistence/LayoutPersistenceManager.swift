import Foundation
import CoreGraphics

/// Persists and restores strip column layouts, widths, and window stacks across app launches and restarts.
@MainActor
public final class LayoutPersistenceManager {
    public static let shared = LayoutPersistenceManager()
    
    private let fileManager = FileManager.default
    private let storageUrl: URL
    
    public init(customStorageUrl: URL? = nil) {
        if let customUrl = customStorageUrl {
            self.storageUrl = customUrl
        } else if NSClassFromString("XCTestCase") != nil {
            // Tests construct WorkspaceManager() (and therefore the shared persistence
            // manager) and may save throwaway layouts with mock window IDs. Writing those to
            // the real Application Support file wiped the user's actual strip on every test
            // run. Give the test process its own file instead.
            let testDir = fileManager.temporaryDirectory
                .appendingPathComponent("IumeTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            try? fileManager.createDirectory(at: testDir, withIntermediateDirectories: true)
            self.storageUrl = testDir.appendingPathComponent("saved_layout.json")
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let iumeDir = appSupport.appendingPathComponent("Iume", isDirectory: true)
            try? fileManager.createDirectory(at: iumeDir, withIntermediateDirectories: true)
            self.storageUrl = iumeDir.appendingPathComponent("saved_layout.json")
        }
    }
    
    // MARK: - Disk Serialization
    
    public func save(state: PersistedLayoutState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: storageUrl, options: .atomic)
        } catch {
            print("[Iume] Failed to save layout state: \(error.localizedDescription)")
        }
    }
    
    public func load() -> PersistedLayoutState? {
        guard fileManager.fileExists(atPath: storageUrl.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: storageUrl)
            let decoder = JSONDecoder()
            return try decoder.decode(PersistedLayoutState.self, from: data)
        } catch {
            print("[Iume] Failed to load layout state: \(error.localizedDescription)")
            return nil
        }
    }
    
    public func clear() {
        try? fileManager.removeItem(at: storageUrl)
    }
    
    // MARK: - Space Resolution Across Reboots
    
    /// Intelligently resolves saved layout state across application reboots and display reconnects.
    ///
    /// On macOS reboot, `spaceId` is dynamically reassigned by WindowServer, meaning an exact
    /// `displayId_spaceId_workspaceIndex` key may not match. This method falls back gracefully:
    /// 1. Exact match on `key.storageKey`
    /// 2. Match on same display and workspace slot (`displayId_*_workspaceIndex`)
    /// 3. Match on any saved layout for the same display
    public func findSpaceLayout(
        for key: WorkspaceKey,
        in state: PersistedLayoutState
    ) -> SavedSpaceLayout? {
        // 1. Direct exact match
        if let exact = state.spaces[key.storageKey], !exact.columns.isEmpty {
            return exact
        }
        
        // 2. Reboot fallback: match displayId and workspaceIndex
        let displayPrefix = "\(key.displayId)_"
        let slotSuffix = "_\(key.workspaceIndex)"
        for (candidateKey, layout) in state.spaces {
            if candidateKey.hasPrefix(displayPrefix) && candidateKey.hasSuffix(slotSuffix) && !layout.columns.isEmpty {
                return layout
            }
        }
        
        // 3. Fallback: match any saved layout on this display
        for (candidateKey, layout) in state.spaces {
            if candidateKey.hasPrefix(displayPrefix) && !layout.columns.isEmpty {
                return layout
            }
        }
        
        // 4. Fallback for primary display when display IDs renumbered
        if let first = state.spaces.values.first(where: { !$0.columns.isEmpty }) {
            return first
        }
        
        return nil
    }
    
    // MARK: - State Capture & Restoration
    
    /// Captures the runtime column strip state into a serialized SavedSpaceLayout.
    public func captureSpaceLayout(
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        focusedColumnIndex: Int?,
        viewportOffset: CGFloat
    ) -> SavedSpaceLayout {
        var savedColumns: [SavedColumn] = []
        
        for col in columns {
            var signatures: [WindowSignature] = []
            for winId in col.windowIds {
                if let win = windows[winId] {
                    signatures.append(WindowSignature(
                        bundleIdentifier: win.bundleIdentifier,
                        appName: win.appName,
                        title: win.title
                    ))
                }
            }
            if !signatures.isEmpty {
                var lockedIndices: [Int] = []
                var customTitlesBySig: [String: String] = [:]
                for (idx, winId) in col.windowIds.enumerated() {
                    if col.isLocked(winId) {
                        lockedIndices.append(idx)
                    }
                    if let customTitle = col.customTabTitles[winId], let win = windows[winId] {
                        let sigKey = "\(win.bundleIdentifier):\(win.title)"
                        customTitlesBySig[sigKey] = customTitle
                    }
                }
                savedColumns.append(SavedColumn(
                    width: col.width,
                    windowSignatures: signatures,
                    presentationMode: col.presentationMode,
                    activeWindowIndex: col.windowIds.isEmpty ? nil : min(col.activeWindowIndex, col.windowIds.count - 1),
                    tabBarPinned: col.tabBarPinned,
                    customGroupName: col.customGroupName,
                    customColorHex: col.customColorHex,
                    isCollapsed: col.isCollapsed,
                    lockedWindowIndices: lockedIndices.isEmpty ? nil : lockedIndices,
                    customTabTitlesBySignature: customTitlesBySig.isEmpty ? nil : customTitlesBySig
                ))
            }
        }
        
        return SavedSpaceLayout(
            columns: savedColumns,
            focusedColumnIndex: focusedColumnIndex,
            viewportOffset: viewportOffset
        )
    }
    
    /// Reconstructs columns and stacks from a saved layout using currently running windows.
    /// Preserves exact column order, column widths, and stacked relationships.
    public func restoreSpaceLayout(
        savedLayout: SavedSpaceLayout,
        availableWindows: [ManagedWindow],
        visibleWidth: CGFloat
    ) -> (restoredColumns: [WindowColumn], placedWindowIds: Set<WindowId>, savedFocusedIndex: Int?, savedViewportOffset: CGFloat) {
        var restoredColumns: [WindowColumn] = []
        var placedWindowIds = Set<WindowId>()
        var remainingWindows = availableWindows
        
        for savedCol in savedLayout.columns {
            var colWindowIds: [WindowId] = []
            
            for signature in savedCol.windowSignatures {
                // Find matching running window: prefer title match, fallback to bundleIdentifier
                if let matchIdx = remainingWindows.firstIndex(where: {
                    $0.bundleIdentifier == signature.bundleIdentifier &&
                    ($0.title == signature.title || signature.title == nil)
                }) {
                    let win = remainingWindows.remove(at: matchIdx)
                    colWindowIds.append(win.id)
                    placedWindowIds.insert(win.id)
                } else if let matchIdx = remainingWindows.firstIndex(where: {
                    $0.bundleIdentifier == signature.bundleIdentifier
                }) {
                    let win = remainingWindows.remove(at: matchIdx)
                    colWindowIds.append(win.id)
                    placedWindowIds.insert(win.id)
                }
            }
            
            if !colWindowIds.isEmpty {
                let clampedWidth = max(380.0, min(visibleWidth, savedCol.width))
                var lockedIds = Set<WindowId>()
                if let lockedIndices = savedCol.lockedWindowIndices {
                    for lIdx in lockedIndices where lIdx >= 0 && lIdx < colWindowIds.count {
                        lockedIds.insert(colWindowIds[lIdx])
                    }
                }
                var customTabTitles: [WindowId: String] = [:]
                if let titlesMap = savedCol.customTabTitlesBySignature {
                    for (idx, wId) in colWindowIds.enumerated() {
                        if idx < savedCol.windowSignatures.count {
                            let sig = savedCol.windowSignatures[idx]
                            let key = "\(sig.bundleIdentifier):\(sig.title ?? "")"
                            if let custom = titlesMap[key] {
                                customTabTitles[wId] = custom
                            }
                        }
                    }
                }
                var column = WindowColumn(
                    windowIds: colWindowIds,
                    width: clampedWidth,
                    presentationMode: savedCol.presentationMode ?? .stacked,
                    activeWindowIndex: min(max(0, savedCol.activeWindowIndex ?? 0), colWindowIds.count - 1),
                    tabBarPinned: savedCol.tabBarPinned ?? false,
                    customGroupName: savedCol.customGroupName,
                    customColorHex: savedCol.customColorHex,
                    isCollapsed: savedCol.isCollapsed ?? false,
                    lockedWindowIds: lockedIds,
                    customTabTitles: customTabTitles
                )
                column.normalizeTabPresentation()
                restoredColumns.append(column)
            }
        }
        
        let validFocusedIndex: Int? = {
            guard let idx = savedLayout.focusedColumnIndex, !restoredColumns.isEmpty else { return nil }
            return min(max(0, idx), restoredColumns.count - 1)
        }()
        
        return (
            restoredColumns: restoredColumns,
            placedWindowIds: placedWindowIds,
            savedFocusedIndex: validFocusedIndex,
            savedViewportOffset: savedLayout.viewportOffset
        )
    }
}
