import AppKit
import CoreGraphics
import ApplicationServices

/// Data model representing a rendered window card in the strip overview.
public struct WindowPreviewItem: Identifiable, Sendable {
    public let id: WindowId
    public let columnId: UUID
    public let title: String
    public let appName: String
    public let appIcon: NSImage
    public let snapshot: NSImage?
    public let aspectRatio: CGFloat
    public let stackedCount: Int
    
    public init(
        id: WindowId,
        columnId: UUID,
        title: String,
        appName: String,
        appIcon: NSImage,
        snapshot: NSImage?,
        aspectRatio: CGFloat = 1.6,
        stackedCount: Int = 1
    ) {
        self.id = id
        self.columnId = columnId
        self.title = title
        self.appName = appName
        self.appIcon = appIcon
        self.snapshot = snapshot
        self.aspectRatio = aspectRatio
        self.stackedCount = stackedCount
    }
}

/// Helper utility for capturing window thumbnails and resolving application metadata.
@MainActor
public final class WindowPreviewCapturer {
    public static func capturePreview(
        for window: ManagedWindow,
        cgWindowId: CGWindowID?,
        columnId: UUID,
        stackedCount: Int = 1
    ) -> WindowPreviewItem {
        let app = NSRunningApplication(processIdentifier: window.pid)
        let defaultIcon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let icon = app?.icon ?? defaultIcon
        let appName = app?.localizedName ?? (window.appName.isEmpty ? "Application" : window.appName)
        let title = window.title.isEmpty ? appName : window.title
        
        var snapshotImage: NSImage? = nil
        if let wid = cgWindowId, wid > 0 {
            if let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                wid,
                [.bestResolution, .boundsIgnoreFraming]
            ) {
                snapshotImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }
        }
        
        let ratio: CGFloat
        if window.frame.height > 0 && window.frame.width > 0 {
            ratio = window.frame.width / window.frame.height
        } else {
            ratio = 1.6
        }
        
        return WindowPreviewItem(
            id: window.id,
            columnId: columnId,
            title: title,
            appName: appName,
            appIcon: icon,
            snapshot: snapshotImage,
            aspectRatio: max(0.5, min(2.5, ratio)),
            stackedCount: stackedCount
        )
    }
}
