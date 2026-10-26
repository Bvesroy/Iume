import SwiftUI

/// State-of-the-art macOS SwiftUI Settings Window for Iume.
public struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var permissions = PermissionManager.shared
    
    public init() {}
    
    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape.fill") }
            
            layoutTab
                .tabItem { Label("Layout & Strip", systemImage: "rectangle.split.2x1.fill") }
            
            scrollingTab
                .tabItem { Label("Smoothness & Physics", systemImage: "hand.draw.fill") }
            
            visualsTab
                .tabItem { Label("Visuals & HUD", systemImage: "sparkles") }
            
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard.fill") }
            
            rulesTab
                .tabItem { Label("Rules", systemImage: "shield.slash.fill") }
            
            MacSetupView()
                .tabItem { Label("Mac Setup", systemImage: "checkmark.seal.fill") }
            
            diagnosticsTab
                .tabItem { Label("Diagnostics", systemImage: "wrench.and.screwdriver.fill") }
        }
        .frame(width: 680, height: 570)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - 1. General Tab
    
    private var generalTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Status Hero Card
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(settings.isEnabled ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                            .frame(width: 48, height: 48)
                        
                        Image(systemName: settings.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(settings.isEnabled ? .green : .orange)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settings.isEnabled ? "Iume Window Manager is Active" : "Iume Window Manager is Paused")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text(settings.isEnabled ? "Continuous horizontal sliding strip enabled." : "Windows are unmanaged.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { settings.isEnabled },
                        set: { newVal in
                            if newVal {
                                LaunchHUDController.shared.performKickstart()
                            } else {
                                LaunchHUDController.shared.performStop()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Primary Action Center
                VStack(alignment: .leading, spacing: 12) {
                    Text("Instant Control")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            LaunchHUDController.shared.performKickstart()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Kickstart & Re-arrange Strip")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentColor)
                        
                        Button(action: {
                            LaunchHUDController.shared.performStop()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 14))
                                Text("Stop & Restore Windows")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Button(action: {
                        LaunchHUDController.shared.show()
                    }) {
                        HStack {
                            Image(systemName: "macwindow.on.rectangle")
                            Text("Open Slide Launch Control Overlay")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // System Options
                VStack(alignment: .leading, spacing: 12) {
                    Text("System Integration")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    Toggle(isOn: $settings.launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                                .font(.body)
                            Text("Automatically start Iume when you log into your Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    HStack {
                        Image(systemName: permissions.hasAccessibilityPermission ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(permissions.hasAccessibilityPermission ? .green : .orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permissions.hasAccessibilityPermission ? "Accessibility Permission: Granted" : "Accessibility Permission: Missing")
                                .font(.body)
                            Text("Required for macOS window positioning and gesture interception.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if !permissions.hasAccessibilityPermission {
                            Button("Grant Access") {
                                permissions.openAccessibilityPreferences()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - 2. Layout & Strip Tab
    
    private var layoutTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Live Interactive Strip Preview Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Live Layout Preview")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text("Gap: \(Int(settings.windowGap))pt  •  Margins: \(Int(settings.edgeMargins.top))pt  •  Ratio: \(Int(settings.defaultColumnWidthRatio * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    
                    LiveStripPreviewView(
                        windowGap: settings.windowGap,
                        edgeMargins: settings.edgeMargins,
                        columnRatio: settings.defaultColumnWidthRatio,
                        centerMode: settings.centerMode
                    )
                    .frame(height: 85)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(14)
                .background(settingsCardBackground)
                
                // Gap and Margins Card (Apps Edge Together & Spacing)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Window Edges & Spacing")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if settings.appsEdgeTogether {
                            Text("EDGES LOCKED TOGETHER")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                    }
                    
                    // Apps Edge Together Toggle
                    Toggle(isOn: $settings.appsEdgeTogether) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.split.2x1.fill")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apps Edge Together (Zero Gap)")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text("Locks adjacent window borders seamlessly together with 0 pt space between strips.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Toggle(isOn: $settings.edgeSnapping) {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Magnetic Window Snapping & Adhesion")
                                    .font(.body)
                                Text("Adjacent windows remain together like magnets. Windows automatically snap together when brought closer with zero flicker.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                    
                    // Inner Window Gap
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Inner Window Gap:")
                                .font(.body)
                            Spacer()
                            Text("\(Int(settings.windowGap)) pt")
                                .font(.body)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        
                        Slider(value: $settings.windowGap, in: 0...32, step: 2)
                        
                        HStack(spacing: 6) {
                            presetPill("Together (0 pt)", isSelected: settings.windowGap == 0) {
                                settings.appsEdgeTogether = true
                            }
                            presetPill("Compact (4 pt)", isSelected: settings.windowGap == 4) {
                                settings.windowGap = 4
                            }
                            presetPill("Standard (8 pt)", isSelected: settings.windowGap == 8) {
                                settings.windowGap = 8
                            }
                            presetPill("Comfortable (12 pt)", isSelected: settings.windowGap == 12) {
                                settings.windowGap = 12
                            }
                            presetPill("Spacious (16 pt)", isSelected: settings.windowGap == 16) {
                                settings.windowGap = 16
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Outer Screen Margins
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Screen Outer Margins:")
                                .font(.body)
                            Spacer()
                            Text("\(Int(settings.edgeMargins.top)) pt")
                                .font(.body)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        
                        Slider(value: Binding(
                            get: { settings.edgeMargins.top },
                            set: { newVal in
                                settings.edgeMargins = EdgeMargins(top: newVal, bottom: newVal, left: newVal, right: newVal)
                            }
                        ), in: 0...32, step: 2)
                        
                        HStack(spacing: 6) {
                            presetPill("Flush Screen (0 pt)", isSelected: settings.edgeMargins.top == 0) {
                                settings.edgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0)
                            }
                            presetPill("Compact (4 pt)", isSelected: settings.edgeMargins.top == 4) {
                                settings.edgeMargins = EdgeMargins(top: 4, bottom: 4, left: 4, right: 4)
                            }
                            presetPill("Standard (8 pt)", isSelected: settings.edgeMargins.top == 8) {
                                settings.edgeMargins = EdgeMargins(top: 8, bottom: 8, left: 8, right: 8)
                            }
                            presetPill("Comfortable (16 pt)", isSelected: settings.edgeMargins.top == 16) {
                                settings.edgeMargins = EdgeMargins(top: 16, bottom: 16, left: 16, right: 16)
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        Toggle("Smart Margins (Zero margins when single window is open)", isOn: $settings.smartWindowMargins)
                        Toggle("Disable Margins on Built-in Laptop Display", isOn: $settings.disablePaddingOnBuiltinDisplay)
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Column Width Sizing Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Column Geometry")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Default Column Width Ratio:")
                            Spacer()
                            Text(String(format: "%.0f%% of Screen", settings.defaultColumnWidthRatio * 100))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        
                        Slider(value: $settings.defaultColumnWidthRatio, in: 0.25...0.90, step: 0.05)
                        
                        HStack(spacing: 6) {
                            presetPill("33% (1/3)", isSelected: abs(settings.defaultColumnWidthRatio - 0.333) < 0.03) {
                                settings.defaultColumnWidthRatio = 0.333
                            }
                            presetPill("50% (1/2)", isSelected: abs(settings.defaultColumnWidthRatio - 0.50) < 0.03) {
                                settings.defaultColumnWidthRatio = 0.50
                            }
                            presetPill("66% (2/3)", isSelected: abs(settings.defaultColumnWidthRatio - 0.667) < 0.03) {
                                settings.defaultColumnWidthRatio = 0.667
                            }
                            presetPill("75% (3/4)", isSelected: abs(settings.defaultColumnWidthRatio - 0.75) < 0.03) {
                                settings.defaultColumnWidthRatio = 0.75
                            }
                        }
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Alignment & Center Mode Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Strip Alignment & Centering Mode")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    Picker("Center Mode", selection: $settings.centerMode) {
                        Text("Flush Edge-to-Edge (Never Center) - Recommended").tag(CenterMode.never)
                        Text("Center on Overflow (When Strip > Screen)").tag(CenterMode.onOverflow)
                        Text("Always Center Active Window").tag(CenterMode.always)
                    }
                    .pickerStyle(.radioGroup)
                    
                    Text(centerModeExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Divider()
                    
                    Picker("New Window Placement", selection: $settings.insertionPolicy) {
                        ForEach(InsertionPolicy.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Multi-Monitor Per-Display Management Card (ChainYourMac Parity)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Displays (One Strip Per Display)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button("Send Active Window to Next Display (⌃⌥N)") {
                            WorkspaceManager.shared.sendFocusedColumnToNextDisplay(follow: true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Text("Switch Iume off for any display (such as a presentation screen or portrait monitor) to leave windows there untouched.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(WorkspaceManager.shared.displayManager.activeDisplays, id: \.id) { display in
                        let isManaged = !settings.disabledDisplayIds.contains(display.id)
                        Toggle(isOn: Binding(
                            get: { isManaged },
                            set: { enabled in
                                if enabled {
                                    settings.disabledDisplayIds.removeAll { $0 == display.id }
                                } else if !settings.disabledDisplayIds.contains(display.id) {
                                    settings.disabledDisplayIds.append(display.id)
                                }
                                WorkspaceManager.shared.applyLayout(animated: true)
                            }
                        )) {
                            HStack(spacing: 8) {
                                Image(systemName: "display")
                                    .foregroundColor(isManaged ? .accentColor : .secondary)
                                Text("\(display.name) (\(Int(display.frame.width))×\(Int(display.frame.height)))")
                                    .font(.body)
                                if display.isPrimary {
                                    Text("Primary")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Browser-Style Window Tab Grouping Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browser-Style Window Tab Grouping")
                                .font(.headline)
                            Text("Combine multiple windows of the same app into a single window with a Chrome-style tab bar.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    Toggle(isOn: $settings.autoTabSameAppWindows) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Tab Same Application Windows")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Automatically group newly opened windows of the same application together into tabs.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Smart Grouping Policy")
                            .font(.body)
                            .fontWeight(.medium)
                        Picker("", selection: $settings.smartGroupingPolicy) {
                            Text("Same App").tag(SmartGroupingPolicy.sameApp)
                            Text("Manual Only").tag(SmartGroupingPolicy.manualOnly)
                            Text("Ask on Window").tag(SmartGroupingPolicy.askOnNewWindow)
                        }
                        .pickerStyle(.segmented)
                        Text("Defines how new windows are organized when launched.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Toggle(isOn: $settings.tabBarCompactMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Compact Tab Bar Mode")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Minimizes tab padding and height for high-density, low-profile tab bars.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Toggle(isOn: $settings.allowCrossAppGrouping) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow Cross-Application Grouping")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Permits drag-and-drop grouping across different applications into unified task workspaces.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Tab Detach Tear-Off Threshold")
                                .font(.body)
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(Int(settings.tabDetachThreshold)) pt")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.tabDetachThreshold, in: 40...160, step: 5)
                        Text("Vertical drag distance outside the tab bar required to detach a tab into an independent window.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    HStack(spacing: 8) {
                        Button("Tab Focused App (⌃⌥T)") {
                            WorkspaceManager.shared.tabSameAppWindows()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("Tab All Apps Across Display (⌃⌥⌘T)") {
                            WorkspaceManager.shared.tabAllSameAppWindows()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    HStack(spacing: 8) {
                        Button("New Tab (⌃⌥⌘N)") {
                            WorkspaceManager.shared.addTabToFocusedColumn()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Close Tab (⌃⌥⇧W)") {
                            WorkspaceManager.shared.closeActiveTab()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Detach Tab (⌃⌥⌘D)") {
                            WorkspaceManager.shared.detachActiveTab()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Ungroup All (⌃⌥⇧U)") {
                            WorkspaceManager.shared.ungroupFocusedTabGroup()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    HStack(spacing: 8) {
                        Button("Reorder Tab Left (⌃⌥⇧[)") {
                            WorkspaceManager.shared.reorderActiveTabInFocusedColumn(direction: -1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Reorder Tab Right (⌃⌥⇧])") {
                            WorkspaceManager.shared.reorderActiveTabInFocusedColumn(direction: 1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Tab Motion & Effects Card (user-selectable transitions)
                TabEffectsSettingsCard()
                
                // Window Navigation & Focus Controls Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Window Navigation & Strip Controls")
                                .font(.headline)
                            Text("Keyboard navigation, wrap-around focus, column full-width toggling, and tab cycling.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    Toggle(isOn: $settings.wrapAroundFocus) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wrap-Around Focus Navigation")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Loop smoothly between first and last columns when moving past the strip boundaries.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Toggle(isOn: $settings.cycleTabsBeforeColumns) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cycle Tabs Before Columns (⌃⌥Tab)")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Inside browser-style tab groups, ⌃⌥Tab cycles tabs in the active group rather than hopping columns.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Toggle(isOn: $settings.fullWidthToggleRestoresRatio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Width Shortcut Toggles Back (⌃⌥Return / ⌃⌥F)")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Pressing Full Width on an already full-screen column restores its previous width ratio.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                    
                    Text("Interactive Action Controls")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    HStack(spacing: 8) {
                        Button("Prev (⌃⌥H)") {
                            WorkspaceManager.shared.focusPreviousWindow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Next (⌃⌥L)") {
                            WorkspaceManager.shared.focusNextWindow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Above (⌃⌥K)") {
                            WorkspaceManager.shared.focusWindowAbove()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Down (⌃⌥J)") {
                            WorkspaceManager.shared.focusWindowDown()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Cycle (⌃⌥Tab)") {
                            WorkspaceManager.shared.cycleNextWindowOrTab()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    HStack(spacing: 8) {
                        Button("Move Col Left (⌃⌥⇧H)") {
                            WorkspaceManager.shared.moveColumnLeft()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Move Col Right (⌃⌥⇧L)") {
                            WorkspaceManager.shared.moveColumnRight()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Full Width (⌃⌥F)") {
                            WorkspaceManager.shared.toggleFullWidthColumn()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Close Window (⌃⌥W)") {
                            WorkspaceManager.shared.closeActiveWindow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    private var centerModeExplanation: String {
        switch settings.centerMode {
        case .never:
            return "✓ Windows tile tightly side-by-side without empty side gaps. Scrolling only occurs when navigating to offscreen windows."
        case .onOverflow:
            return "Windows are flush when they fit on screen; when total strip width exceeds the screen, the active window centers."
        case .always:
            return "Active window is locked in the physical center of the screen."
        }
    }
    
    // MARK: - 3. Smoothness & Physics Tab
    
    private var scrollingTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Interactive Rotary Smoothness Dial Studio
                VStack(spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smooth Scrolling Studio")
                                .font(.headline)
                            Text("Wheel, coast & settle dynamics · direct touch stays low-latency")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    SmoothScrollWheelView(smoothness: $settings.scrollSmoothness)

                    Text("Smooth Scrolling: Gradual movement between positions; governs wheel interpolation and settle dynamics without relying on gesture momentum. Direct two-finger tracking remains deterministic 1:1 resampled.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Live Interactive Scroll Test Track
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "hand.draw")
                            .foregroundColor(.accentColor)
                        Text("Interactive Trackpad Test Track")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text("Swipe horizontally with 2 fingers")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CGFloat(settings.windowGap > 0 ? settings.windowGap : 8)) {
                            ForEach(1...8, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.accentColor.opacity(0.8), Color.blue.opacity(0.5)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 130, height: 65)
                                    .overlay(
                                        VStack(spacing: 2) {
                                            Image(systemName: "macwindow")
                                                .font(.system(size: 15))
                                            Text("Window \(i)")
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        }
                                        .foregroundColor(.white)
                                    )
                                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                    .frame(height: 75)
                }
                .padding(14)
                .background(settingsCardBackground)
                
                // Physics Tuning & Deceleration / Friction Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("Deceleration & Friction")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Deceleration Factor:")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Governs how quickly scrolling slows down after release")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.3f", settings.scrollDeceleration))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("High Friction (Fast Stop)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Low Friction (Long Glide)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.scrollDeceleration, in: 0.88...0.995, step: 0.005)

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scroll Sensitivity:")
                            Text("Trackpad / wheel delta multiplier")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f×", settings.scrollSensitivity))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.scrollSensitivity, in: 0.5...2.5, step: 0.1)

                    Divider()

                    HStack {
                        Text("Transition Animation Speed:")
                        Spacer()
                        Text(String(format: "%.2fs", settings.animationDuration))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.animationDuration, in: 0.08...0.45, step: 0.02)
                }
                .padding(16)
                .background(settingsCardBackground)

                // Inertial, Momentum & Kinetic Scrolling Card
                VStack(alignment: .leading, spacing: 14) {
                    Text("Inertial, Momentum & Kinetic Scrolling")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    Toggle(isOn: $settings.inertialScrolling) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inertial Scrolling")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Scrolling continues on inertia after your fingers leave the trackpad.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if settings.inertialScrolling {
                        Toggle(isOn: $settings.momentumScrolling) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Momentum Scrolling")
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text("Coasting effect driven directly by the release velocity of your gesture.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if settings.momentumScrolling {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Gesture Velocity Multiplier:")
                                        .font(.subheadline)
                                    Text("Scales release speed into scrolling kinetic energy")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.1f×", settings.momentumMultiplier))
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                            }
                            Slider(value: $settings.momentumMultiplier, in: 0.5...2.5, step: 0.1)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Kinetic Scrolling Profile")
                                .font(.body)
                                .fontWeight(.medium)

                            Picker("", selection: $settings.kineticScrollingProfile) {
                                ForEach(KineticScrollingProfile.allCases) { profile in
                                    Text(profile.displayName).tag(profile)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(settings.kineticScrollingProfile.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Toggle(isOn: $settings.smoothScrollingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smooth Scrolling")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Gradual movement between positions; not necessarily momentum-based (mouse wheel notches, focus steps & programmatic jumps).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Gestures & Snapping Options
                VStack(alignment: .leading, spacing: 12) {
                    Text("Gestures & Snapping")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    Toggle("Enable Smooth Transitions During Focus Change", isOn: $settings.enableTransitions)
                    Toggle(isOn: $settings.freeformScroll) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remain Where Left (Freeform Strip)")
                                .font(.body)
                            Text("Viewport remains exactly where you scroll it without auto-shifting, centering, or moving.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if !settings.freeformScroll {
                        Toggle("Snap Viewport to Column on Gesture Lift", isOn: $settings.snapToColumn)
                    }
                    Toggle(isOn: $settings.freezeOnRelease) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stop Exactly Where Fingers Lift")
                                .font(.body)
                            Text("Locks the strip at the exact offset where your gesture ends — no inertia, fling, or snap. It stays put until you swipe again.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle("Natural Scrolling Direction", isOn: $settings.trackpadNaturalScroll)
                    
                    Divider()
                    
                    Picker("Scroll Trigger Mode", selection: $settings.scrollTriggerMode) {
                        ForEach(ScrollTriggerMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - 4. Visuals & Overlays Tab
    
    private var visualsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("HUD & Focus Highlights")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    Toggle(isOn: $settings.showMinimapHUD) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Floating Strip Minimap HUD")
                                .font(.body)
                            Text("Shows translucent overview of offscreen windows during scroll.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if settings.showMinimapHUD {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("HUD Instrument Style")
                                .font(.body)
                                .fontWeight(.medium)
                            
                            Picker("", selection: $settings.hudStyle) {
                                ForEach(MinimapHUDStyle.allCases, id: \.self) { style in
                                    Text(style.displayName).tag(style)
                                }
                            }
                            .pickerStyle(.menu)
                            
                            Text(settings.hudStyle.subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 8)
                        
                        Toggle("Keep HUD Always Visible", isOn: $settings.hudAlwaysVisible)
                            .padding(.leading, 8)
                    }
                    
                    Divider()
                    
                    Toggle(isOn: $settings.showFocusBorder) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Window Focus Border")
                                .font(.body)
                            Text("Draws an accented highlight border around the focused window.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    Toggle(isOn: $settings.dimUnfocusedWindows) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dim Inactive Windows")
                                .font(.body)
                            Text("Gently dims background windows to focus attention on active task.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    Toggle(isOn: $settings.dragToReorder) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Drag Titlebar to Reorder Columns")
                                .font(.body)
                            Text("Rearrange windows along the strip by dragging them with mouse.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    Toggle("Mouse Follows Focus", isOn: $settings.mouseFollowsFocus)
                    Toggle("Focus Follows Mouse Hover", isOn: $settings.focusFollowsMouse)
                    Toggle("Float Small Windows (< 500pt dialogs & utilities)", isOn: $settings.floatSmallWindows)
                }
                .padding(16)
                .background(settingsCardBackground)
                
                // Endless Loop Mode & Audio Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Endless Loop Mode & Audio")
                                .font(.headline)
                            Text("Wrap strip seamlessly into a continuous loop and tune audio cues.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    Toggle(isOn: $settings.loopMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Endless Loop Mode (Continuous Wrap)")
                                .font(.body)
                                .fontWeight(.medium)
                            Text("Desktop strip wraps around continuously so the last window connects back to the first.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                    
                    Toggle(isOn: $settings.loopSeamSoundEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loop Seam Lap Sound")
                                .font(.body)
                            Text("Plays a subtle wooden mechanical tick when completing a full strip loop.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Toggle(isOn: $settings.hudSoundEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tactile HUD Sound Effects")
                                .font(.body)
                            Text("Audio clicks and feedback when snapping windows and scrolling.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if settings.hudSoundEnabled {
                        HStack {
                            Text("Feedback Volume")
                                .font(.body)
                            Spacer()
                            Slider(value: $settings.hudSoundVolume, in: 0.05...1.0)
                                .frame(width: 140)
                            Text("\(Int(settings.hudSoundVolume * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - 5. Shortcuts Tab
    
    private var shortcutsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Legacy Option (⌥) Shortcut Fallbacks", isOn: Binding(
                        get: { settings.useLegacyOptionShortcuts },
                        set: { newVal in
                            settings.useLegacyOptionShortcuts = newVal
                            ShortcutManager.shared.registerDefaultShortcuts()
                        }
                    ))
                }
                .padding(16)
                .background(settingsCardBackground)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keyboard Navigation & Chords")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    shortcutRow("Focus Next Window", "⌃⌥ + L  /  ⌃⌥ + →")
                    shortcutRow("Focus Previous Window", "⌃⌥ + H  /  ⌃⌥ + ←")
                    shortcutRow("Focus Window Above", "⌃⌥ + K  /  ⌃⌥ + ↑")
                    shortcutRow("Focus Window Down", "⌃⌥ + J  /  ⌃⌥ + ↓")
                    shortcutRow("Move Column Left", "⌃⌥⇧ + H  /  ⌃⌥⇧ + ←")
                    shortcutRow("Move Column Right", "⌃⌥⇧ + L  /  ⌃⌥⇧ + →")
                    shortcutRow("Full Width Column (Toggle)", "⌃⌥ + Return  or  ⌃⌥ + F")
                    shortcutRow("Close Active Window", "⌃⌥ + W")
                    shortcutRow("Cycle Windows / Tabs", "⌃⌥ + Tab")
                    shortcutRow("Cycle Backward", "⌃⌥⇧ + Tab")
                    shortcutRow("First / Last Window on Strip", "⌃⌥⌘ + ← / →")
                    shortcutRow("Cycle Width (25/33/50/66/75%)", "⌃⌥ + R (Fwd)  |  ⌃⌥⇧ + R (Back)")
                    shortcutRow("Nudge Width Narrower / Wider", "⌃⌥ + -  /  ⌃⌥ + =")
                    shortcutRow("Stack Window Taller / Shorter", "⌃⌥⇧ + =  /  ⌃⌥⇧ + -")
                    shortcutRow("Equalize Stack Heights", "⌃⌥ + 0")
                    shortcutRow("Center Active Column on Screen", "⌃⌥ + C")
                    shortcutRow("Pull/Stack into Column Left/Right", "⌃⌥ + [  /  ⌃⌥ + ]")
                    shortcutRow("Pop / Unstack Window", "⌃⌥⇧ + [  /  ⌃⌥⇧ + ]")
                    shortcutRow("Tab Windows of Same App Together", "⌃⌥ + T")
                    shortcutRow("Tab All Same-App Windows", "⌃⌥⌘ + T")
                    shortcutRow("Next / Previous Tab in Column", "⌃⌥⌘ + ]  /  ⌃⌥⌘ + [")
                    shortcutRow("New Tab in Current Group", "⌃⌥⌘ + N")
                    shortcutRow("Close Active Tab", "⌃⌥⇧ + W")
                    shortcutRow("Detach Active Tab from Group", "⌃⌥⌘ + D")
                    shortcutRow("Ungroup All Tabs in Column", "⌃⌥⇧ + U")
                    shortcutRow("Keep Tab Bar Visible (Pin)", "⌃⌥⇧ + P")
                    shortcutRow("Toggle Stack vs. Tabbed Column", "⌃⌥⇧ + T")
                    shortcutRow("Strip Overview & Drag-Adjust", "⌃⌥ + O  or  ⌥ + O")
                    shortcutRow("Float / Unfloat Active Window", "⌃⌥⇧ + F")
                    shortcutRow("Send Window to Next Display", "⌃⌥ + N")
                    shortcutRow("Direct Focus Display 1 / 2 / 3", "⌃⌥⌘ + 1 / 2 / 3")
                    shortcutRow("Throw Window to Left / Right Space", "⌃⌥⇧ + ← / →")
                    shortcutRow("Force Re-evaluate & Refresh Windows", "⌃⌥ + Z")
                    shortcutRow("Relaunch Iume Daemon", "⌃⌥⇧ + Z")
                    shortcutRow("Toggle Zero Gap (Flush Edges)", "⌃⌥ + G")
                    shortcutRow("Open Settings Window", "⌃⌥ + ,")
                    shortcutRow("Stop & Restore Windows", "⌃⌥ + Q  or  ⌃⌥⇧ + S")
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    private func shortcutRow(_ label: String, _ shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(5)
        }
    }
    
    // MARK: - 6. Rules Tab
    
    private var rulesTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Excluded Floating Applications")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    Text("These applications float freely above the strip and are not managed:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    List {
                        ForEach(settings.excludedBundleIdentifiers, id: \.self) { bundleId in
                            HStack {
                                Image(systemName: "app.dashed")
                                    .foregroundColor(.secondary)
                                Text(bundleId)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .onDelete { indexSet in
                            settings.excludedBundleIdentifiers.remove(atOffsets: indexSet)
                        }
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - 7. Diagnostics Tab
    
    private var diagnosticsTab: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Diagnostics & State")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    HStack {
                        Button("Export Full Diagnostic Dump") {
                            let report = WorkspaceManager.shared.dumpAllWindows()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                        
                        Button("Repair Accessibility Permissions (tccutil reset)") {
                            permissions.repairStaleTCCEntry()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Divider()
                    
                    Button("Reset All Settings to Factory Defaults", role: .destructive) {
                        settings.resetToDefaults()
                        WorkspaceManager.shared.reflowColumnsForGeometryChange()
                        WorkspaceManager.shared.applyLayout(animated: true)
                    }
                }
                .padding(16)
                .background(settingsCardBackground)
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Shared Helpers
    
    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
    }
    
    private func presetPill(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live Strip Preview Mini Canvas

struct LiveStripPreviewView: View {
    let windowGap: Double
    let edgeMargins: EdgeMargins
    let columnRatio: Double
    let centerMode: CenterMode
    
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let padL = max(0, min(16, CGFloat(edgeMargins.left) * 0.4))
            let padR = max(0, min(16, CGFloat(edgeMargins.right) * 0.4))
            let gap = max(0, min(18, CGFloat(windowGap) * 0.5))
            let usable = w - padL - padR
            let colW = max(30, floor((usable - gap) * CGFloat(columnRatio)))
            
            ZStack(alignment: .leading) {
                // Background display canvas
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                
                HStack(spacing: gap) {
                    // Window Column 1
                    previewWindowCard(title: "Code", color: Color.blue, isFocused: true)
                        .frame(width: colW)
                    
                    // Window Column 2
                    previewWindowCard(title: "Browser", color: Color.purple, isFocused: false)
                        .frame(width: colW)
                    
                    // Window Column 3 (Peeking)
                    previewWindowCard(title: "Terminal", color: Color.teal, isFocused: false)
                        .frame(width: colW)
                }
                .padding(.leading, padL)
                .padding(.trailing, padR)
                .padding(.vertical, 8)
            }
        }
    }
    
    private func previewWindowCard(title: String, color: Color, isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.opacity(isFocused ? 0.85 : 0.45))
            .overlay(
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        Circle().fill(Color.red.opacity(0.7)).frame(width: 4, height: 4)
                        Circle().fill(Color.yellow.opacity(0.7)).frame(width: 4, height: 4)
                        Circle().fill(Color.green.opacity(0.7)).frame(width: 4, height: 4)
                        Spacer()
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 4)
                    
                    Spacer()
                    Text(title)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(isFocused ? 0.25 : 0.08), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Rotary Smoothness Wheel

public struct SmoothScrollWheelView: View {
    @Binding var smoothness: Double
    
    private var angleDegrees: Double {
        let clamped = min(max(smoothness, 0.05), 1.0)
        // -135° to +135°
        return -135.0 + (clamped * 270.0)
    }
    
    public init(smoothness: Binding<Double>) {
        self._smoothness = smoothness
    }
    
    public var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                // Rotary Wheel
                ZStack {
                    // Outer Ring with vibrant glowing gradient
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    Color.blue.opacity(0.4),
                                    Color.cyan,
                                    Color.accentColor,
                                    Color.purple,
                                    Color.blue.opacity(0.4)
                                ],
                                center: .center,
                                startAngle: .degrees(-145),
                                endAngle: .degrees(145)
                            ),
                            lineWidth: 5
                        )
                        .frame(width: 90, height: 90)
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 7, x: 0, y: 0)
                    
                    // Dial tick notches
                    ForEach(0..<13) { tick in
                        let tickAngle = -135.0 + (Double(tick) / 12.0) * 270.0
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 1.5, height: tick % 3 == 0 ? 6 : 3)
                            .offset(y: -49)
                            .rotationEffect(.degrees(tickAngle))
                    }
                    
                    // Wheel Knob Base
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(nsColor: .controlBackgroundColor),
                                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: 44
                            )
                        )
                        .frame(width: 76, height: 76)
                        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                    
                    // Needle Pointer
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3.5, height: 22)
                        .offset(y: -20)
                        .rotationEffect(.degrees(angleDegrees))
                    
                    // Center readout badge
                    VStack(spacing: 1) {
                        Text("\(Int(smoothness * 100))%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .monospacedDigit()
                        Text("Smooth")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                    }
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let center = CGPoint(x: 45, y: 45)
                            let dx = value.location.x - center.x
                            let dy = value.location.y - center.y
                            let rad = atan2(dy, dx)
                            var deg = rad * 180.0 / .pi + 90.0
                            if deg < 0 { deg += 360.0 }
                            
                            // Map degrees from -135° to +135°
                            let normalized: Double
                            if deg >= 225 {
                                normalized = (deg - 225) / 270.0
                            } else if deg <= 135 {
                                normalized = (deg + 135) / 270.0
                            } else {
                                return
                            }
                            smoothness = min(max(normalized, 0.05), 1.0)
                        }
                )
                
                // Explanatory Physics Readout
                VStack(alignment: .leading, spacing: 4) {
                    Text(feelingTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text(feelingSubtext)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    HStack(spacing: 8) {
                        telemetryBadge(title: "Settle", val: "\(Int(max(60, 60 + smoothness * 220)))ms")
                        telemetryBadge(title: "Damping", val: String(format: "%.2f", max(0.82, 0.96 - smoothness * 0.10)))
                        telemetryBadge(title: "VSYNC", val: "120Hz")
                    }
                    .padding(.top, 4)
                }
            }
            
            // Quick preset pills
            HStack(spacing: 8) {
                presetButton(title: "⚡️ Snappy (25%)", value: 0.25)
                presetButton(title: "⚖️ Balanced (50%)", value: 0.50)
                presetButton(title: "✨ Silky (75%)", value: 0.75)
                presetButton(title: "🌊 Liquid (100%)", value: 1.0)
            }
        }
    }
    
    private func telemetryBadge(title: String, val: String) -> some View {
        HStack(spacing: 3) {
            Text(title + ":")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(val)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.10))
        .cornerRadius(4)
    }
    
    private var feelingTitle: String {
        if smoothness <= 0.30 {
            return "⚡️ Crisp & Instant Snap"
        } else if smoothness <= 0.60 {
            return "⚖️ Balanced Fluid Motion"
        } else if smoothness <= 0.85 {
            return "✨ Harmonic 120Hz Gliding"
        } else {
            return "🌊 Ultra Liquid ProMotion"
        }
    }
    
    private var feelingSubtext: String {
        if smoothness <= 0.30 {
            return "Crisp wheel snap with minimal coasting; the strip stops immediately when fingers lift."
        } else if smoothness <= 0.60 {
            return "Natural macOS trackpad physics with crisp column latching."
        } else if smoothness <= 0.85 {
            return "Harmonic wheel and settle interpolation with cushioned, jitter-free coasting."
        } else {
            return "Maximum inertial coasting with buttery elastic boundary resistance."
        }
    }
    
    private func presetButton(title: String, value: Double) -> some View {
        let isSelected = abs(smoothness - value) < 0.12
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                smoothness = value
            }
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
