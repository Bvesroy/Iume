import AppKit
import ApplicationServices
import IumeCore

@MainActor
func runLiveTest() {
    print("==================================================================")
    print(" 🚀 Iume Window Manager — Live On-Screen Test")
    print("==================================================================")
    
    // 1. Accessibility verification
    let trusted = AXIsProcessTrusted()
    print("Accessibility Permission: \(trusted ? "✅ GRANTED" : "❌ NOT GRANTED")")
    if !trusted {
        print("Prompting for accessibility permissions...")
        PermissionManager.shared.promptForAccessibility()
    }
    
    // 2. Display Topology
    let displayManager = DisplayManager()
    displayManager.refreshDisplays()
    guard let primary = displayManager.primaryDisplay() else {
        print("❌ Error: No primary display detected.")
        return
    }
    print("\n🖥️  Primary Display: \(primary.name) (ID: \(primary.id))")
    print("    Full Frame:    \(primary.frame)")
    print("    Visible Frame: \(primary.visibleFrame)")
    
    // 3. Application Discovery
    let appDiscovery = ApplicationDiscovery()
    let settings = SettingsStore.shared
    
    // Ensure Finder is not excluded for our live test
    settings.excludedBundleIdentifiers.removeAll { $0 == "com.apple.finder" }
    print("\n📦 Active Exclusions: \(settings.excludedBundleIdentifiers)")
    
    let apps = appDiscovery.discoverEligibleApplications(excludedBundleIds: settings.excludedBundleIdentifiers)
    print("\n🔍 Discovered \(apps.count) Eligible GUI Applications:")
    for app in apps {
        print("   • [PID \(app.id)] \(app.localizedName) (\(app.bundleIdentifier))")
    }
    
    // 4. Window Discovery & Registration
    let windowDiscovery = WindowDiscovery()
    let layoutEngine = LayoutEngine(
        windowGap: settings.appsEdgeTogether ? 0.0 : settings.windowGap,
        edgeMargins: settings.edgeMargins,
        defaultColumnWidthRatio: settings.defaultColumnWidthRatio
    )
    let windowController = WindowController()
    
    var columns: [WindowColumn] = []
    var windowMap: [WindowId: ManagedWindow] = [:]
    var axMap: [WindowId: AXUIElement] = [:]
    
    print("\n🪟 Inspecting Open Windows:")
    for app in apps {
        let windows = windowDiscovery.discoverWindows(for: app.id, bundleId: app.bundleIdentifier, appName: app.localizedName)
        if windows.isEmpty {
            continue
        }
        for (win, ax) in windows {
            print("   ▶ [\(app.localizedName)] Title: \"\(win.title)\"")
            print("     ID: \(win.id), Frame: \(win.frame), isMinimized: \(win.isMinimized), isFloating: \(win.isFloating)")
            
            windowMap[win.id] = win
            axMap[win.id] = ax
            
            // Insert window into horizontal strip column
            _ = layoutEngine.insertWindow(
                win.id,
                into: &columns,
                focusedColumnIndex: nil,
                policy: .atEnd,
                visibleWidth: primary.visibleFrame.width
            )
        }
    }
    
    let totalWindows = windowMap.count
    let totalColumns = columns.count
    print("\n📊 Summary:")
    print("   Total Managed Windows: \(totalWindows)")
    print("   Total Strip Columns:   \(totalColumns)")
    
    if columns.isEmpty {
        print("⚠️ No eligible windows found to tile.")
        return
    }
    
    // 5. Layout Calculation
    let stripWidth = layoutEngine.totalStripWidth(columns: columns)
    print("   Total Strip Width:     \(stripWidth) pt (Screen Visible Width: \(primary.visibleFrame.width) pt)")
    
    let computation = layoutEngine.computeLayout(
        columns: columns,
        windows: windowMap,
        focusedColumnIndex: 0,
        visibleFrame: primary.visibleFrame,
        viewportOffset: 0,
        layoutMode: .scrollStrip
    )
    
    print("\n📐 Computed Target Frames for Strip Columns:")
    let stripOffsets = layoutEngine.columnStripOffsets(columns: columns)
    for (colIdx, col) in columns.enumerated() {
        let xOffset = stripOffsets[colIdx]
        print("   Column [\(colIdx)] (Strip X: \(xOffset), Width: \(col.width)):")
        for winId in col.windowIds {
            if let win = windowMap[winId], let targetFrame = computation.targetFrames[winId] {
                print("     - [\(win.appName)] \"\(win.title)\"")
                print("       -> Target Screen Frame: origin=(\(targetFrame.origin.x), \(targetFrame.origin.y)), size=(\(targetFrame.size.width) x \(targetFrame.size.height))")
            }
        }
    }
    
    // 6. Apply Live Window Positioning
    print("\n⚡ Applying Layout to Live Windows...")
    var appliedCount = 0
    for (winId, targetFrame) in computation.targetFrames {
        if let ax = axMap[winId], let win = windowMap[winId] {
            let ok = windowController.setFrame(element: ax, frame: targetFrame, windowId: winId)
            print("   \(ok ? "✅" : "⚠️") [\(win.appName)] Set frame to \(targetFrame)")
            appliedCount += 1
        }
    }
    
    print("\n🎉 Live Layout Application Complete: \(appliedCount) windows tiled side by side on strip!")
    print("==================================================================")
}

runLiveTest()
