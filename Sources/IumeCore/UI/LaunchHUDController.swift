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
    @Published public var notificationColor: Color = .green
    @Published public var lastArrangedCount: Int = 0
    @Published public var isArranging: Bool = false
    @Published public var isStopping: Bool = false
    
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
    
    public func showTemporaryNotification(message: String, color: Color = .green) {
        notificationMessage = message
        notificationColor = color
        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.notificationMessage = nil
            }
        }
    }
    
    private func setupWindow() {
        let view = LaunchHUDView(controller: self)
        let hostingView = NSHostingView(rootView: view)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        win.minSize = NSSize(width: 480, height: 480)
        win.maxSize = NSSize(width: 600, height: 950)
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        
        self.window = win
    }
    
    public func performKickstart() {
        guard PermissionManager.shared.checkPermission() else {
            showTemporaryNotification(message: "⚠️ Accessibility required. Enable Iume in System Settings.", color: .orange)
            PermissionManager.shared.promptForAccessibility()
            return
        }
        
        // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:HUDKickstartPhysicsActivation]
        // Description: LaunchHUD kickstart trigger guaranteeing all 5 scrolling physics dimensions are engaged.
        // Ensure all 5 requested scrolling features are actively engaged
        let settings = SettingsStore.shared
        settings.freezeOnRelease = false
        settings.inertialScrolling = true
        settings.momentumScrolling = true
        settings.smoothScrollingEnabled = true
        // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:HUDKickstartPhysicsActivation]
        
        isArranging = true
        let count = WorkspaceManager.shared.kickstart()
        lastArrangedCount = count
        StatusBarController.current?.rebuildMenu()
        
        let profile = settings.kineticScrollingProfile.displayName
        showTemporaryNotification(message: "✅ Kickstarted \(count) windows! Inertial, Momentum & Smooth Scrolling active (\(profile)).", color: .green)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isArranging = false
        }
    }
    
    public func performStop() {
        isStopping = true
        let count = WorkspaceManager.shared.registry.allWindows().count
        WorkspaceManager.shared.stop()
        StatusBarController.current?.rebuildMenu()
        
        let countText = count > 0 ? "Restored \(count) windows and apps back to normal!" : "Windows and apps restored to normal!"
        showTemporaryNotification(message: "⏹️ Stopped: \(countText)", color: Color(red: 0.95, green: 0.45, blue: 0.25))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isStopping = false
        }
    }
}

/// SwiftUI View for the Kickstart & Slide Mode Launch Panel.
public struct LaunchHUDView: View {
    @ObservedObject var controller: LaunchHUDController
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var workspaceManager = WorkspaceManager.shared
    @ObservedObject var permissions = PermissionManager.shared
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
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
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Iume Slide Mode")
                            .font(.system(size: 18, weight: .bold))
                        
