import AppKit
import SwiftUI

// MARK: - Priority 1A: Live Screen Footprint Preview Overlay (Loop & Rectangle Parity)

/// Renders a live translucent glass footprint rectangle on the screen showing the exact target box
/// where a window will snap while dragging to an edge/corner, using the Radial Menu, or dragging
/// across the Custom Box Grid Selector (before mouse-up).
@MainActor
public final class FootprintPreviewOverlayController: ObservableObject {
    public static let shared = FootprintPreviewOverlayController()
    
    private var panel: NSPanel?
    @Published public private(set) var isShowing: Bool = false
    @Published public var title: String = ""
    @Published public var dimensionsText: String = ""
    @Published public private(set) var currentQuartzFrame: CGRect = .zero
    
    public init() {}
    
    /// Converts a Quartz screen rect (origin at top-left of primary screen) to AppKit screen coordinates
    /// (origin at bottom-left of primary screen).
    public static func appKitRect(fromQuartzRect quartz: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080.0
        let appKitY = primaryHeight - quartz.origin.y - quartz.height
        return NSRect(x: quartz.origin.x, y: appKitY, width: quartz.width, height: quartz.height)
    }
    
    /// Displays or smoothly updates the live translucent glass footprint at `quartzFrame`.
    public func showPreview(quartzFrame: CGRect, title: String, subtitle: String? = nil) {
        guard quartzFrame.width >= 60, quartzFrame.height >= 60 else { return }
        let roundedQuartz = quartzFrame.integral
        let newDimensionsText: String
        if let sub = subtitle, !sub.isEmpty {
            newDimensionsText = sub
        } else {
            newDimensionsText = "\(Int(roundedQuartz.width)) × \(Int(roundedQuartz.height))"
        }
        if isShowing && currentQuartzFrame == roundedQuartz && self.title == title && self.dimensionsText == newDimensionsText {
            return
        }
        self.currentQuartzFrame = roundedQuartz
        if self.title != title { self.title = title }
        if self.dimensionsText != newDimensionsText { self.dimensionsText = newDimensionsText }
        
        if panel == nil {
            setupPanel()
        }
        guard let p = panel else { return }
        let targetNSRect = Self.appKitRect(fromQuartzRect: roundedQuartz)
        
        if !isShowing {
            isShowing = true
            p.setFrame(targetNSRect, display: true)
            p.alphaValue = 0.0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1.0
            }
        } else {
            let originDist = hypot(p.frame.origin.x - targetNSRect.origin.x, p.frame.origin.y - targetNSRect.origin.y)
            let sizeDist = hypot(p.frame.width - targetNSRect.width, p.frame.height - targetNSRect.height)
            let maxDelta = max(originDist, sizeDist)
            if maxDelta > 36.0 {
                // Distinct snap zone jump: animate smoothly
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.08
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    p.animator().setFrame(targetNSRect, display: true)
                }
            } else if maxDelta > 1.0 {
                // Continuous freeform draw: update directly without stacking overlapping NSAnimationContexts
                p.setFrame(targetNSRect, display: true)
            }
        }
    }
    
    public func hide() {
        guard isShowing, let p = panel else { return }
        isShowing = false
        currentQuartzFrame = .zero
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !self.isShowing {
                    p.orderOut(nil)
                }
            }
        })
    }
    
    private func setupPanel() {
        let view = FootprintPreviewView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = hosting
        self.panel = p
    }
}

struct FootprintPreviewView: View {
    @ObservedObject var controller: FootprintPreviewOverlayController
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.95), Color.cyan.opacity(0.80)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.5
                        )
                )
            
            VStack(spacing: 4) {
                Text(controller.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(controller.dimensionsText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.82))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.68))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
            )
        }
        .padding(2)
    }
}

// MARK: - Priority 1B: Loop-Style Cursor-Centered Radial Menu Controller

