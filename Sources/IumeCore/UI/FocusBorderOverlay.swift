import AppKit
import SwiftUI

/// Floating border overlay highlighting the currently focused window on the strip,
/// directly inspired by ChainYourMac's focus border feature.
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
    
    public func updateFrame(_ frame: CGRect?, visibleFrame: CGRect) {
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
        p.setFrame(insetFrame, display: true)
        if !p.isVisible {
            p.orderFront(nil)
        }
    }
    
    public func hide() {
        panel?.orderOut(nil)
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
