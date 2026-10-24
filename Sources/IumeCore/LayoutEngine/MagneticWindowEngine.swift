import Foundation
import CoreGraphics

/// Pure deterministic magnetic layout engine managing magnetic window adhesion,
/// distance-based edge snapping, and seamless adjacent column coupling.
public struct MagneticWindowEngine: Sendable {
    
    public struct SnapResult: Equatable, Sendable {
        public enum Edge: String, Equatable, Sendable {
            case leftOfCandidate  // Dragged window snapped to candidate's left edge
            case rightOfCandidate // Dragged window snapped to candidate's right edge
            case screenLeftEdge   // Dragged window snapped to screen's left edge
            case screenRightEdge  // Dragged window snapped to screen's right edge
        }
        
        public let snappedFrame: CGRect
        public let candidateWindowId: WindowId?
        public let candidateFrame: CGRect?
        public let edge: Edge
        public let distance: CGFloat
        
        public init(
            snappedFrame: CGRect,
            candidateWindowId: WindowId?,
            candidateFrame: CGRect?,
            edge: Edge,
            distance: CGFloat
        ) {
            self.snappedFrame = snappedFrame
            self.candidateWindowId = candidateWindowId
            self.candidateFrame = candidateFrame
            self.edge = edge
            self.distance = distance
        }
    }
    
    public var snapRadius: CGFloat
    public var breakawayThreshold: CGFloat
    
    public init(
        snapRadius: CGFloat = 36.0,
        breakawayThreshold: CGFloat = 160.0
    ) {
        self.snapRadius = snapRadius
        self.breakawayThreshold = breakawayThreshold
    }
    
    // MARK: - Magnetic Snap Evaluation
    
    /// Evaluates if a dragged window is close enough to any open candidate window
    /// or visible screen edge to trigger an automatic magnetic snap.
    public func evaluateMagneticSnap(
        draggedWindowId: WindowId,
        draggedFrame: CGRect,
        candidateWindows: [(id: WindowId, frame: CGRect)],
        gap: CGFloat,
        visibleFrame: CGRect? = nil
    ) -> SnapResult? {
        if RustEngine.isAvailable {
            return RustEngine.evaluateMagneticSnap(
                draggedId: draggedWindowId,
                draggedFrame: draggedFrame,
                candidateWindows: candidateWindows,
                gap: gap,
                visibleFrame: visibleFrame,
                snapRadius: snapRadius
            )
        }
        var bestResult: SnapResult?
        var minDistance = snapRadius + 1.0
        
        // 1. Evaluate candidate window proximity
        for candidate in candidateWindows where candidate.id != draggedWindowId {
            let cFrame = candidate.frame
            
            // Check vertical proximity: must overlap or be near vertically
            let verticalOverlap = max(0, min(draggedFrame.maxY, cFrame.maxY) - max(draggedFrame.minY, cFrame.minY))
            let verticalDistance = abs(draggedFrame.minY - cFrame.minY)
            guard verticalOverlap > 0 || verticalDistance <= snapRadius * 1.5 else {
                continue
            }
            
            // Dragged window brought to the LEFT of candidate
            // Target: draggedFrame.maxX + gap == cFrame.minX
            let targetMaxX = cFrame.minX - gap
            let distLeft = abs(draggedFrame.maxX - targetMaxX)
            if distLeft <= snapRadius && distLeft < minDistance {
                let snappedOriginX = targetMaxX - draggedFrame.width
                let snappedY = cFrame.origin.y
                let snappedH = cFrame.height
                let snapped = CGRect(
                    x: round(snappedOriginX),
                    y: round(snappedY),
                    width: round(draggedFrame.width),
                    height: round(snappedH)
                )
                
                minDistance = distLeft
                bestResult = SnapResult(
                    snappedFrame: snapped,
                    candidateWindowId: candidate.id,
                    candidateFrame: cFrame,
                    edge: .leftOfCandidate,
                    distance: distLeft
                )
            }
            
            // Dragged window brought to the RIGHT of candidate
            // Target: draggedFrame.minX == cFrame.maxX + gap
            let targetMinX = cFrame.maxX + gap
            let distRight = abs(draggedFrame.minX - targetMinX)
            if distRight <= snapRadius && distRight < minDistance {
                let snappedOriginX = targetMinX
                let snappedY = cFrame.origin.y
                let snappedH = cFrame.height
                let snapped = CGRect(
                    x: round(snappedOriginX),
                    y: round(snappedY),
                    width: round(draggedFrame.width),
                    height: round(snappedH)
                )
                
                minDistance = distRight
                bestResult = SnapResult(
                    snappedFrame: snapped,
                    candidateWindowId: candidate.id,
                    candidateFrame: cFrame,
                    edge: .rightOfCandidate,
                    distance: distRight
                )
            }
        }
        
        // 2. Evaluate screen edge proximity if visibleFrame is provided
        if let vis = visibleFrame {
            let distScreenLeft = abs(draggedFrame.minX - vis.minX)
            if distScreenLeft <= snapRadius && distScreenLeft < minDistance {
                let snapped = CGRect(
                    x: round(vis.minX),
                    y: round(draggedFrame.minY),
                    width: round(draggedFrame.width),
                    height: round(draggedFrame.height)
                )
                minDistance = distScreenLeft
                bestResult = SnapResult(
                    snappedFrame: snapped,
                    candidateWindowId: nil,
                    candidateFrame: nil,
                    edge: .screenLeftEdge,
                    distance: distScreenLeft
                )
            }
            
            let distScreenRight = abs(draggedFrame.maxX - vis.maxX)
            if distScreenRight <= snapRadius && distScreenRight < minDistance {
                let snapped = CGRect(
                    x: round(vis.maxX - draggedFrame.width),
                    y: round(draggedFrame.minY),
                    width: round(draggedFrame.width),
                    height: round(draggedFrame.height)
                )
                minDistance = distScreenRight
                bestResult = SnapResult(
                    snappedFrame: snapped,
                    candidateWindowId: nil,
                    candidateFrame: nil,
                    edge: .screenRightEdge,
                    distance: distScreenRight
                )
            }
        }
        
        return bestResult
    }
    
