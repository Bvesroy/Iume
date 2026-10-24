import AppKit
import SwiftUI

// MARK: - Color & Preset Helpers

extension Color {
    init?(hex: String?) {
        guard let hex = hex?.trimmingCharacters(in: CharacterSet.alphanumerics.inverted),
              hex.count == 6,
              let intVal = UInt64(hex, radix: 16) else { return nil }
        let r = Double((intVal >> 16) & 0xFF) / 255.0
        let g = Double((intVal >> 8) & 0xFF) / 255.0
        let b = Double(intVal & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

public struct TabGroupColorPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let hex: String
    
    public static let all: [TabGroupColorPreset] = [
        TabGroupColorPreset(id: "blue", name: "Ocean Blue", hex: "007AFF"),
        TabGroupColorPreset(id: "purple", name: "Royal Purple", hex: "AF52DE"),
        TabGroupColorPreset(id: "pink", name: "Rose Pink", hex: "FF2D55"),
        TabGroupColorPreset(id: "orange", name: "Sunset Orange", hex: "FF9500"),
        TabGroupColorPreset(id: "green", name: "Emerald Green", hex: "34C759"),
        TabGroupColorPreset(id: "teal", name: "Neon Teal", hex: "30B0C7"),
        TabGroupColorPreset(id: "indigo", name: "Deep Indigo", hex: "5856D6")
    ]
}

@MainActor
public func promptUserForText(title: String, message: String, initialValue: String, completion: @escaping (String?) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    input.stringValue = initialValue
    alert.accessoryView = input
    alert.window.initialFirstResponder = input
    
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        completion(input.stringValue)
    } else {
        completion(nil)
    }
}

// MARK: - Tab Bar Overlay Controller

/// Observable state for one floating tab bar. Keeping the model separate from
/// the hosting view lets SwiftUI animate tab insertion, removal and reordering
/// instead of rebuilding the whole panel on every change.
@MainActor
public final class TabBarViewModel: ObservableObject {
    public let columnId: UUID
    @Published public private(set) var windows: [ManagedWindow]
    @Published public private(set) var activeWindowId: WindowId?
    @Published public private(set) var candidates: [ManagedWindow]
    @Published public private(set) var isPinned: Bool
    @Published public private(set) var appName: String
    @Published public private(set) var isPresented: Bool = true
    
    @Published public private(set) var customGroupName: String?
    @Published public private(set) var customColorHex: String?
    @Published public private(set) var isCollapsed: Bool
    @Published public private(set) var lockedWindowIds: Set<WindowId>
    @Published public private(set) var customTabTitles: [WindowId: String]
    @Published public private(set) var otherColumns: [(id: UUID, title: String)]
    @Published public private(set) var isCompactMode: Bool

    public init(
        columnId: UUID,
        windows: [ManagedWindow],
        activeWindowId: WindowId?,
        candidates: [ManagedWindow],
        isPinned: Bool,
        customGroupName: String? = nil,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        lockedWindowIds: Set<WindowId> = [],
        customTabTitles: [WindowId: String] = [:],
        otherColumns: [(id: UUID, title: String)] = [],
        isCompactMode: Bool = false
    ) {
        self.columnId = columnId
        self.windows = windows
        self.activeWindowId = activeWindowId
        self.candidates = candidates
        self.isPinned = isPinned
        self.appName = windows.first?.appName ?? "Application"
        self.customGroupName = customGroupName
        self.customColorHex = customColorHex
        self.isCollapsed = isCollapsed
        self.lockedWindowIds = lockedWindowIds
        self.customTabTitles = customTabTitles
        self.otherColumns = otherColumns
        self.isCompactMode = isCompactMode
    }
    
    public var isTabGroup: Bool {
        windows.count > 1 || customGroupName != nil
    }

    public var effectiveGroupName: String {
        if let customGroupName, !customGroupName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customGroupName
        }
        return appName
    }

    public var accentColor: Color {
        if let customColorHex, let custom = Color(hex: customColorHex) {
            return custom
        }
        return Color.accentColor
    }

    public func effectiveTitle(for windowId: WindowId, defaultTitle: String) -> String {
        if let custom = customTabTitles[windowId], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return defaultTitle.isEmpty ? appName : defaultTitle
    }

    public func isLocked(_ windowId: WindowId) -> Bool {
        lockedWindowIds.contains(windowId)
    }

    public func update(
        windows: [ManagedWindow],
        activeWindowId: WindowId?,
        candidates: [ManagedWindow],
        isPinned: Bool,
        customGroupName: String? = nil,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        lockedWindowIds: Set<WindowId> = [],
        customTabTitles: [WindowId: String] = [:],
        otherColumns: [(id: UUID, title: String)] = [],
        isCompactMode: Bool = false
    ) {
        let appName = windows.first?.appName ?? self.appName
        if !self.windows.matchesTabContent(windows) { self.windows = windows }
        if self.activeWindowId != activeWindowId { self.activeWindowId = activeWindowId }
        if !self.candidates.matchesTabContent(candidates) { self.candidates = candidates }
        if self.isPinned != isPinned { self.isPinned = isPinned }
        if self.appName != appName { self.appName = appName }
        if self.customGroupName != customGroupName { self.customGroupName = customGroupName }
        if self.customColorHex != customColorHex { self.customColorHex = customColorHex }
        if self.isCollapsed != isCollapsed { self.isCollapsed = isCollapsed }
        if self.lockedWindowIds != lockedWindowIds { self.lockedWindowIds = lockedWindowIds }
        if self.customTabTitles != customTabTitles { self.customTabTitles = customTabTitles }
        if self.otherColumns.map(\.id) != otherColumns.map(\.id) { self.otherColumns = otherColumns }
        if self.isCompactMode != isCompactMode { self.isCompactMode = isCompactMode }
    }