/// Interactive cursor-centered radial direction picker modeled after Loop.
/// Moving the cursor from the center anchor selects 8 compass sectors (inner ring = halves/quarters,
/// outer ring = thirds/two-thirds/maximize) while displaying the live target footprint on screen.
@MainActor
public final class RadialMenuOverlayController: ObservableObject {
    public static let shared = RadialMenuOverlayController()
    
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var localMonitor: Any?
    private var anchorAppKitPoint: CGPoint = .zero
    private var activeVisibleFrameQuartz: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)
    
    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var currentSelection: BoxTilingEngine.RadialSelection = .init(
        direction: .center,
        ring: .center,
        action: .center,
        angleDegrees: 0,
        distance: 0
    )
    
    public var onSelectAction: ((WindowBoxAction) -> Void)?
    
    public init() {}
    
    public func toggle(visibleFrameQuartz: CGRect) {
        if isActive {
            commitAndClose()
        } else {
            beginSession(at: NSEvent.mouseLocation, visibleFrameQuartz: visibleFrameQuartz)
        }
    }
    
    public func beginSession(at appKitCursorPoint: CGPoint, visibleFrameQuartz: CGRect) {
        self.anchorAppKitPoint = appKitCursorPoint
        self.activeVisibleFrameQuartz = visibleFrameQuartz
        self.isActive = true
        
        if panel == nil {
            setupPanel()
        }
        guard let p = panel else { return }
        
        let size: CGFloat = 240
        let frame = NSRect(
            x: appKitCursorPoint.x - size / 2.0,
            y: appKitCursorPoint.y - size / 2.0,
            width: size,
            height: size
        )
        p.setFrame(frame, display: true)
        p.alphaValue = 0.0
        p.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1.0
        }
        
        updateCursor(appKitPoint: appKitCursorPoint)
        installMonitors()
    }
    
    public func updateCursor(appKitPoint: CGPoint) {
        guard isActive else { return }
        let engine = BoxTilingEngine(
            windowGap: SettingsStore.shared.appsEdgeTogether ? 0.0 : CGFloat(SettingsStore.shared.windowGap),
            edgeMargins: SettingsStore.shared.edgeMargins
        )
        let sel = engine.resolveRadialSelection(
            origin: anchorAppKitPoint,
            cursor: appKitPoint,
            deadzoneRadius: 20.0,
            outerRingRadius: 72.0,
            yAxisIncreasesUpward: true
        )
        self.currentSelection = sel
        
        let targetFrame = engine.frame(for: sel.action, in: activeVisibleFrameQuartz)
        FootprintPreviewOverlayController.shared.showPreview(
            quartzFrame: targetFrame,
            title: sel.action.rawValue
        )
    }
    
    public func commitAndClose() {
        guard isActive else { return }
        let chosen = currentSelection.action
        cancel()
        if let callback = onSelectAction {
            callback(chosen)
        } else {
            WorkspaceManager.shared.snapActiveWindow(to: chosen)
        }
    }
    
    public func cancel() {
        guard isActive else { return }
        isActive = false
        removeMonitors()
        FootprintPreviewOverlayController.shared.hide()
        panel?.orderOut(nil)
    }
    
    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp, .keyDown]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleEvent(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleEvent(event)
            }
            return event
        }
    }
    
    private func removeMonitors() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
        if let l = localMonitor {
            NSEvent.removeMonitor(l)
            localMonitor = nil
        }
    }
    
    private func handleEvent(_ event: NSEvent) {
        guard isActive else { return }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            updateCursor(appKitPoint: NSEvent.mouseLocation)
        case .leftMouseUp, .rightMouseUp:
            commitAndClose()
        case .keyDown:
            if event.keyCode == 53 { // Escape
                cancel()
            } else if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
                commitAndClose()
            }
        default:
            break
        }
    }
    
    private func setupPanel() {
        let view = RadialMenuOverlayView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        p.contentView = hosting
        self.panel = p
    }
}

struct RadialMenuOverlayView: View {
    @ObservedObject var controller: RadialMenuOverlayController
    
    private let sectors: [(dir: BoxTilingEngine.RadialDirection, angle: Double, icon: String)] = [
        (.east, 0, "rectangle.righthalf.inset.filled"),
        (.northEast, -45, "rectangle.inset.topright.filled"),
        (.north, -90, "rectangle.tophalf.inset.filled"),
        (.northWest, -135, "rectangle.inset.topleft.filled"),
        (.west, 180, "rectangle.lefthalf.inset.filled"),
        (.southWest, 135, "rectangle.inset.bottomleft.filled"),
        (.south, 90, "rectangle.bottomhalf.inset.filled"),
        (.southEast, 45, "rectangle.inset.bottomright.filled")
    ]
    
    var body: some View {
        ZStack {
            // Outer glass ring
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 216, height: 216)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 8)
            
