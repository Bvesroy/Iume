import SwiftUI

/// Native macOS SwiftUI Settings Window for Iume.
public struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var permissions = PermissionManager.shared
    @ObservedObject var workspaceManager = WorkspaceManager.shared
    
    public init() {}
    
    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            
            navigationTab
                .tabItem {
                    Label("Navigation", systemImage: "keyboard")
                }
            
            windowsTab
                .tabItem {
                    Label("Windows", systemImage: "macwindow.on.rectangle")
                }
            
            displaysTab
                .tabItem {
                    Label("Displays", systemImage: "display.2")
                }
            
            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 580, height: 460)
        .padding()
    }
    
    // MARK: - General Tab
    
    private var generalTab: some View {
        Form {
            Section(header: Text("Management Status")) {
                Toggle("Enable Iume Window Management", isOn: $settings.isEnabled)
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }
            
            Section(header: Text("Layout Strategy")) {
                Picker("Layout Mode", selection: $settings.layoutMode) {
                    ForEach(LayoutMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                
                Text(settings.layoutMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Picker("New Window Insertion", selection: $settings.insertionPolicy) {
                    ForEach(InsertionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Section(header: Text("Spacing & Appearance")) {
                HStack {
                    Text("Window Gap:")
                    Slider(value: $settings.windowGap, in: 0...40, step: 2)
                    Text("\(Int(settings.windowGap)) pt")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }
        }
        .padding()
    }
    
    // MARK: - Navigation Tab
    
    private var navigationTab: some View {
        Form {
            Section(header: Text("Viewport & Scrolling")) {
                Toggle("Snap Viewport to Column Boundaries", isOn: $settings.snapToColumn)
                Toggle("Natural Trackpad Scrolling", isOn: $settings.trackpadNaturalScroll)
                
                HStack {
                    Text("Animation Speed:")
                    Slider(value: $settings.animationDuration, in: 0.05...0.6, step: 0.02)
                    Text(String(format: "%.2fs", settings.animationDuration))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
            
            Section(header: Text("Default Keyboard Shortcuts")) {
                VStack(alignment: .leading, spacing: 6) {
                    shortcutRow("Focus Previous Window", "⌥ + H")
                    shortcutRow("Focus Next Window", "⌥ + L")
                    shortcutRow("Focus Window Up (if stacked)", "⌥ + K")
                    shortcutRow("Focus Window Down (if stacked)", "⌥ + J")
                    shortcutRow("Move Column Left", "⌥ + ⇧ + H")
                    shortcutRow("Move Column Right", "⌥ + ⇧ + L")
                    shortcutRow("Toggle Window Zoom", "⌥ + Return")
                    shortcutRow("Close Active Window", "⌥ + W")
                    shortcutRow("Cycle Through Windows", "⌥ + Tab")
                    shortcutRow("Scroll Viewport Left / Right", "⌥ + ← / →")
                }
            }
        }
        .padding()
    }
    
    private func shortcutRow(_ label: String, _ shortcut: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
        }
    }
    
    // MARK: - Windows Tab
    
    private var windowsTab: some View {
        Form {
            Section(header: Text("Column Sizing")) {
                HStack {
                    Text("Default Column Width Ratio:")
                    Slider(value: $settings.defaultColumnWidthRatio, in: 0.3...0.9, step: 0.05)
                    Text(String(format: "%.0f%%", settings.defaultColumnWidthRatio * 100))
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }
            
            Section(header: Text("Excluded Applications (Float by Default)")) {
                List {
                    ForEach(settings.excludedBundleIdentifiers, id: \.self) { bundleId in
                        Text(bundleId)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .onDelete { indexSet in
                        settings.excludedBundleIdentifiers.remove(atOffsets: indexSet)
                    }
                }
                .frame(height: 140)
            }
        }
        .padding()
    }
    
    // MARK: - Displays Tab
    
    private var displaysTab: some View {
        Form {
            Section(header: Text("Connected Displays")) {
                List(workspaceManager.displayManager.activeDisplays, id: \.id) { display in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(display.name)
                                .fontWeight(.semibold)
                            if display.isPrimary {
                                Text("Primary")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                        }
                        Text("Visible Resolution: \(Int(display.visibleFrame.width)) × \(Int(display.visibleFrame.height)) pt")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 180)
            }
        }
        .padding()
    }
    
    // MARK: - Advanced Tab
    
    private var advancedTab: some View {
        Form {
            Section(header: Text("System Permissions")) {
                HStack {
                    Image(systemName: permissions.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(permissions.hasAccessibilityPermission ? .green : .orange)
                    Text(permissions.hasAccessibilityPermission ? "Accessibility Permission Granted" : "Accessibility Permission Missing")
                    Spacer()
                    if !permissions.hasAccessibilityPermission {
                        Button("Open System Settings") {
                            permissions.openAccessibilityPreferences()
                        }
                    }
                }
            }
            
            Section(header: Text("Diagnostics & State")) {
                HStack {
                    Text("Managed Windows: \(workspaceManager.registry.allWindows().count)")
                    Spacer()
                    Button("Export Report") {
                        let report = workspaceManager.diagnostics.exportDiagnosticReport()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                }
                
                Button("Reset Preferences to Defaults", role: .destructive) {
                    settings.resetToDefaults()
                }
            }
        }
        .padding()
    }
}
