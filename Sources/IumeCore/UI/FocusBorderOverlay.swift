import AppKit
import SwiftUI

/// Floating border overlay highlighting the currently focused window on the strip.
@MainActor
public final class FocusBorderOverlay {
    public static let shared = FocusBorderOverlay()
    
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
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = false
        
        let view = FocusBorderView()
        let host = NSHostingView(rootView: view)
        p.contentView = host
        
        self.panel = p
    }
    
    public func updateFrame(_ frame: CGRect?, visibleFrame: CGRect, animated: Bool = true) {
        guard let p = panel else { return }
        
        guard SettingsStore.shared.showFocusBorder, let f = frame else {
            p.orderOut(nil)
            return
        }
        
        // Check if window is at least partially visible on screen
        let intersection = f.intersection(visibleFrame)
        guard !intersection.isNull && intersection.width > 20 else {
            p.orderOut(nil)
            return
        }
        
        let insetFrame = f.insetBy(dx: -2.0, dy: -2.0)
        let isMoving = abs(p.frame.origin.x - insetFrame.origin.x) + abs(p.frame.origin.y - insetFrame.origin.y)
        let shouldAnimate = animated && SettingsStore.shared.enableTransitions && p.isVisible && p.frame != .zero && isMoving > 2.0 && isMoving < 1500
        
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = min(0.22, SettingsStore.shared.animationDuration)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(insetFrame, display: true)
            }
        } else {
            p.setFrame(insetFrame, display: true)
        }
        
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                p.animator().alphaValue = 1.0
            }
        }
    }
    
    public func show(around frame: CGRect) {
        if let screen = NSScreen.main {
            updateFrame(frame, visibleFrame: screen.visibleFrame, animated: true)
        }
    }
    
    public func hide() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        }
    }
}

/// Border view with rounded accent-color stroke
public struct FocusBorderView: View {
    public var body: some View {
        RoundedRectangle(cornerRadius: 11)
            .stroke(Color(nsColor: .controlAccentColor), lineWidth: 3.0)
            .padding(1.5)
            .shadow(color: Color(nsColor: .controlAccentColor).opacity(0.4), radius: 4, x: 0, y: 0)
    }
}
