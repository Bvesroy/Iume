import AppKit
import SwiftUI

/// Model passed to the Minimap HUD view to render the strip state.
public struct MinimapState: Equatable, Sendable {
    public var columns: [CGFloat] // column widths
    public var totalStripWidth: CGFloat
    public var viewportOffset: CGFloat
    public var visibleWidth: CGFloat
    public var focusedIndex: Int
    public var activeTitle: String
    
    public init(
        columns: [CGFloat] = [],
        totalStripWidth: CGFloat = 0,
        viewportOffset: CGFloat = 0,
        visibleWidth: CGFloat = 0,
        focusedIndex: Int = 0,
        activeTitle: String = ""
    ) {
        self.columns = columns
        self.totalStripWidth = totalStripWidth
        self.viewportOffset = viewportOffset
        self.visibleWidth = visibleWidth
        self.focusedIndex = focusedIndex
        self.activeTitle = activeTitle
    }
}

/// Floating, translucent HUD overlay showing the endless strip minimap and viewport tracker,
/// directly inspired by ChainYourMac and TileMyMac.
@MainActor
public final class MinimapHUDController: ObservableObject {
    public static let shared = MinimapHUDController()
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MinimapHUDView>?
    private var hideTimer: Timer?
    @Published public private(set) var state = MinimapState()
    
    public init() {
        setupPanel()
    }
    
    private func setupPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.alphaValue = 0.0
        
        let view = MinimapHUDView(controller: self)
        let host = NSHostingView(rootView: view)
        p.contentView = host
        
        self.panel = p
        self.hostingView = host
    }
    
    public func update(
        columns: [WindowColumn],
        totalStripWidth: CGFloat,
        viewportOffset: CGFloat,
        visibleWidth: CGFloat,
        focusedIndex: Int?,
        activeTitle: String,
        screen: NSScreen?
    ) {
        guard SettingsStore.shared.showMinimapHUD else {
            panel?.alphaValue = 0.0
            panel?.orderOut(nil)
            return
        }
        
        let colWidths = columns.map { $0.width }
        self.state = MinimapState(
            columns: colWidths,
            totalStripWidth: max(1, totalStripWidth),
            viewportOffset: viewportOffset,
            visibleWidth: max(1, visibleWidth),
            focusedIndex: focusedIndex ?? 0,
            activeTitle: activeTitle
        )
        
        if let targetScreen = screen ?? NSScreen.main {
            positionPanel(on: targetScreen)
        }
        
        showWithAutohide()
    }
    
    public func showWithAutohide() {
        guard let p = panel else { return }
        
        hideTimer?.invalidate()
        
        if p.alphaValue < 0.95 {
            p.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1.0
            }
        }
        
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fadeOut()
            }
        }
    }
    
    public func fadeOut() {
        guard let p = panel, p.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 0.0
        }, completionHandler: {
            DispatchQueue.main.async {
                p.orderOut(nil)
            }
        })
    }
    
    private func positionPanel(on screen: NSScreen) {
        guard let p = panel else { return }
        let screenFrame = screen.visibleFrame
        let panelW: CGFloat = 340
        let panelH: CGFloat = 64
        let x = screenFrame.origin.x + (screenFrame.width - panelW) / 2.0
        let y = screenFrame.origin.y + 24.0 // Floats comfortably above dock
        p.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true)
    }
}

/// SwiftUI View rendering the glassmorphic mini strip and viewport box.
public struct MinimapHUDView: View {
    @ObservedObject var controller: MinimapHUDController
    
    public var body: some View {
        let st = controller.state
        let totalW = max(1.0, st.totalStripWidth)
        let count = max(1, st.columns.count)
        
        VStack(spacing: 5) {
            // Header Info Line
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: 6, height: 6)
                
                Text(st.activeTitle.isEmpty ? "Strip" : st.activeTitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                Text("\(min(count, st.focusedIndex + 1)) of \(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.70))
            }
            .padding(.horizontal, 2)
            
            // Mini Columns Track & Gliding Viewport Frame
            GeometryReader { geo in
                let trackWidth = geo.size.width
                let trackHeight = geo.size.height
                
                ZStack(alignment: .leading) {
                    // Track Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.10))
                    
                    // Column Pills
                    HStack(spacing: 3) {
                        ForEach(0..<st.columns.count, id: \.self) { idx in
                            let colW = st.columns[idx]
                            let fraction = colW / totalW
                            let isFocused = (idx == st.focusedIndex)
                            
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isFocused ? Color(nsColor: .controlAccentColor) : Color.white.opacity(0.28))
                                .frame(width: max(6, fraction * (trackWidth - CGFloat(count * 3))))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(isFocused ? Color.white.opacity(0.7) : Color.clear, lineWidth: 1)
                                )
                        }
                    }
                    
                    // Viewport Indicator Box
                    let vpRatio = min(1.0, st.visibleWidth / totalW)
                    let vpWidth = max(28.0, vpRatio * trackWidth)
                    let offsetRatio = min(max(0, st.viewportOffset / totalW), 1.0 - (vpWidth / trackWidth))
                    let vpX = offsetRatio * trackWidth
                    
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.12))
                        )
                        .frame(width: vpWidth, height: trackHeight)
                        .offset(x: max(0, vpX))
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

/// Helper NSVisualEffectView wrapper for SwiftUI
public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    
    public init(material: NSVisualEffectView.Material = .hudWindow, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