    // MARK: - Magnetic Adhesion (Chained Adjacent Windows)
    
    /// Computes target frames for adjacent neighbor windows so that when one window is moved,
    /// its adjacent companion windows remain attached to it like a magnetic chain.
    public func computeChainedNeighborFrames(
        draggedWindowId: WindowId,
        draggedFrame: CGRect,
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        gap: CGFloat,
        visibleFrame: CGRect? = nil
    ) -> [WindowId: CGRect] {
        guard let colIdx = columns.firstIndex(where: { $0.windowIds.contains(draggedWindowId) }) else {
            return [:]
        }
        
        if RustEngine.isAvailable {
            guard let accelerated = RustEngine.computeChainedFrames(
                draggedId: draggedWindowId,
                draggedFrame: draggedFrame,
                columns: columns,
                windows: windows,
                gap: gap,
                breakawayThreshold: breakawayThreshold,
                capacity: max(1, windows.count)
            ) else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: accelerated.map { ($0.id, $0.frame) })
        }
        
        // Clean breakaway check: if the user intentionally rips the window away vertically,
        // decouple the magnetic chain to allow independent movement
        if let origWin = windows[draggedWindowId] {
            let verticalDisplacement = abs(draggedFrame.minY - origWin.frame.minY)
            if verticalDisplacement > breakawayThreshold {
                return [:]
            }
        }
        
        var chainedFrames: [WindowId: CGRect] = [:]
        let usableY = draggedFrame.origin.y
        let usableHeight = draggedFrame.height
        
        // 1. Right adjacent neighbors (Column colIdx + 1, colIdx + 2, ...)
        var runningRightX = draggedFrame.maxX + gap
        if colIdx + 1 < columns.count {
            for rightIdx in (colIdx + 1)..<columns.count {
                let col = columns[rightIdx]
                let managedWins = col.windowIds.compactMap { windows[$0] }.filter { !$0.isFloating && !$0.isMinimized }
                guard !managedWins.isEmpty else { break }
                
                let count = managedWins.count
                let singleHeight = (usableHeight - CGFloat(count - 1) * gap) / CGFloat(count)
                
                for (stackIdx, win) in managedWins.enumerated() {
                    let winY = usableY + CGFloat(stackIdx) * (singleHeight + gap)
                    let frame = CGRect(
                        x: round(runningRightX),
                        y: round(winY),
                        width: round(col.width),
                        height: round(singleHeight)
                    )
                    chainedFrames[win.id] = frame
                }
                
                runningRightX += col.width + gap
            }
        }
        