    public func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
    }
}

private extension Array where Element == ManagedWindow {
    /// Compares only the values rendered by `TabBarView`.
    func matchesTabContent(_ other: [ManagedWindow]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { lhs, rhs in
            lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.appName == rhs.appName &&
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }
    }
}

/// Specialized NSPanel that never attempts to become key or main window,
/// preventing AppKit key-window tracking warnings and runloop freezes when clicked.
final class NonActivatingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Interactive 28pt Chrome-style tab strip displayed above a tabbed column.
/// Supports click-to-switch, close, add (new or existing window), drag reorder,
/// drag-out-to-detach and pinning a single-window group open.
@MainActor
public final class TabBarOverlayController {
    public static let shared = TabBarOverlayController()
    
    public var onTabSelected: ((WindowId, UUID) -> Void)?
    public var onCloseTab: ((WindowId, UUID) -> Void)?
    public var onAddNewWindow: ((UUID) -> Void)?
    public var onAddExistingWindow: ((WindowId, UUID) -> Void)?
    public var onReorderTab: ((WindowId, UUID, Int) -> Void)?
    public var onDetachTab: ((WindowId, UUID) -> Void)?
    public var onUngroupAll: ((UUID) -> Void)?
    public var onTogglePin: ((UUID) -> Void)?
    
    public var onMoveTabBetweenColumns: ((WindowId, UUID, UUID) -> Void)?
    public var onCloseOtherTabs: ((WindowId, UUID) -> Void)?
    public var onCloseTabsToRight: ((WindowId, UUID) -> Void)?
    public var onRenameTab: ((WindowId, UUID, String) -> Void)?
    public var onResetTabTitle: ((WindowId, UUID) -> Void)?
    public var onToggleLockTab: ((WindowId, UUID) -> Void)?
    public var onRenameGroup: ((UUID, String) -> Void)?
    public var onChangeGroupColor: ((UUID, String?) -> Void)?
    public var onToggleCollapseGroup: ((UUID) -> Void)?
    public var onDuplicateTab: ((WindowId, UUID) -> Void)?
    
    private var panels: [UUID: NSPanel] = [:]
    private var models: [UUID: TabBarViewModel] = [:]
    private var hostingViews: [UUID: NSHostingView<TabBarView>] = [:]
    private var displayByColumn: [UUID: CGDirectDisplayID] = [:]
    /// Panels linger briefly after their group disappears so the exit
    /// transition can finish instead of vanishing in one frame.
    private var pendingRemovals: [UUID: DispatchWorkItem] = [:]
    
    public init() {}
    
