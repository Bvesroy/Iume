import AppKit
import SwiftUI

/// Translucent on-screen HUD pill displaying the active layout mode, box action, or resize feedback
/// (modeled after Loop & Rectangle visual HUD indicators).
@MainActor
public final class BoxPreviewHUDController: ObservableObject {
    public static let shared = BoxPreviewHUDController()
    
    private var window: NSPanel?
    private var hideTimer: Timer?
    @Published public var title: String = ""
    @Published public var subtitle: String = ""
    @Published public var systemImageName: String = "squareshape.split.2x2"
    
    public init() {}
    
    public func flash(
        title: String,
        subtitle: String = "",
        systemImageName: String = "squareshape.split.2x2",
        screen: NSScreen? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        
        if window == nil {
            setupWindow()
        }
        
        guard let panel = window else { return }
        
        // Center panel on screen
        let visible = screen.visibleFrame
        let panelW: CGFloat = 220
        let panelH: CGFloat = 110
        let panelX = visible.midX - (panelW / 2.0)
        let panelY = visible.midY - (panelH / 2.0)
        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelW, height: panelH), display: true)
        
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.10, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let panel = self.window else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    panel.animator().alphaValue = 0.0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        panel.orderOut(nil)
                    }
                })
            }
        }
    }
    
    private func setupWindow() {
        let view = BoxPreviewHUDView(controller: self)
        let hostingView = NSHostingView(rootView: view)
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = hostingView
        
        self.window = panel
    }
}

public struct BoxPreviewHUDView: View {
    @ObservedObject var controller: BoxPreviewHUDController
    
    public init(controller: BoxPreviewHUDController) {
        self.controller = controller
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: controller.systemImageName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.white)
                .symbolRenderingMode(.hierarchical)
            
            Text(controller.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            if !controller.subtitle.isEmpty {
                Text(controller.subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 8)
    }
}