                        if settings.isEnabled {
                            HStack(spacing: 4) {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(4)
                        } else {
                            HStack(spacing: 4) {
                                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                                Text("STOPPED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                        }
                    }
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
            
            // Accessibility Permission Status Banner
            if !permissions.hasAccessibilityPermission {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 15))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility Permission Needed")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.primary)
                        Text("Enable Iume once in System Settings to arrange windows.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Open Settings") {
                        permissions.openAccessibilityPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal)
            }
            
            // Action Buttons (Kickstart & Stop/Restore)
            VStack(spacing: 10) {
                // Primary Kickstart Action Button
                Button(action: {
                    controller.performKickstart()
                }) {
                    HStack(spacing: 14) {
                        Image(systemName: controller.isArranging ? "gearshape.arrow.triangle.2.circlepath" : "bolt.fill")
                            .font(.system(size: 22, weight: .bold))
                            .rotationEffect(.degrees(controller.isArranging ? 360 : 0))
                            .animation(controller.isArranging ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: controller.isArranging)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.isArranging ? "Arranging Windows..." : "Kickstart & Arrange Windows")
                                .font(.system(size: 14, weight: .bold))
                            Text("Tiles open windows into side-by-side slide strip")
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
                    .padding(.vertical, 10)
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
                
                // Stop & Restore Action Button
                Button(action: {
                    controller.performStop()
                }) {
                    HStack(spacing: 14) {
                        Image(systemName: controller.isStopping ? "arrow.triangle.2.circlepath" : "stop.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .rotationEffect(.degrees(controller.isStopping ? 360 : 0))
                            .animation(controller.isStopping ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: controller.isStopping)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.isStopping ? "Restoring Windows..." : "Stop & Restore Windows")
                                .font(.system(size: 14, weight: .bold))
                            Text("Restores all windows and apps back to the way they were")
                                .font(.system(size: 11))
                                .opacity(0.85)
                        }
                        
                        Spacer()
                        
                        Text("⌥⇧S")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(6)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(LinearGradient(
                        colors: [Color(red: 0.85, green: 0.22, blue: 0.28), Color(red: 0.68, green: 0.15, blue: 0.35)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .shadow(color: Color.red.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            
            // Notification Banner
            if let note = controller.notificationMessage {
                HStack {
                    Text(note)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(controller.notificationColor)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(controller.notificationColor.opacity(0.12))
                .cornerRadius(8)
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            // [LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:HUDScrollingDynamicsCard]
            // Description: LaunchHUD control card for Inertial, Momentum, Friction, Kinetic Profiles, and Smooth Scrolling.
            // Kinetic & Inertial Scrolling Dynamics (Inertial, Momentum, Friction, Kinetic, Smooth)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "hand.point.up.left.and.text")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.blue)
                    Text("Scrolling Dynamics & Physics")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    if settings.inertialScrolling && !settings.freezeOnRelease {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("INERTIA ON")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(4)
                    }
                }
                
                // 1. Inertial Scrolling & 5. Smooth Scrolling Toggles
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { settings.inertialScrolling && !settings.freezeOnRelease },
                        set: { enabled in
                            settings.inertialScrolling = enabled
                            if enabled {
                                settings.freezeOnRelease = false
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Inertial Scrolling")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Continues after fingers lift")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    
                    Spacer()
                    
                    Toggle(isOn: $settings.smoothScrollingEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Smooth Scrolling")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Interpolated gradual movement")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                
                Divider()
                
                // 2. Momentum Scrolling & Gesture Velocity Multiplier
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(isOn: $settings.momentumScrolling) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Momentum Scrolling")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Driven by release velocity")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!settings.inertialScrolling || settings.freezeOnRelease)
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Text("Multiplier:")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(String(format: "%.1f×", settings.momentumMultiplier))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                            Slider(value: $settings.momentumMultiplier, in: 0.5...2.5, step: 0.1)
                                .frame(width: 75)
                        }
                        .disabled(!settings.inertialScrolling || !settings.momentumScrolling || settings.freezeOnRelease)
                    }
                }
                
                Divider()
                
                // 3. Deceleration / Friction
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Deceleration / Friction")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(String(format: "Factor: %.3f", settings.scrollDeceleration))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.purple)
                    }
                    
                    Slider(value: $settings.scrollDeceleration, in: 0.88...0.995, step: 0.005)
                    
                    HStack(spacing: 6) {
                        frictionPresetButton("Snappy (0.910)", rate: 0.910, desc: "Quick Stop")
                        frictionPresetButton("Natural (0.965)", rate: 0.965, desc: "Standard Glide")
                        frictionPresetButton("Slick (0.985)", rate: 0.985, desc: "Long Coast")
                    }
                }
                
                Divider()
                
                // 4. Kinetic Scrolling Profile
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Kinetic Scrolling Profile")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(settings.kineticScrollingProfile.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    
                    Picker("", selection: $settings.kineticScrollingProfile) {
                        ForEach(KineticScrollingProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Text(settings.kineticScrollingProfile.description)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal)
            // [END LOCKED SECTION: PERFECT_SCROLLING_PHYSICS_ENGINE:HUDScrollingDynamicsCard]
            
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
            
            // Window Edges & Gap Controls
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Window Edges & Spacing")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("Edges Together", isOn: $settings.appsEdgeTogether)
                        .toggleStyle(.switch)
                        .scaleEffect(0.8)
                }
                
                HStack(spacing: 8) {
                    gapButton("Together (0 pt)", gap: 0.0)
                    gapButton("Compact (4 pt)", gap: 4.0)
                    gapButton("Standard (8 pt)", gap: 8.0)
                    gapButton("Spacious (16 pt)", gap: 16.0)
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
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .frame(minHeight: 520, maxHeight: 720)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
    
    private func frictionPresetButton(_ title: String, rate: Double, desc: String) -> some View {
        let isSelected = abs(settings.scrollDeceleration - rate) < 0.006
        return Button(action: {
            settings.scrollDeceleration = rate
        }) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
                Text(desc)
                    .font(.system(size: 8))
                    .foregroundColor(isSelected ? .purple : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.purple.opacity(0.2) : Color(NSColor.controlBackgroundColor))
            .foregroundColor(isSelected ? .purple : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.purple : Color.clear, lineWidth: 1)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
    
    private func gapButton(_ title: String, gap: Double) -> some View {
        let isSelected = abs(settings.windowGap - gap) < 0.5
        return Button(action: {
            settings.windowGap = gap
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.indigo.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isSelected ? .indigo : .primary)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 1)
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