    /// Updates every tab bar belonging to one display. Column frames are supplied
    /// by the layout engine so the bars stay glued to their columns while the
    /// strip scrolls or resizes.
    public func updateTabs(
        for columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        visibleFrame: CGRect,
        displayId: CGDirectDisplayID,
        primaryScreenHeight: CGFloat,
        columnFrames: [UUID: ColumnScreenFrame]
    ) {
        var activeColumnIds = Set<UUID>()
        
        for column in columns where column.showsTabBar {
            guard let columnFrame = columnFrames[column.id],
                  !columnFrame.isParked,
                  columnFrame.frame.maxX > visibleFrame.minX + 24,
                  columnFrame.frame.minX < visibleFrame.maxX - 24 else { continue }
            
            let tabBarFrame = CGRect(
                x: columnFrame.frame.minX,
                y: primaryScreenHeight - (columnFrame.frame.minY + PureStripLayoutEngine.tabBarHeight),
                width: max(1, columnFrame.frame.width),
                height: PureStripLayoutEngine.tabBarHeight
            )
            
            activeColumnIds.insert(column.id)
            displayByColumn[column.id] = displayId
            
            let memberWindows = column.windowIds.compactMap { windows[$0] }
            let activeWindowId = column.activeWindowId
            let bundleId = memberWindows.first?.bundleIdentifier ?? ""
            
            // Other windows of the same app can be attached with the "+" menu.
            let candidates = windows.values
                .filter { candidate in
                    guard !candidate.isFloating, !candidate.isMinimized, !column.windowIds.contains(candidate.id) else { return false }
                    if !bundleId.isEmpty { return candidate.bundleIdentifier == bundleId }
                    return candidate.pid == memberWindows.first?.pid
                }
                .sorted { lhs, rhs in
                    if lhs.title == rhs.title { return lhs.id.rawId < rhs.id.rawId }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            
            let otherCols: [(id: UUID, title: String)] = columns
                .filter { $0.id != column.id }
                .compactMap { col in
                    let win = col.activeWindowId.flatMap { windows[$0] } ?? (col.windowIds.first.flatMap { windows[$0] })
                    let title = col.customGroupName ?? win?.appName ?? "Column"
                    return (col.id, title)
                }
            
            let model = getOrCreateModel(
                for: column.id,
                windows: memberWindows,
                activeWindowId: activeWindowId,
                candidates: candidates,
                isPinned: column.tabBarPinned,
                customGroupName: column.customGroupName,
                customColorHex: column.customColorHex,
                isCollapsed: column.isCollapsed,
                lockedWindowIds: column.lockedWindowIds,
                customTabTitles: column.customTabTitles,
                otherColumns: otherCols,
                isCompactMode: SettingsStore.shared.tabBarCompactMode
            )
            model.update(
                windows: memberWindows,
                activeWindowId: activeWindowId,
                candidates: candidates,
                isPinned: column.tabBarPinned,
                customGroupName: column.customGroupName,
                customColorHex: column.customColorHex,
                isCollapsed: column.isCollapsed,
                lockedWindowIds: column.lockedWindowIds,
                customTabTitles: column.customTabTitles,
                otherColumns: otherCols,
                isCompactMode: SettingsStore.shared.tabBarCompactMode
            )
            
            // A returning group cancels its pending exit and animates back in.
            if let pending = pendingRemovals.removeValue(forKey: column.id) {
                pending.cancel()
            }
            model.setPresented(true)
            
            let panel = getOrCreatePanel(for: column.id)
            panel.ignoresMouseEvents = false
            
            if abs(panel.frame.minX - tabBarFrame.minX) > 0.25 ||
                abs(panel.frame.minY - tabBarFrame.minY) > 0.25 ||
                abs(panel.frame.width - tabBarFrame.width) > 0.25 ||
                abs(panel.frame.height - tabBarFrame.height) > 0.25 {
                panel.setFrame(tabBarFrame, display: false)
            }
            if !panel.isVisible {
                panel.orderFront(nil)
            }
        }
        
        // Animate bars out on this display whose groups disappeared (or fell
        // back to a single unpinned tab), then release their hosting views.
        let staleIds = panels.keys.filter { id in
            displayByColumn[id] == displayId && !activeColumnIds.contains(id)
        }
        for id in staleIds {
            scheduleAnimatedRemoval(for: id)
        }
    }
    
    public func hideTabs(for displayId: CGDirectDisplayID) {
        for id in panels.keys where displayByColumn[id] == displayId {
            scheduleAnimatedRemoval(for: id)
        }
    }
    
    public func hideAll() {
        for item in pendingRemovals.values { item.cancel() }
        pendingRemovals.removeAll()
        for (_, panel) in panels where panel.isVisible {
            panel.orderOut(nil)
        }
        panels.removeAll()
        models.removeAll()
        hostingViews.removeAll()
        displayByColumn.removeAll()
    }
    
    /// Starts an exit transition once and removes the panel after it settles.
    private func scheduleAnimatedRemoval(for id: UUID) {
        guard pendingRemovals[id] == nil else { return }
        models[id]?.setPresented(false)
        panels[id]?.ignoresMouseEvents = true
        
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panels[id]?.orderOut(nil)
            self.panels.removeValue(forKey: id)
            self.models.removeValue(forKey: id)
            self.hostingViews.removeValue(forKey: id)
            self.displayByColumn.removeValue(forKey: id)
            self.pendingRemovals.removeValue(forKey: id)
        }
        pendingRemovals[id] = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TabMotionProfile.current.barDismissDelay,
            execute: item
        )
    }
    
    private func getOrCreateModel(
        for columnId: UUID,
        windows: [ManagedWindow],
        activeWindowId: WindowId?,
        candidates: [ManagedWindow],
        isPinned: Bool,
        customGroupName: String? = nil,
        customColorHex: String? = nil,
        isCollapsed: Bool = false,
        lockedWindowIds: Set<WindowId> = [],
        customTabTitles: [WindowId: String] = [:],
        otherColumns: [(id: UUID, title: String)] = [],
        isCompactMode: Bool = false
    ) -> TabBarViewModel {
        if let existing = models[columnId] { return existing }
        let model = TabBarViewModel(
            columnId: columnId,
            windows: windows,
            activeWindowId: activeWindowId,
            candidates: candidates,
            isPinned: isPinned,
            customGroupName: customGroupName,
            customColorHex: customColorHex,
            isCollapsed: isCollapsed,
            lockedWindowIds: lockedWindowIds,
            customTabTitles: customTabTitles,
            otherColumns: otherColumns,
            isCompactMode: isCompactMode
        )
        models[columnId] = model
        return model
    }
    
    private func getOrCreatePanel(for columnId: UUID) -> NSPanel {
        if let existing = panels[columnId] { return existing }
        
        let panel = NonActivatingOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        
        guard let model = models[columnId] else { return panel }
        let rootView = TabBarView(
            model: model,
            onSelectTab: { [weak self] windowId in
                guard let self else { return }
                self.onTabSelected?(windowId, columnId)
            },
            onCloseTab: { [weak self] windowId in
                guard let self else { return }
                self.onCloseTab?(windowId, columnId)
            },
            onAddNewWindow: { [weak self] in
                self?.onAddNewWindow?(columnId)
            },
            onAddExistingWindow: { [weak self] windowId in
                self?.onAddExistingWindow?(windowId, columnId)
            },
            onReorderTab: { [weak self] windowId, newIndex in
                self?.onReorderTab?(windowId, columnId, newIndex)
            },
            onDetachTab: { [weak self] windowId in
                self?.onDetachTab?(windowId, columnId)
            },
            onUngroupAll: { [weak self] in
                self?.onUngroupAll?(columnId)
            },
            onTogglePin: { [weak self] in
                self?.onTogglePin?(columnId)
            },
            onMoveTabBetweenColumns: { [weak self] windowId, targetColId in
                self?.onMoveTabBetweenColumns?(windowId, columnId, targetColId)
            },
            onCloseOtherTabs: { [weak self] windowId in
                self?.onCloseOtherTabs?(windowId, columnId)
            },
            onCloseTabsToRight: { [weak self] windowId in
                self?.onCloseTabsToRight?(windowId, columnId)
            },
            onRenameTab: { [weak self] windowId, newTitle in
                self?.onRenameTab?(windowId, columnId, newTitle)
            },
            onResetTabTitle: { [weak self] windowId in
                self?.onResetTabTitle?(windowId, columnId)
            },
            onToggleLockTab: { [weak self] windowId in
                self?.onToggleLockTab?(windowId, columnId)
            },
            onRenameGroup: { [weak self] newName in
                self?.onRenameGroup?(columnId, newName)
            },
            onChangeGroupColor: { [weak self] newHex in
                self?.onChangeGroupColor?(columnId, newHex)
            },
            onToggleCollapseGroup: { [weak self] in
                self?.onToggleCollapseGroup?(columnId)
            },
            onDuplicateTab: { [weak self] windowId in
                self?.onDuplicateTab?(windowId, columnId)
            }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        hostingViews[columnId] = hosting
        panels[columnId] = panel
        return panel
    }
}

