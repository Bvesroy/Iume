import AppKit
import SwiftUI
import Combine

/// Model representing a column entry inside the Strip Overview modal.
public struct OverviewColumnData: Identifiable, Sendable {
    public let id: UUID
    public var previewItem: WindowPreviewItem?
    public var columnWidth: CGFloat
    public var windowCount: Int
    
    public init(
        id: UUID,
        previewItem: WindowPreviewItem? = nil,
        columnWidth: CGFloat = 800,
        windowCount: Int = 1
    ) {
        self.id = id
        self.previewItem = previewItem
        self.columnWidth = columnWidth
        self.windowCount = windowCount
    }
}

/// Floating modal controller that presents a panoramic, interactive preview of all apps in the strip.
/// Supports smooth transitions and direct drag-and-drop column reordering.
@MainActor
public final class StripOverviewController: ObservableObject {
    public static let shared = StripOverviewController()
    
    @Published public var columns: [OverviewColumnData] = []
    @Published public var focusedColumnIndex: Int = 0
    @Published public var isPresented: Bool = false
    
    private var window: NSPanel?
    private var hostingView: NSHostingView<StripOverviewView>?
    private var keyMonitor: Any?
    private var isTransitioning: Bool = false
    
    public init() {}
    
    /// Toggles the strip overview on or off.
    public func toggle() {
        if isPresented || window?.isVisible == true {
            dismiss(selectedColumnIndex: nil)
        } else {
            present()
        }
    }
    
    /// Shows the overview with a smooth transition.
    public func present() {
        guard !isTransitioning else { return }
        
        let wm = WorkspaceManager.shared
        guard let ws = wm.workspaces[wm.activeDisplayId], !ws.columns.isEmpty else {
            return
        }
        
        let registry = wm.registry
        var items: [OverviewColumnData] = []
        
        for col in ws.columns {
            var preview: WindowPreviewItem? = nil
            if let firstWinId = col.windowIds.first, let win = registry.get(windowId: firstWinId) {
                let ax = registry.getAXElement(windowId: firstWinId)
                let cgid = ax.flatMap { registry.getCGWindowID(for: firstWinId, ax: $0) }
                preview = WindowPreviewCapturer.capturePreview(
                    for: win,
                    cgWindowId: cgid,
                    columnId: col.id,
                    stackedCount: col.windowIds.count
                )
            }
            items.append(
                OverviewColumnData(
                    id: col.id,
                    previewItem: preview,
                    columnWidth: col.width,
                    windowCount: col.windowIds.count
                )
            )
        }
        
        self.columns = items
        self.focusedColumnIndex = min(items.count - 1, max(0, ws.focusedColumnIndex ?? 0))
        
        let screen = wm.cachedScreen(for: wm.activeDisplayId) ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen = screen else { return }
        
        if window == nil {
            setupPanel(frame: targetScreen.frame)
        } else if let win = window {
            win.setFrame(targetScreen.frame, display: true)
        }
        
        guard let panel = window else { return }
        
        isTransitioning = true
        panel.alphaValue = 0.0
        panel.orderFront(nil)
        isPresented = true
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isTransitioning = false
            }
        })
        
        setupKeyMonitor()
    }
    
    private func setupPanel(frame: NSRect) {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.isFloatingPanel = true
        p.hasShadow = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        
        let view = StripOverviewView(controller: self)
        let host = NSHostingView(rootView: view)
        p.contentView = host
        
        self.window = p
        self.hostingView = host
    }
    
    private func setupKeyMonitor() {
        tearDownKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isPresented else { return event }
            
            switch event.keyCode {
            case 53: // ESC
                self.dismiss(selectedColumnIndex: nil)
                return nil
            case 36, 76: // Enter / Return
                self.dismiss(selectedColumnIndex: self.focusedColumnIndex)
                return nil
            case 123: // Left Arrow
                if self.focusedColumnIndex > 0 {
                    self.focusedColumnIndex -= 1
                }
                return nil
            case 124: // Right Arrow
                if self.focusedColumnIndex < self.columns.count - 1 {
                    self.focusedColumnIndex += 1
                }
                return nil
            default:
                return event
            }
        }
    }
    
    private func tearDownKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    /// Reorders column positions locally during live drag gestures.
    public func reorderColumnLocally(from source: Int, to destination: Int) {
        guard source != destination,
              source >= 0, source < columns.count,
              destination >= 0, destination < columns.count else { return }
        
        let item = columns.remove(at: source)
        columns.insert(item, at: destination)
        
        if focusedColumnIndex == source {
            focusedColumnIndex = destination
        } else if source < focusedColumnIndex && destination >= focusedColumnIndex {
            focusedColumnIndex -= 1
        } else if source > focusedColumnIndex && destination <= focusedColumnIndex {
            focusedColumnIndex += 1
        }
    }
    
    /// Commits the newly arranged column order to WorkspaceManager and updates the live screen layout.
    public func commitReorderToWorkspace() {
        let wm = WorkspaceManager.shared
        guard let ws = wm.workspaces[wm.activeDisplayId] else { return }
        
        var newColumns: [WindowColumn] = []
        for colData in columns {
            if let originalCol = ws.columns.first(where: { $0.id == colData.id }) {
                newColumns.append(originalCol)
            }
        }
        
        guard newColumns.count == ws.columns.count else { return }
        wm.reorderColumns(newColumns: newColumns)
    }
    
    /// Closes the overview and optionally selects and focuses a target column.
    public func dismiss(selectedColumnIndex: Int?) {
        guard !isTransitioning else { return }
        tearDownKeyMonitor()
        
        guard let panel = window, panel.isVisible else {
            isPresented = false
            return
        }
        
        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                panel.orderOut(nil)
                self.isPresented = false
                self.isTransitioning = false
                
                if let chosenIndex = selectedColumnIndex {
                    WorkspaceManager.shared.selectAndFocusColumn(at: chosenIndex)
                }
            }
        })
    }
}
