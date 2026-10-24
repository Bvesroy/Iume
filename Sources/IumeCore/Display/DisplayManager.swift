import Foundation
import AppKit
import CoreGraphics

/// Monitors display hardware topology, geometry changes, and screen parameter updates.
@MainActor
public final class DisplayManager: ObservableObject {
    
    @Published public private(set) var activeDisplays: [DisplayGeometry] = []
    public var onDisplaysChanged: (([DisplayGeometry]) -> Void)?
    
    public init() {
        refreshDisplays()
        setupObserver()
    }
    
    public func refreshDisplays() {
        var geometries: [DisplayGeometry] = []
        let screens = NSScreen.screens
        let primaryScreen = screens.first
        
        for screen in screens {
            let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let displayID = CGDirectDisplayID(screenNumber)
            let isPrimary = (screen == primaryScreen)
            let name = screen.localizedName
            
            // Convert AppKit coordinates (bottom-left origin) to Quartz/Accessibility coordinates (top-left origin)
            let primaryHeight = primaryScreen?.frame.height ?? screen.frame.height
            
            let frame = CGRect(
                x: screen.frame.origin.x,
                y: primaryHeight - (screen.frame.origin.y + screen.frame.height),
                width: screen.frame.width,
                height: screen.frame.height
            )
            
            let visibleFrame = CGRect(
                x: screen.visibleFrame.origin.x,
                y: primaryHeight - (screen.visibleFrame.origin.y + screen.visibleFrame.height),
                width: screen.visibleFrame.width,
                height: screen.visibleFrame.height
            )
            
            geometries.append(DisplayGeometry(
                id: displayID,
                name: name,
                frame: frame,
                visibleFrame: visibleFrame,
                isPrimary: isPrimary
            ))
        }
        
        self.activeDisplays = geometries
        onDisplaysChanged?(geometries)
    }
    
    public func setActiveDisplaysForTesting(_ displays: [DisplayGeometry]) {
        self.activeDisplays = displays
        onDisplaysChanged?(displays)
    }
    
    public func primaryDisplay() -> DisplayGeometry? {
        activeDisplays.first { $0.isPrimary } ?? activeDisplays.first
    }
    
    private func setupObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    @objc private func handleScreenChange() {
        refreshDisplays()
    }
}