/// Cached application icon lookup used by tabs.
@MainActor
private enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    
    static func icon(for bundleIdentifier: String) -> NSImage? {
        guard !bundleIdentifier.isEmpty else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        guard !missing.contains(bundleIdentifier) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            missing.insert(bundleIdentifier)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleIdentifier] = image
        return image
    }
}

/// Helper view displaying an application icon from its bundle identifier.
struct AppIconImage: View {
    let bundleIdentifier: String
    let size: CGFloat
    
    init(bundleIdentifier: String, size: CGFloat = 14) {
        self.bundleIdentifier = bundleIdentifier
        self.size = size
    }
    
    var body: some View {
        Group {
            if let image = AppIconCache.icon(for: bundleIdentifier) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.78))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Google Chrome-style tab strip with live drag reordering and detach feedback.
public struct TabBarView: View {
    @ObservedObject public var model: TabBarViewModel
    @ObservedObject private var settings = SettingsStore.shared
    
    public let onSelectTab: (WindowId) -> Void
    public let onCloseTab: (WindowId) -> Void
    public let onAddNewWindow: () -> Void
    public let onAddExistingWindow: (WindowId) -> Void
    public let onReorderTab: (WindowId, Int) -> Void
    public let onDetachTab: (WindowId) -> Void
    public let onUngroupAll: () -> Void
    public let onTogglePin: () -> Void
    
    public var onMoveTabBetweenColumns: ((WindowId, UUID) -> Void)?
    public var onCloseOtherTabs: ((WindowId) -> Void)?
    public var onCloseTabsToRight: ((WindowId) -> Void)?
    public var onRenameTab: ((WindowId, String) -> Void)?
    public var onResetTabTitle: ((WindowId) -> Void)?
    public var onToggleLockTab: ((WindowId) -> Void)?
    public var onRenameGroup: ((String) -> Void)?
    public var onChangeGroupColor: ((String?) -> Void)?
    public var onToggleCollapseGroup: (() -> Void)?
    public var onDuplicateTab: ((WindowId) -> Void)?
    
    @State private var localOrder: [WindowId] = []
    @State private var hoveredTabId: WindowId?
    @State private var isAddHovered = false
    @State private var isMenuHovered = false
    @State private var draggingId: WindowId?
    @State private var dragStartIndex = 0
    @State private var dragTranslation: CGSize = .zero
    @State private var isDetachIntent = false
    @State private var visibility: CGFloat = 0
    @Namespace private var activeTabNamespace
    
    private let tabSpacing: CGFloat = 3
    private let addButtonWidth: CGFloat = 26
    private let menuButtonWidth: CGFloat = 24
    private let horizontalPadding: CGFloat = 10
    
    private var detachThreshold: CGFloat {
        CGFloat(settings.tabDetachThreshold)
    }
    
    public init(
        model: TabBarViewModel,
        onSelectTab: @escaping (WindowId) -> Void,
        onCloseTab: @escaping (WindowId) -> Void,
        onAddNewWindow: @escaping () -> Void,
        onAddExistingWindow: @escaping (WindowId) -> Void,
        onReorderTab: @escaping (WindowId, Int) -> Void,
        onDetachTab: @escaping (WindowId) -> Void,
        onUngroupAll: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onMoveTabBetweenColumns: ((WindowId, UUID) -> Void)? = nil,
        onCloseOtherTabs: ((WindowId) -> Void)? = nil,
        onCloseTabsToRight: ((WindowId) -> Void)? = nil,
        onRenameTab: ((WindowId, String) -> Void)? = nil,
        onResetTabTitle: ((WindowId) -> Void)? = nil,
        onToggleLockTab: ((WindowId) -> Void)? = nil,
        onRenameGroup: ((String) -> Void)? = nil,
        onChangeGroupColor: ((String?) -> Void)? = nil,
        onToggleCollapseGroup: (() -> Void)? = nil,
        onDuplicateTab: ((WindowId) -> Void)? = nil
    ) {
        self.model = model
        self.onSelectTab = onSelectTab
        self.onCloseTab = onCloseTab
        self.onAddNewWindow = onAddNewWindow
        self.onAddExistingWindow = onAddExistingWindow
        self.onReorderTab = onReorderTab
        self.onDetachTab = onDetachTab
        self.onUngroupAll = onUngroupAll
        self.onTogglePin = onTogglePin
        self.onMoveTabBetweenColumns = onMoveTabBetweenColumns
        self.onCloseOtherTabs = onCloseOtherTabs
        self.onCloseTabsToRight = onCloseTabsToRight
        self.onRenameTab = onRenameTab
        self.onResetTabTitle = onResetTabTitle
        self.onToggleLockTab = onToggleLockTab
        self.onRenameGroup = onRenameGroup
        self.onChangeGroupColor = onChangeGroupColor
        self.onToggleCollapseGroup = onToggleCollapseGroup
        self.onDuplicateTab = onDuplicateTab
    }
    
