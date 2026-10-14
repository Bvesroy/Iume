import Foundation
import CoreGraphics
import ApplicationServices

/// Represents an application window managed by Iume.
public struct ManagedWindow: Identifiable, Equatable, Sendable {
    public let id: WindowId
    public let pid: pid_t
    public var bundleIdentifier: String
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var isFloating: Bool
    public var isPinned: Bool
    public var isFocused: Bool
    public var isMinimized: Bool
    public var isFullscreen: Bool
    public var minSize: CGSize?
    public var preferredWidth: CGFloat?
    public var lastSeen: Date
    
    public init(
        id: WindowId,
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        title: String,
        frame: CGRect,
        isFloating: Bool = false,
        isPinned: Bool = false,
        isFocused: Bool = false,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        minSize: CGSize? = nil,
        preferredWidth: CGFloat? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isFloating = isFloating
        self.isPinned = isPinned
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.minSize = minSize
        self.preferredWidth = preferredWidth
        self.lastSeen = lastSeen
    }
}
