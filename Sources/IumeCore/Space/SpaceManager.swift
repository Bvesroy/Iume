import Foundation
import CoreGraphics
import AppKit

/// Monitors macOS Mission Control virtual spaces and multi-display desktop environments.
/// Enables independent horizontal strip layouts per physical display and virtual Space.
@MainActor
public final class SpaceManager: NSObject, ObservableObject {
    public static let shared = SpaceManager()
    
    // Callbacks
    public var onActiveSpaceChanged: ((UInt64, CGDirectDisplayID) -> Void)?
    
    // Cached space identification
    @Published public private(set) var currentSpaceId: UInt64 = 1
    
    private typealias CGSConnectionID = UInt32
    private typealias CGSSpaceID = UInt64
    
    private var cgsMainConnectionIDFunc: (@convention(c) () -> CGSConnectionID)?
    private var cgsGetActiveSpaceFunc: (@convention(c) (CGSConnectionID) -> CGSSpaceID)?
    private var cgsCopyManagedDisplaySpacesFunc: (@convention(c) (CGSConnectionID) -> CFArray?)?
    
    public override init() {
        super.init()
        loadSkyLightSymbols()
        refreshCurrentSpace()
        setupSpaceObserver()
    }
    
    // MARK: - SkyLight Dynamic Symbol Resolution
    
    private func loadSkyLightSymbols() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else {
            return
        }
        
        if let symConn = dlsym(handle, "CGSMainConnectionID") {
            cgsMainConnectionIDFunc = unsafeBitCast(symConn, to: (@convention(c) () -> CGSConnectionID).self)
        }
        if let symActive = dlsym(handle, "CGSGetActiveSpace") {
            cgsGetActiveSpaceFunc = unsafeBitCast(symActive, to: (@convention(c) (CGSConnectionID) -> CGSSpaceID).self)
        }
        if let symDisplaySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") {
            cgsCopyManagedDisplaySpacesFunc = unsafeBitCast(symDisplaySpaces, to: (@convention(c) (CGSConnectionID) -> CFArray?).self)
        }
    }
    
    // MARK: - Space Querying
    
    /// Queries the currently active Space ID from the system.
    public func activeSpaceId() -> UInt64 {
        if let connFunc = cgsMainConnectionIDFunc, let activeFunc = cgsGetActiveSpaceFunc {
            let cid = connFunc()
            let spaceId = activeFunc(cid)
            if spaceId != 0 {
                return spaceId
            }
        }
        return currentSpaceId
    }
    
    /// Returns the active Space ID for a given display.
    public func activeSpaceId(for displayId: CGDirectDisplayID) -> UInt64 {
        guard let connFunc = cgsMainConnectionIDFunc,
              let displaySpacesFunc = cgsCopyManagedDisplaySpacesFunc else {
            return activeSpaceId()
        }
        
        let cid = connFunc()
        guard let displaySpaces = displaySpacesFunc(cid) as? [[String: Any]] else {
            return activeSpaceId()
        }
        
        // Find matching display entry
        for dict in displaySpaces {
            if let currentSpace = dict["Current Space"] as? [String: Any],
               let spaceId = currentSpace["ManagedSpaceID"] as? UInt64 ?? (currentSpace["id64"] as? UInt64) {
                if let dispUUID = dict["Display Identifier"] as? String {
                    if dispUUID == "Main" && displayId == CGMainDisplayID() {
                        return spaceId
                    }
                }
                return spaceId
            }
        }
        
        return activeSpaceId()
    }
    
    @discardableResult
    public func refreshCurrentSpace() -> UInt64 {
        let space = activeSpaceId()
        self.currentSpaceId = space
        return space
    }
    
    // MARK: - Observer
    
    private func setupSpaceObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleSpaceChange() {
        let newSpaceId = refreshCurrentSpace()
        let displayId: CGDirectDisplayID = {
            if NSScreen.screens.count > 1,
               let keyWin = NSApp.keyWindow,
               let scr = keyWin.screen,
               let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return num
            }
            return NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        }()
        onActiveSpaceChanged?(newSpaceId, displayId)
    }
}