    private var orderedWindows: [ManagedWindow] {
        let byId = Dictionary(uniqueKeysWithValues: model.windows.map { ($0.id, $0) })
        let ids = localOrder.isEmpty ? model.windows.map(\.id) : localOrder
        let ordered = ids.compactMap { byId[$0] }
        let missing = model.windows.filter { !ids.contains($0.id) }
        let all = ordered + missing
        if model.isCollapsed {
            if let activeId = model.activeWindowId, let activeWin = all.first(where: { $0.id == activeId }) {
                return [activeWin]
            }
            return all.isEmpty ? [] : [all[0]]
        }
        return all
    }
    
    private var motion: TabMotionProfile {
        TabMotionProfile(
            isEnabled: settings.tabAnimationsEnabled,
            switchEffect: settings.tabSwitchEffect,
            openCloseEffect: settings.tabOpenCloseEffect,
            speed: settings.tabMotionSpeed,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let tabWidth = computedTabWidth(availableWidth: geometry.size.width)
            let compact = tabWidth < 84 || model.isCompactMode
            
            HStack(spacing: tabSpacing) {
                // Group Pill / Badge (Section 7)
                groupPill
                
                if model.isCollapsed {
                    HStack(spacing: 6) {
                        Text("\(model.windows.count) tabs")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                        Button("Expand") {
                            onToggleCollapseGroup?()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(model.accentColor)
                    }
                    .padding(.horizontal, 4)
                } else {
                    // Horizontally Scrollable Tab Strip (Section 3)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: tabSpacing) {
                                ForEach(orderedWindows) { window in
                                    tabView(window, width: tabWidth, compact: compact)
                                        .id(window.id)
                                }
                            }
                        }
                        .onChange(of: model.activeWindowId) { _, newActiveId in
                            if let newActiveId {
                                withAnimation(motion.switchAnimation) {
                                    proxy.scrollTo(newActiveId, anchor: .center)
                                }
                            }
                        }
                    }
                    
                    addButton
                    groupMenuButton
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: geometry.size.width, height: PureStripLayoutEngine.tabBarHeight, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.44))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(
                        isDetachIntent ? Color.orange.opacity(0.85) : model.accentColor.opacity(model.customColorHex != nil ? 0.35 : 0.16),
                        lineWidth: isDetachIntent ? 1.5 : 1
                    )
            )
            .overlay(alignment: .trailing) {
                if isDetachIntent {
                    detachBadge
                        .padding(.trailing, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .shadow(color: Color.black.opacity(0.35), radius: 5, x: 0, y: 2)
            .scaleEffect(1 - (1 - visibility) * (1 - motion.barHiddenScale), anchor: .top)
            .offset(y: (1 - visibility) * motion.barHiddenOffset)
            .blur(radius: (1 - visibility) * motion.barHiddenBlur)
            .opacity(Double(visibility))
            .onAppear {
                if localOrder.isEmpty { localOrder = model.windows.map(\.id) }
                withAnimation(motion.barAnimation) {
                    visibility = 1
                }
            }
            .onChange(of: model.isPresented) { _, presented in
                withAnimation(motion.barAnimation) {
                    visibility = presented ? 1 : 0
                }
            }
            .onChange(of: model.windows.map(\.id)) { _, newIds in
                if draggingId == nil {
                    withAnimation(motion.reorderAnimation) {
                        localOrder = newIds
                    }
                }
            }
            .animation(motion.openCloseAnimation, value: model.windows.map(\.id))
            .animation(motion.switchAnimation, value: model.activeWindowId)
        }
    }
    
    // MARK: - Group Pill / Visual Organization (Section 7)
    
    private var groupPill: some View {
        Menu {
            Button {
                promptUserForText(title: "Rename Tab Group", message: "Enter a custom name for this tab group:", initialValue: model.effectiveGroupName) { newName in
                    if let newName, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                        onRenameGroup?(newName)
                    }
                }
            } label: {
                Label("Rename Group...", systemImage: "pencil")
            }
            
            Menu("Group Color") {
                Button {
                    onChangeGroupColor?(nil)
                } label: {
                    Label("Default Accent", systemImage: model.customColorHex == nil ? "checkmark" : "circle")
                }
                Divider()
                ForEach(TabGroupColorPreset.all) { preset in
                    Button {
                        onChangeGroupColor?(preset.hex)
                    } label: {
                        Label(preset.name, systemImage: model.customColorHex == preset.hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            
            Button {
                onToggleCollapseGroup?()
            } label: {
                Label(model.isCollapsed ? "Expand Tab Group" : "Collapse Tab Group", systemImage: model.isCollapsed ? "chevron.right.2" : "chevron.left.2")
            }
            
            Divider()
            
            Button {
                onAddNewWindow()
            } label: {
                Label("New \(model.appName) Window", systemImage: "plus.rectangle.on.rectangle")
            }
            
            if model.windows.count > 1 {
                Divider()
                Button(role: .destructive) {
                    onUngroupAll()
                } label: {
                    Label("Ungroup All Tabs", systemImage: "rectangle.split.3x1")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(model.accentColor)
                    .frame(width: 7, height: 7)
                Text(model.effectiveGroupName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Image(systemName: model.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(0.60))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(model.accentColor.opacity(0.18))
            )
            .overlay(
                Capsule()
                    .stroke(model.accentColor.opacity(0.40), lineWidth: 0.8)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Tab Group: \(model.effectiveGroupName). Click for group options.")
    }
    
    // MARK: - Status Indicators
    
    private func isDirty(title: String) -> Bool {
        title.contains("•") || title.contains("— Edited") || title.contains(" (Edited)") || title.contains("*")
    }
    
    private func extractBadgeCount(title: String) -> String? {
        if let match = title.range(of: #"\([0-9]+\)"#, options: .regularExpression) {
            let str = String(title[match])
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        }
        return nil
    }

    // MARK: - One Tab
    
    @ViewBuilder
    private func tabView(_ window: ManagedWindow, width: CGFloat, compact: Bool) -> some View {
        let isActive = window.id == model.activeWindowId
        let isHovered = hoveredTabId == window.id
        let isDragging = draggingId == window.id
        let currentIndex = orderedWindows.firstIndex(where: { $0.id == window.id }) ?? 0
        let step = width + tabSpacing
        let compensatedOffset = isDragging
            ? dragTranslation.width - CGFloat(currentIndex - dragStartIndex) * step
            : 0
        let displayTitle = model.effectiveTitle(for: window.id, defaultTitle: window.title)
        let isLocked = model.isLocked(window.id)
        let dirty = isDirty(title: window.title)
        let badgeCount = extractBadgeCount(title: window.title)
        
        HStack(spacing: 5) {
            AppIconImage(bundleIdentifier: window.bundleIdentifier, size: compact ? 12 : 14)
            
            // Unsaved change dot indicator (Section 3)
            if dirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes")
            }
            
            // Notification badge indicator (Section 3)
            if let badgeCount {
                Text(badgeCount)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }
            
            // Locked indicator
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.65))
                    .help("Tab is locked against accidental closure")
            }
            
            if width >= 58 {
                Text(displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .white : Color.white.opacity(0.74))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Close button (or lock indicator if locked)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: 15, height: 15)
                    .help("Locked tab (cannot be closed)")
            } else {
                Button(action: { onCloseTab(window.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(isActive || isHovered ? .white.opacity(0.92) : .white.opacity(0.48))
                        .frame(width: 15, height: 15)
                        .background(
                            Circle().fill(Color.white.opacity(isHovered ? 0.22 : 0.001))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌃⌥⇧W)")
            }
        }
        .padding(.horizontal, compact ? 6 : 8)
        .frame(width: width, height: 24)
        .background {
            if isActive {
                if motion.usesMorphingHighlight {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.17))
                        .matchedGeometryEffect(id: "activeTabPill", in: activeTabNamespace)
                        .shadow(
                            color: motion.showsAccentGlow ? model.accentColor.opacity(0.50) : .clear,
                            radius: motion.showsAccentGlow ? 7 : 0
                        )
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.17))
                }
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.001))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    isActive ? model.accentColor.opacity(0.92) : Color.white.opacity(isHovered ? 0.10 : 0.001),
                    lineWidth: isActive ? 1.1 : 0.8
                )
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(model.accentColor)
                    .frame(height: 1.8)
                    .padding(.horizontal, 7)
                    .offset(y: 1)
            }
        }
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .opacity(isDragging ? 0.92 : 1.0)
        .shadow(color: Color.black.opacity(isDragging ? 0.45 : 0), radius: 7, x: 0, y: 4)
        .offset(x: compensatedOffset, y: isDetachIntent && isDragging ? 4 : 0)
        .rotationEffect(.degrees(isDetachIntent && isDragging ? -1.5 : 0))
        .zIndex(isDragging ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                motion.haptic(.alignment)
            }
            onSelectTab(window.id)
        }
        .onHover { hovering in
            hoveredTabId = hovering ? window.id : nil
            if hovering {
                NSCursor.pointingHand.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .local)
                .onChanged { value in
                    handleDragChanged(
                        windowId: window.id,
                        value: value,
                        tabWidth: width
                    )
                }
                .onEnded { value in
                    handleDragEnded(
                        windowId: window.id,
                        value: value,
                        tabWidth: width
                    )
                }
        )
        .help(displayTitle.isEmpty ? window.appName : "\(window.appName) — \(displayTitle)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityHint("Tab. Click to switch, right-click for options")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .contextMenu {
            Button {
                onAddNewWindow()
            } label: {
                Label("New Tab (⌃⌥⌘N)", systemImage: "plus")
            }
            
            Button {
                onDuplicateTab?(window.id)
            } label: {
                Label("Duplicate Tab", systemImage: "plus.square.on.square")
            }
            
            Button {
                promptUserForText(title: "Rename Tab", message: "Enter custom title for tab:", initialValue: displayTitle) { newTitle in
                    if let newTitle, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        onRenameTab?(window.id, newTitle)
                    }
                }
            } label: {
                Label("Rename Tab...", systemImage: "pencil")
            }
            
            if model.customTabTitles[window.id] != nil {
                Button {
                    onResetTabTitle?(window.id)
                } label: {
                    Label("Reset Tab Title", systemImage: "arrow.counterclockwise")
                }
            }
            
            Divider()
            
            Button {
                onToggleLockTab?(window.id)
            } label: {
                Label(isLocked ? "Unlock Tab" : "Lock Tab Against Closure", systemImage: isLocked ? "lock.open" : "lock")
            }
            
            if currentIndex > 0 {
                Button {
                    onReorderTab(window.id, currentIndex - 1)
                } label: {
                    Label("Move Tab Left", systemImage: "arrow.left")
                }
            }
            
            if currentIndex < orderedWindows.count - 1 {
                Button {
                    onReorderTab(window.id, currentIndex + 1)
                } label: {
                    Label("Move Tab Right", systemImage: "arrow.right")
                }
            }
            
            if !model.otherColumns.isEmpty {
                Menu("Move Tab to Group") {
                    ForEach(model.otherColumns, id: \.id) { col in
                        Button {
                            onMoveTabBetweenColumns?(window.id, col.id)
                        } label: {
                            Label(col.title, systemImage: "rectangle.on.rectangle")
                        }
                    }
                }
            }
            
            if model.windows.count > 1 {
                Button {
                    onDetachTab(window.id)
                } label: {
                    Label("Detach Tab into Window (⌃⌥⌘D)", systemImage: "arrow.up.forward.app")
                }
            }
            
            Divider()
            
            Button(role: .destructive) {
                onCloseTab(window.id)
            } label: {
                Label("Close Tab (⌃⌥⇧W)", systemImage: "xmark")
            }
            .disabled(isLocked)
            
            if model.windows.count > 1 {
                Button(role: .destructive) {
                    onCloseOtherTabs?(window.id)
                } label: {
                    Label("Close Other Tabs", systemImage: "xmark.circle")
                }
                
                if currentIndex < orderedWindows.count - 1 {
                    Button(role: .destructive) {
                        onCloseTabsToRight?(window.id)
                    } label: {
                        Label("Close Tabs to the Right", systemImage: "arrow.right.to.line")
                    }
                }
                
                Divider()
                
                Button(role: .destructive) {
                    onUngroupAll()
                } label: {
                    Label("Ungroup All Tabs (⌃⌥⇧U)", systemImage: "rectangle.split.3x1")
                }
            }
        }
        .animation(motion.reorderAnimation, value: localOrder)
        .transition(motion.tabTransition)
    }
    
    // MARK: - Add / Group Menu
    
    private var addButton: some View {
        Menu {
            Button {
                onAddNewWindow()
            } label: {
                Label("New \(model.appName) Window", systemImage: "plus.rectangle.on.rectangle")
            }
            
            if !model.candidates.isEmpty {
                Divider()
                Text("Add Existing Window")
                ForEach(model.candidates) { candidate in
                    Button {
                        onAddExistingWindow(candidate.id)
                    } label: {
                        Label(
                            candidate.title.isEmpty ? candidate.appName : candidate.title,
                            systemImage: "rectangle.on.rectangle"
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isAddHovered ? .white : Color.white.opacity(0.78))
                .frame(width: 21, height: 21)
                .background(Circle().fill(Color.white.opacity(isAddHovered ? 0.24 : 0.10)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: addButtonWidth, height: 24)
        .help("Add Tab: new or existing \(model.appName) window")
        .onHover { hovering in
            isAddHovered = hovering
            if hovering { NSCursor.pointingHand.set() }
        }
    }
    
    private var groupMenuButton: some View {
        Menu {
            Button {
                onTogglePin()
            } label: {
                Label(
                    model.isPinned ? "Unpin Tab Bar" : "Keep Tab Bar Visible",
                    systemImage: model.isPinned ? "pin.slash" : "pin"
                )
            }
            
            Divider()
            
            Button {
                onAddNewWindow()
            } label: {
                Label("New \(model.appName) Window", systemImage: "plus.rectangle.on.rectangle")
            }
            
            if model.windows.count > 1 {
                Divider()
                Button(role: .destructive) {
                    onUngroupAll()
                } label: {
                    Label("Ungroup All Tabs", systemImage: "rectangle.split.3x1")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isMenuHovered ? .white : Color.white.opacity(0.64))
                .frame(width: 19, height: 21)
                .background(Circle().fill(Color.white.opacity(isMenuHovered ? 0.18 : 0.001)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: menuButtonWidth, height: 24)
        .help("Tab Group Options")
        .onHover { hovering in
            isMenuHovered = hovering
            if hovering { NSCursor.pointingHand.set() }
        }
    }
    
    private var detachBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Detach")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 0.8))
        .allowsHitTesting(false)
    }
    
    // MARK: - Drag Handling
    
    private func handleDragChanged(windowId: WindowId, value: DragGesture.Value, tabWidth: CGFloat) {
        if draggingId == nil {
            draggingId = windowId
            dragStartIndex = orderedWindows.firstIndex(where: { $0.id == windowId }) ?? 0
            localOrder = orderedWindows.map(\.id)
        }
        
        dragTranslation = value.translation
        let wantsDetach = value.translation.height > detachThreshold || value.location.y > 38 || value.location.y < -12
        if wantsDetach != isDetachIntent {
            if wantsDetach {
                motion.haptic(.levelChange)
            }
            withAnimation(motion.quickAnimation) {
                isDetachIntent = wantsDetach
            }
        }
        
        guard !wantsDetach else { return }
        
        // Live reorder: the tab under the cursor swaps positions with its
        // neighbours while the rest of the strip slides out of the way.
        let step = max(1, tabWidth + tabSpacing)
        let shift = Int((value.translation.width / step).rounded())
        let targetIndex = min(max(0, dragStartIndex + shift), max(0, localOrder.count - 1))
        guard let currentIndex = localOrder.firstIndex(of: windowId), currentIndex != targetIndex else { return }
        
        withAnimation(motion.reorderAnimation) {
            let moved = localOrder.remove(at: currentIndex)
            localOrder.insert(moved, at: targetIndex)
        }
        motion.haptic(.alignment)
    }
    
    private func handleDragEnded(windowId: WindowId, value: DragGesture.Value, tabWidth: CGFloat) {
        let shouldDetach = isDetachIntent || value.translation.height > detachThreshold
        let finalIndex = localOrder.firstIndex(of: windowId)
        let originalIndex = dragStartIndex
        let moved = finalIndex != nil && finalIndex != originalIndex
        let wasClick = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
        
        draggingId = nil
        dragTranslation = .zero
        withAnimation(motion.quickAnimation) {
            isDetachIntent = false
        }
        
        if shouldDetach, model.windows.count > 1 {
            onDetachTab(windowId)
        } else if moved, let finalIndex, localOrder.contains(windowId) {
            onReorderTab(windowId, finalIndex)
        } else if wasClick {
            if model.activeWindowId != windowId {
                motion.haptic(.alignment)
            }
            onSelectTab(windowId)
        }
        
        // Let the model settle the canonical order again.
        withAnimation(motion.reorderAnimation) {
            localOrder = model.windows.map(\.id)
        }
    }
    
    // MARK: - Metrics
    
    private func computedTabWidth(availableWidth: CGFloat) -> CGFloat {
        let count = max(1, model.windows.count)
        let groupPillWidth: CGFloat = 80
        let reserved = horizontalPadding * 2 + groupPillWidth + addButtonWidth + menuButtonWidth + tabSpacing * 3
        let available = max(60, availableWidth - reserved)
        let width = (available - tabSpacing * CGFloat(count - 1)) / CGFloat(count)
        return min(178, max(38, width))
    }
}

// MARK: - Grouping Preview Overlay Controller (Section 4)

/// Floating translucent overlay that highlights the target window/column when a window is dragged
/// near or over it, showing a grouping badge preview before the user releases the mouse.
@MainActor
public final class GroupingPreviewOverlayController {
    public static let shared = GroupingPreviewOverlayController()
    
    private var panel: NSPanel?
    private var previewModel = GroupingPreviewModel()
    
    public init() {
        setupPanel()
    }
    
    private func setupPanel() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        
        let view = GroupingPreviewView(model: previewModel)
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        p.contentView = host
        self.panel = p
    }
    
    public func show(around frame: CGRect, title: String, appName: String, primaryScreenHeight: CGFloat) {
        guard let p = panel else { return }
        
        previewModel.title = title
        previewModel.appName = appName
        
        let cocoaFrame = CGRect(
            x: frame.minX - 4,
            y: primaryScreenHeight - frame.maxY - 4,
            width: frame.width + 8,
            height: frame.height + 8
        )
        
        if p.frame != cocoaFrame {
            p.setFrame(cocoaFrame, display: false)
        }
        
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 1.0
            }
        }
    }
    
    public func show(
        targetFrame: CGRect,
        targetDisplayId: CGDirectDisplayID? = nil,
        appName: String = "Tab Group",
        title: String = "Drop to Group as Tabs"
    ) {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        show(around: targetFrame, title: title, appName: appName, primaryScreenHeight: primaryScreenHeight)
    }
    
    public func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, let p = self.panel else { return }
                if p.alphaValue == 0.0 {
                    p.orderOut(nil)
                }
            }
        })
    }
}