        // 2. Left adjacent neighbors (Column colIdx - 1, colIdx - 2, ...)
        var runningLeftEdgeX = draggedFrame.minX - gap
        if colIdx > 0 {
            for leftIdx in stride(from: colIdx - 1, through: 0, by: -1) {
                let col = columns[leftIdx]
                let managedWins = col.windowIds.compactMap { windows[$0] }.filter { !$0.isFloating && !$0.isMinimized }
                guard !managedWins.isEmpty else { break }
                
                let colOriginX = runningLeftEdgeX - col.width
                let count = managedWins.count
                let singleHeight = (usableHeight - CGFloat(count - 1) * gap) / CGFloat(count)
                
                for (stackIdx, win) in managedWins.enumerated() {
                    let winY = usableY + CGFloat(stackIdx) * (singleHeight + gap)
                    let frame = CGRect(
                        x: round(colOriginX),
                        y: round(winY),
                        width: round(col.width),
                        height: round(singleHeight)
                    )
                    chainedFrames[win.id] = frame
                }
                
                runningLeftEdgeX = colOriginX - gap
            }
        }
        
        return chainedFrames
    }
    
    // MARK: - Seam Ratio Snapping
    
    /// Snaps a dragged seam boundary between two adjacent columns to standard proportional splits
    /// (e.g. 50%, 33.3%, 66.7%, 25%, 75%) within a magnetic capture radius.
    public static func snapSeamRatio(
        combinedWidth: CGFloat,
        targetWidth: CGFloat,
        ratios: [Double] = [0.25, 0.3333, 0.50, 0.6667, 0.75],
        snapRadius: CGFloat = 18.0
    ) -> CGFloat {
        if RustEngine.isAvailable,
           ratios == [0.25, 0.3333, 0.50, 0.6667, 0.75] {
            return RustEngine.snapSeamRatio(
                combinedWidth: combinedWidth,
                targetWidth: targetWidth,
                snapRadius: snapRadius
            )
        }
        var bestWidth = targetWidth
        var minDiff = snapRadius + 1.0
        
        for ratio in ratios {
            let candidate = round(combinedWidth * ratio)
            let diff = abs(targetWidth - candidate)
            if diff <= snapRadius && diff < minDiff {
                minDiff = diff
                bestWidth = candidate
            }
        }
        return bestWidth
    }
    
    // MARK: - Magnetic Snap Interpolation
    
    /// Smoothly interpolates window frame during a magnetic snap lock animation according to the selected transition style.
    public static func interpolateMagneticSnap(
        from: CGRect,
        to: CGRect,
        progress: CGFloat,
        style: MagneticSnapTransitionStyle
    ) -> CGRect {
        let t = max(0.0, min(1.0, progress))
        if t <= 0.0 { return from }
        if t >= 1.0 { return to }
        
        let easedT: CGFloat
        switch style {
        case .instantWeld:
            easedT = 1.0
        case .crispLock:
            easedT = 1.0 - pow(1.0 - t, 3.0)
        case .elasticMagnet:
            let p = 1.0 - t
            easedT = 1.0 - pow(p, 2.0) * cos(t * .pi * 1.5)
        case .velvetGlide:
            easedT = t * t * (3.0 - 2.0 * t)
        case .liquidSpring:
            easedT = 1.0 - pow(2.0, -10.0 * t) * cos((t * 10.0 - 0.75) * (2.0 * .pi / 3.0))
        }
        
        let x = from.origin.x + (to.origin.x - from.origin.x) * easedT
        let y = from.origin.y + (to.origin.y - from.origin.y) * easedT
        let w = from.size.width + (to.size.width - from.size.width) * easedT
        let h = from.size.height + (to.size.height - from.size.height) * easedT
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
