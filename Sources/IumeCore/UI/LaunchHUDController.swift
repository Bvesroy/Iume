import AppKit
import SwiftUI

/// Floating Quick Control & Kickstart panel for Iume.
/// Provides a prominent launch button to instantly arrange all open windows into a continuous slide strip.
@MainActor
public final class LaunchHUDController: ObservableObject {
    public static let shared = LaunchHUDController()
    
    private var window: NSWindow?
    private var notificationTimer: Timer?
    @Published public var notificationMessage: String?
    @Published public var lastArrangedCount: Int = 0
    @Published public var isArranging: Bool = false
    
    public init() {}
    
    public func show() {
        if window == nil {
            setupWindow()
        }
        
        guard let win = window else { return }
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func hide() {
        window?.orderOut(nil)
    }
    
    public func toggle() {
        if let win = window, win.isVisible {
            hide()
        } else {
            show()
        }
    }
    
    public func showTemporaryNotification(message: String) {
        notificationMessage = message
        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.notificationMessage = nil
            }
        }
    }
    
    private func setupWindow() {
        let view = LaunchHUDView(controller: self)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Iume — Slide Mode"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.contentView = hostingView
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        
        self.window = win
    }
    
    public func performKickstart() {
        isArranging = true
        let count = WorkspaceManager.shared.kickstart()
        lastArrangedCount = count
        
        showTemporaryNotification(message: "✅ Arranged \(count) windows into continuous slide strip!")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isArranging = false
        }
    }
}

/// SwiftUI View for the Kickstart & Slide Mode Launch Panel.
public struct LaunchHUDView: View {
    @ObservedObject var controller: LaunchHUDController
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var workspaceManager = WorkspaceManager.shared
    
    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [Color.blue, Color.purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: "rectangle.split.3x1.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Iume Slide Mode")
                        .font(.system(size: 18, weight: .bold))
                    Text("Native macOS Continuous Scrolling Window Manager")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { controller.hide() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 16)
            
            // Primary Kickstart Action Button
            Button(action: {
                controller.performKickstart()
            }) {
                HStack(spacing: 14) {
                    Image(systemName: controller.isArranging ? "gearshape.arrow.triangle.2.circlepath" : "bolt.fill")
                        .font(.system(size: 24, weight: .bold))
                        .rotationEffect(.degrees(controller.isArranging ? 360 : 0))
                        .animation(controller.isArranging ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: controller.isArranging)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.isArranging ? "Arranging Windows..." : "Kickstart & Arrange Windows")
                            .font(.system(size: 15, weight: .bold))
                        Text("Tiles open windows into side-by-side half-screen columns")
                            .font(.system(size: 11))
                            .opacity(0.85)
                    }
                    
                    Spacer()
                    
                    Text("⌥⇧Space")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(6)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(
                    colors: [Color.blue, Color.indigo],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .foregroundColor(.white)
                .cornerRadius(12)
                .shadow(color: Color.blue.opacity(0.3), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            
            // Notification Banner
            if let note = controller.notificationMessage {
                HStack {
                    Text(note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // Quick Column Width Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("Column Width Presets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    presetButton("50% Symmetrical", ratio: 0.50)
                    presetButton("60% Focus", ratio: 0.60)
                    presetButton("75% Wide", ratio: 0.75)
                    presetButton("100% Full", ratio: 1.0)
                }
            }
            .padding(.horizontal)
            
            // Managed Windows Overview
            VStack(alignment: .leading, spacing: 6) {
                let windows = workspaceManager.registry.allWindows()
                HStack {
                    Text("Open Windows (\(windows.count))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Continuous Horizontal Strip")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if windows.isEmpty {
                            Text("No open application windows detected.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(windows) { win in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(win.isFocused ? Color.blue : Color.gray.opacity(0.5))
                                        .frame(width: 8, height: 8)
                                    
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(win.appName)
                                            .font(.system(size: 11, weight: .bold))
                                        Text(win.title)
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 110, alignment: .leading)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            Divider()
                .padding(.horizontal)
            
            // Footer & Trackpad Guide
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Swipe 2 fingers horizontally to slide")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Settings...") {
                    StatusBarController.openSettingsWindow()
                }
                .font(.system(size: 11))
                
                Button("Close") {
                    controller.hide()
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(width: 500)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
    
    private func presetButton(_ title: String, ratio: Double) -> some View {
        let isSelected = abs(settings.defaultColumnWidthRatio - ratio) < 0.02
        return Button(action: {
            settings.defaultColumnWidthRatio = ratio
            _ = workspaceManager.kickstart()
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.blue.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .blue : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
                )
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Visual effect wrapper for macOS translucent vibrancy.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