@MainActor
public final class GroupingPreviewModel: ObservableObject {
    @Published public var title: String = ""
    @Published public var appName: String = ""
}

public struct GroupingPreviewView: View {
    @ObservedObject public var model: GroupingPreviewModel
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .shadow(color: Color.accentColor.opacity(0.45), radius: 8, x: 0, y: 0)
            
            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Drop to Group as Tab with \(model.title.isEmpty ? model.appName : model.title)")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.82))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.80), lineWidth: 1.2)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 2)
                .padding(.top, 14)
                
                Spacer()
            }
        }
        .padding(4)
        .allowsHitTesting(false)
    }
}

// MARK: - Inactive Window Dimming Overlay Controller

/// Translucent non-activating panel dimming unfocused windows on the active display.
@MainActor
public final class DimmingOverlayController {
    public static let shared = DimmingOverlayController()
    
    private var panel: NSPanel?
    
    public init() {
        setupPanel()
    }
    
    private func setupPanel() {
        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .normal
        p.ignoresMouseEvents = true
        p.hasShadow = false
        
        let view = DimmingVeilView()
        p.contentView = NSHostingView(rootView: view)
        self.panel = p
    }
    
    public func updateDimming(visibleFrame: CGRect, isFocusedFullscreen: Bool) {
        guard let p = panel else { return }
        guard SettingsStore.shared.dimUnfocusedWindows && !isFocusedFullscreen else {
            if p.isVisible {
                p.orderOut(nil)
            }
            return
        }
        
        if p.frame != visibleFrame {
            p.setFrame(visibleFrame, display: false)
        }
        if !p.isVisible {
            p.orderFront(nil)
        }
    }
    
    public func hide() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        }
    }
}

struct DimmingVeilView: View {
    var body: some View {
        Color.black.opacity(0.25)
            .animation(.easeInOut(duration: 0.20), value: true)
    }
}