            // 8 directional icons around the ring
            ForEach(sectors, id: \.dir.rawValue) { item in
                let isSelected = controller.currentSelection.direction == item.dir
                let rad = item.angle * .pi / 180.0
                let radius: CGFloat = 76.0
                let x = cos(rad) * radius
                let y = sin(rad) * radius
                
                Button {
                    controller.onSelectAction?(controller.currentSelection.action)
                    controller.commitAndClose()
                } label: {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.white.opacity(0.10))
                            .frame(width: 40, height: 40)
                        Image(systemName: item.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .offset(x: x, y: y)
                .scaleEffect(isSelected ? 1.15 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isSelected)
            }
            
            // Center hub showing active action name & ring indicator
            VStack(spacing: 3) {
                Text(controller.currentSelection.action.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 82)
                    .lineLimit(2)
                Text(controller.currentSelection.ring == .outer ? "Outer Ring (1/3 • Max)" : "Click to Snap")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.70))
            }
            .frame(width: 92, height: 92)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Circle()
                            .stroke(
                                controller.currentSelection.direction == .center
                                    ? Color.accentColor
                                    : Color.white.opacity(0.20),
                                lineWidth: 2
                            )
                    )
            )
        }
        .frame(width: 240, height: 240)
    }
}

// MARK: - Priority 2: Interactive Custom Box Grid & Freeform Box Selector ("Adjust Any Way I Want")

/// Interactive floating HUD allowing the user to:
/// 1. Drag across any `N × M` grid of cells to snap the focused window into that exact box span.
/// 2. Draw any custom freeform box region ("adjust any way I want") with live desktop footprint preview.
/// 3. Apply multi-window custom box presets across all open windows.
@MainActor
public final class CustomGridOverlayController: ObservableObject {
    public static let shared = CustomGridOverlayController()
    
    private var panel: NSPanel?
    @Published public var isVisible: Bool = false
    @Published public var gridColumns: Int = 4
    @Published public var gridRows: Int = 3
    @Published public var isFreeformDrawMode: Bool = false
    @Published public var snapFreeformTo5Percent: Bool = true
    
    @Published public var dragStartCell: BoxTilingEngine.GridCellCoord? = nil
    @Published public var dragEndCell: BoxTilingEngine.GridCellCoord? = nil
    @Published public var freeformStartNorm: CGPoint? = nil
    @Published public var freeformCurrentNorm: CGPoint? = nil
    
    public init() {}
    
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }
    
    public func show() {
        if panel == nil {
            setupPanel()
        }
        guard let p = panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 540
        let h: CGFloat = 430
        p.setFrame(
            NSRect(x: vis.midX - w / 2.0, y: vis.midY - h / 2.0, width: w, height: h),
            display: true
        )
        isVisible = true
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }
    
    public func hide() {
        isVisible = false
        dragStartCell = nil
        dragEndCell = nil
        freeformStartNorm = nil
        freeformCurrentNorm = nil
        FootprintPreviewOverlayController.shared.hide()
        panel?.orderOut(nil)
    }
    
    private func setupPanel() {
        let view = CustomGridSelectorView(controller: self)
        let hosting = NSHostingView(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "Custom Box & Grid Selector"
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = hosting
        self.panel = p
    }
}

struct CustomGridSelectorView: View {
    @ObservedObject var controller: CustomGridOverlayController
    
    private let gridPresets: [(label: String, cols: Int, rows: Int)] = [
        ("2×2", 2, 2),
        ("3×2", 3, 2),
        ("3×3", 3, 3),
        ("4×3", 4, 3),
        ("4×4", 4, 4),
        ("6×3", 6, 3),
        ("6×4", 6, 4),
        ("8×4", 8, 4)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interactive Box & Grid Studio")
                        .font(.system(size: 16, weight: .bold))
                    Text(controller.isFreeformDrawMode
                         ? "Drag anywhere below to draw a custom window box in real time"
                         : "Drag across cells below to snap the active window into any custom span")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $controller.isFreeformDrawMode) {
                    Text("Grid Cells").tag(false)
                    Text("Freeform Draw").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            
            // Grid presets or Freeform snap toggle
            if !controller.isFreeformDrawMode {
                HStack(spacing: 6) {
                    Text("Grid Size:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(gridPresets, id: \.label) { preset in
                        let active = controller.gridColumns == preset.cols && controller.gridRows == preset.rows
                        Button(preset.label) {
                            controller.gridColumns = preset.cols
                            controller.gridRows = preset.rows
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: active ? .bold : .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(active ? Color.accentColor : Color.secondary.opacity(0.15))
                        )
                        .foregroundColor(active ? .white : .primary)
                    }
                    Spacer()
                }
            } else {
                HStack {
                    Toggle("Snap drawn box to 5% screen increments", isOn: $controller.snapFreeformTo5Percent)
                        .font(.system(size: 12))
                    Spacer()
                }
            }
            
            // Interactive Canvas
            GeometryReader { geo in
                let canvasRect = CGRect(origin: .zero, size: geo.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    
                    if !controller.isFreeformDrawMode {
                        gridCellsLayer(in: canvasRect)
                    } else {
                        freeformLayer(in: canvasRect)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleCanvasDragChanged(value: value, canvasRect: canvasRect)
                        }
                        .onEnded { value in
                            handleCanvasDragEnded(value: value, canvasRect: canvasRect)
                        }
                )
            }
            .frame(height: 225)
            
            // Multi-Window Open Windows Box Tiling Bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-Tile All Open Windows Into Boxes:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    quickLayoutButton("Grid Boxes", icon: "squareshape.split.2x2", mode: .grid)
                    quickLayoutButton("Tall (Main+Stack)", icon: "rectangle.split.2x1", mode: .tall)
                    quickLayoutButton("Wide (Top+Bottom)", icon: "rectangle.split.1x2", mode: .wide)
                    quickLayoutButton("BSP Tree", icon: "uiwindow.split.2x1", mode: .bsp)
                    quickLayoutButton("Equal Row", icon: "rectangle.split.3x1", mode: .row)
                    Button {
                        WorkspaceManager.shared.balanceColumnSizes()
                        controller.hide()
                    } label: {
                        Label("Balance All", systemImage: "equal.square")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private func gridCellsLayer(in canvasRect: CGRect) -> some View {
        let cols = max(1, controller.gridColumns)
        let rows = max(1, controller.gridRows)
        let pad: CGFloat = 6
        let cellW = (canvasRect.width - pad * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (canvasRect.height - pad * CGFloat(rows + 1)) / CGFloat(rows)
        
        ForEach(0..<rows, id: \.self) { r in
            ForEach(0..<cols, id: \.self) { c in
                let isSelected = isCellSelected(col: c, row: r)
                let x = pad + CGFloat(c) * (cellW + pad) + cellW / 2.0
                let y = pad + CGFloat(r) * (cellH + pad) + cellH / 2.0
                
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                    )
                    .frame(width: max(10, cellW), height: max(10, cellH))
                    .position(x: x, y: y)
            }
        }
    }
    
    @ViewBuilder
    private func freeformLayer(in canvasRect: CGRect) -> some View {
        if let start = controller.freeformStartNorm, let cur = controller.freeformCurrentNorm {
            let minX = min(start.x, cur.x) * canvasRect.width
            let minY = min(start.y, cur.y) * canvasRect.height
            let w = max(24, abs(cur.x - start.x) * canvasRect.width)
            let h = max(24, abs(cur.y - start.y) * canvasRect.height)
            
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                )
                .frame(width: w, height: h)
                .position(x: minX + w / 2.0, y: minY + h / 2.0)
        } else {
            Text("Click and drag here to draw any custom window box")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
    
    private func isCellSelected(col: Int, row: Int) -> Bool {
        guard let s = controller.dragStartCell, let e = controller.dragEndCell else { return false }
        let minC = min(s.col, e.col)
        let maxC = max(s.col, e.col)
        let minR = min(s.row, e.row)
        let maxR = max(s.row, e.row)
        return col >= minC && col <= maxC && row >= minR && row <= maxR
    }
    
    private func handleCanvasDragChanged(value: DragGesture.Value, canvasRect: CGRect) {
        let wsManager = WorkspaceManager.shared
        guard let ws = wsManager.workspaces[wsManager.activeDisplayId] else { return }
        let engine = BoxTilingEngine(
            windowGap: wsManager.settings.appsEdgeTogether ? 0.0 : CGFloat(wsManager.settings.windowGap),
            edgeMargins: wsManager.settings.edgeMargins
        )
        
        if !controller.isFreeformDrawMode {
            if controller.dragStartCell == nil {
                controller.dragStartCell = engine.gridCell(
                    at: value.startLocation,
                    columns: controller.gridColumns,
                    rows: controller.gridRows,
                    in: canvasRect
                )
            }
            let clampedPt = CGPoint(
                x: min(canvasRect.maxX - 1, max(canvasRect.minX + 1, value.location.x)),
                y: min(canvasRect.maxY - 1, max(canvasRect.minY + 1, value.location.y))
            )
            controller.dragEndCell = engine.gridCell(
                at: clampedPt,
                columns: controller.gridColumns,
                rows: controller.gridRows,
                in: canvasRect
            )
            if let s = controller.dragStartCell, let e = controller.dragEndCell {
                let targetFrame = engine.frameForGridSpan(
                    start: s,
                    end: e,
                    columns: controller.gridColumns,
                    rows: controller.gridRows,
                    in: ws.displayGeometry.visibleFrame
                )
                let spanCols = abs(e.col - s.col) + 1
                let spanRows = abs(e.row - s.row) + 1
                FootprintPreviewOverlayController.shared.showPreview(
                    quartzFrame: targetFrame,
                    title: "Grid Box (\(spanCols)×\(spanRows) of \(controller.gridColumns)×\(controller.gridRows))"
                )
            }
        } else {
            let startNorm = CGPoint(
                x: min(1.0, max(0.0, value.startLocation.x / max(1, canvasRect.width))),
                y: min(1.0, max(0.0, value.startLocation.y / max(1, canvasRect.height)))
            )
            let curNorm = CGPoint(
                x: min(1.0, max(0.0, value.location.x / max(1, canvasRect.width))),
                y: min(1.0, max(0.0, value.location.y / max(1, canvasRect.height)))
            )
            controller.freeformStartNorm = startNorm
            controller.freeformCurrentNorm = curNorm
            let normRect = CGRect(
                x: min(startNorm.x, curNorm.x),
                y: min(startNorm.y, curNorm.y),
                width: max(0.08, abs(curNorm.x - startNorm.x)),
                height: max(0.08, abs(curNorm.y - startNorm.y))
            )
            let targetFrame = engine.frameForNormalizedBox(
                normRect,
                in: ws.displayGeometry.visibleFrame,
                snapIncrement: controller.snapFreeformTo5Percent ? 0.05 : nil
            )
            FootprintPreviewOverlayController.shared.showPreview(
                quartzFrame: targetFrame,
                title: "Custom Freeform Box"
            )
        }
    }
    
    private func handleCanvasDragEnded(value: DragGesture.Value, canvasRect: CGRect) {
        let wsManager = WorkspaceManager.shared
        guard let ws = wsManager.workspaces[wsManager.activeDisplayId] else {
            FootprintPreviewOverlayController.shared.hide()
            return
        }
        let engine = BoxTilingEngine(
            windowGap: wsManager.settings.appsEdgeTogether ? 0.0 : CGFloat(wsManager.settings.windowGap),
            edgeMargins: wsManager.settings.edgeMargins
        )
        
        if !controller.isFreeformDrawMode {
            if let s = controller.dragStartCell, let e = controller.dragEndCell {
                let targetFrame = engine.frameForGridSpan(
                    start: s,
                    end: e,
                    columns: controller.gridColumns,
                    rows: controller.gridRows,
                    in: ws.displayGeometry.visibleFrame
                )
                wsManager.applyCustomBoxFrameToActiveWindow(targetFrame, label: "Custom Grid Box")
            }
            controller.dragStartCell = nil
            controller.dragEndCell = nil
        } else {
            if let startNorm = controller.freeformStartNorm, let curNorm = controller.freeformCurrentNorm {
                let normRect = CGRect(
                    x: min(startNorm.x, curNorm.x),
                    y: min(startNorm.y, curNorm.y),
                    width: max(0.08, abs(curNorm.x - startNorm.x)),
                    height: max(0.08, abs(curNorm.y - startNorm.y))
                )
                let targetFrame = engine.frameForNormalizedBox(
                    normRect,
                    in: ws.displayGeometry.visibleFrame,
                    snapIncrement: controller.snapFreeformTo5Percent ? 0.05 : nil
                )
                wsManager.applyCustomBoxFrameToActiveWindow(targetFrame, label: "Custom Freeform Box")
            }
            controller.freeformStartNorm = nil
            controller.freeformCurrentNorm = nil
        }
        FootprintPreviewOverlayController.shared.hide()
    }
    
    private func quickLayoutButton(_ title: String, icon: String, mode: LayoutMode) -> some View {
        Button {
            WorkspaceManager.shared.settings.layoutMode = mode
            WorkspaceManager.shared.clearCustomBoxFrames()
            WorkspaceManager.shared.applyLayout(animated: true)
            controller.hide()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}
