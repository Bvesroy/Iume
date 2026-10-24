import Foundation
import CoreGraphics

/// Action representing geometric snapping to standard screen boxes, halves, quarters, and thirds.
public enum WindowBoxAction: String, CaseIterable, Codable, Sendable {
    // Halves
    case leftHalf = "Left Half"
    case rightHalf = "Right Half"
    case topHalf = "Top Half"
    case bottomHalf = "Bottom Half"
    
    // Quarters / Corners
    case topLeft = "Top-Left Quarter"
    case topRight = "Top-Right Quarter"
    case bottomLeft = "Bottom-Left Quarter"
    case bottomRight = "Bottom-Right Quarter"
    
    // Thirds
    case firstThird = "First Third"
    case centerThird = "Center Third"
    case lastThird = "Last Third"
    case firstTwoThirds = "First Two Thirds"
    case lastTwoThirds = "Last Two Thirds"
    
    // Fullscreen / Center
    case maximize = "Maximize"
    case almostMaximize = "Almost Maximize"
    case center = "Center Window"
    
    // Resizing & Scaling
    case larger = "Expand (Larger)"
    case smaller = "Shrink (Smaller)"
    case balance = "Balance Window Sizes"
}

/// A pure deterministic layout engine providing:
/// 1. Tiling of all open windows into Grid, Tall, Wide, and BSP box layouts.
/// 2. Precise calculation of Halves, Quarters, Thirds, and Centered boxes.
/// 3. Cooperative corner and edge resizing: dynamically resizing adjacent windows that share a border.
/// 4. Cycle size progressions (Rectangle parity: 1/2 -> 2/3 -> 1/3).
/// 5. Balance sizes: distributing screen space equally across open windows.
/// 6. Screen edge & corner snap zone detection (Rectangle & Loop parity).
public struct BoxTilingEngine: Sendable {
    
    public var windowGap: CGFloat
    public var edgeMargins: EdgeMargins
    public var mainPaneRatio: CGFloat
    public var minimumWindowDimension: CGFloat
    
    public init(
        windowGap: CGFloat = 0.0,
        edgeMargins: EdgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0),
        mainPaneRatio: CGFloat = 0.50,
        minimumWindowDimension: CGFloat = 180.0
    ) {
        self.windowGap = windowGap
        self.edgeMargins = edgeMargins
        self.mainPaneRatio = mainPaneRatio
        self.minimumWindowDimension = minimumWindowDimension
    }
    
    // MARK: - Usable Screen Bounds
    
    public func usableBounds(in visibleFrame: CGRect, margins: EdgeMargins? = nil) -> CGRect {
        let m = margins ?? self.edgeMargins
        let x = visibleFrame.origin.x + m.left
        let y = visibleFrame.origin.y + m.top
        let w = max(200.0, visibleFrame.width - m.left - m.right)
        let h = max(100.0, visibleFrame.height - m.top - m.bottom)
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    // MARK: - Box Action Calculations (Rectangle & Loop Parity)
    
    /// Calculates the target CGRect for an action within the screen's visible frame,
    /// respecting gaps, edge margins, and cycle size fractions.
    public func frame(for action: WindowBoxAction, in visibleFrame: CGRect, cycleFraction: CGFloat? = nil) -> CGRect {
        let bounds = usableBounds(in: visibleFrame)
        let gap = windowGap
        
        switch action {
        case .leftHalf:
            let fraction = cycleFraction ?? 0.50
            let w = floor((bounds.width - gap) * fraction)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .rightHalf:
            let fraction = cycleFraction ?? 0.50
            let w = floor((bounds.width - gap) * fraction)
            let x = bounds.origin.x + bounds.width - w
            return CGRect(x: x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .topHalf:
            let fraction = cycleFraction ?? 0.50
            let h = floor((bounds.height - gap) * fraction)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: h)
            
        case .bottomHalf:
            let fraction = cycleFraction ?? 0.50
            let h = floor((bounds.height - gap) * fraction)
            let y = bounds.origin.y + bounds.height - h
            return CGRect(x: bounds.origin.x, y: y, width: bounds.width, height: h)
            
        case .topLeft:
            let w = floor((bounds.width - gap) * 0.50)
            let h = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y, width: w, height: h)
            
        case .topRight:
            let w = floor((bounds.width - gap) * 0.50)
            let h = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.origin.x + bounds.width - w, y: bounds.origin.y, width: w, height: h)
            
        case .bottomLeft:
            let w = floor((bounds.width - gap) * 0.50)
            let h = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y + bounds.height - h, width: w, height: h)
            
        case .bottomRight:
            let w = floor((bounds.width - gap) * 0.50)
            let h = floor((bounds.height - gap) * 0.50)
            return CGRect(x: bounds.origin.x + bounds.width - w, y: bounds.origin.y + bounds.height - h, width: w, height: h)
            
        case .firstThird:
            let w = floor((bounds.width - 2.0 * gap) / 3.0)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .centerThird:
            let w = floor((bounds.width - 2.0 * gap) / 3.0)
            let x = bounds.origin.x + w + gap
            return CGRect(x: x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .lastThird:
            let w = floor((bounds.width - 2.0 * gap) / 3.0)
            let x = bounds.origin.x + bounds.width - w
            return CGRect(x: x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .firstTwoThirds:
            let w = floor(((bounds.width - 2.0 * gap) * (2.0 / 3.0)) + gap)
            return CGRect(x: bounds.origin.x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .lastTwoThirds:
            let w = floor(((bounds.width - 2.0 * gap) * (2.0 / 3.0)) + gap)
            let x = bounds.origin.x + bounds.width - w
            return CGRect(x: x, y: bounds.origin.y, width: w, height: bounds.height)
            
        case .maximize:
            return bounds
            
        case .almostMaximize:
            let padX: CGFloat = max(20.0, bounds.width * 0.05)
            let padY: CGFloat = max(20.0, bounds.height * 0.05)
            return CGRect(
                x: bounds.origin.x + padX,
                y: bounds.origin.y + padY,
                width: max(200.0, bounds.width - (2.0 * padX)),
                height: max(150.0, bounds.height - (2.0 * padY))
            )
            
        case .center:
            let w = min(bounds.width, max(500.0, bounds.width * 0.65))
            let h = min(bounds.height, max(400.0, bounds.height * 0.70))
            let x = bounds.origin.x + (bounds.width - w) / 2.0
            let y = bounds.origin.y + (bounds.height - h) / 2.0
            return CGRect(x: round(x), y: round(y), width: round(w), height: round(h))
            
        case .larger, .smaller, .balance:
            return bounds
        }
    }
    
    // MARK: - Cycle Size Logic (Rectangle Parity)
    
    /// Cycles through fractions: 1/2 -> 2/3 -> 1/3 -> 1/4 -> 3/4 -> 1/2
    public static func nextCycleFraction(after currentFraction: CGFloat) -> CGFloat {
        let presets: [CGFloat] = [0.50, 0.667, 0.333, 0.25, 0.75]
        for (idx, p) in presets.enumerated() {
            if abs(currentFraction - p) < 0.03 {
                let nextIdx = (idx + 1) % presets.count
                return presets[nextIdx]
            }
        }
        return 0.50
    }
    
    // MARK: - Layout Mode 1: Grid / Boxes Tiling (Auto-Tile All Open Windows)
    
    /// Computes frames for all open windows tiled into an optimal NxM box grid.
    public func computeGridLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        let count = windowIds.count
        
        if count == 1 {
            return [windowIds[0]: bounds]
        }
        
        if count == 2 {
            // 2 windows: side-by-side halves
            let gap = windowGap
            let w = floor((bounds.width - gap) * 0.50)
            let f1 = CGRect(x: bounds.origin.x, y: bounds.origin.y, width: w, height: bounds.height)
            let f2 = CGRect(x: bounds.origin.x + w + gap, y: bounds.origin.y, width: bounds.width - w - gap, height: bounds.height)
            return [windowIds[0]: f1, windowIds[1]: f2]
        }
        
        if count == 3 {
            // 3 windows: 1 left half, 2 stacked right quarter boxes
            let gap = windowGap
            let leftW = floor((bounds.width - gap) * 0.50)
            let rightW = bounds.width - leftW - gap
            let rightX = bounds.origin.x + leftW + gap
            let topH = floor((bounds.height - gap) * 0.50)
            let botH = bounds.height - topH - gap
            let botY = bounds.origin.y + topH + gap
            
            return [
                windowIds[0]: CGRect(x: bounds.origin.x, y: bounds.origin.y, width: leftW, height: bounds.height),
                windowIds[1]: CGRect(x: rightX, y: bounds.origin.y, width: rightW, height: topH),
                windowIds[2]: CGRect(x: rightX, y: botY, width: rightW, height: botH)
            ]
        }
        
        let gap = windowGap
        let aspect = bounds.width / max(1.0, bounds.height)
        
        // Pick the column count whose cells come closest to the screen's own aspect ratio.
        // Penalise empty cells so 5 windows tile as 3+2 rather than 3+2 with a hole.
        var cols = 1
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidateCols in 1...count {
            let candidateRows = Int(ceil(Double(count) / Double(candidateCols)))
            let cellWidth = (bounds.width - CGFloat(candidateCols - 1) * gap) / CGFloat(candidateCols)
            let cellHeight = (bounds.height - CGFloat(candidateRows - 1) * gap) / CGFloat(candidateRows)
            let emptyCells = CGFloat(candidateCols * candidateRows - count)
            let score = abs(cellWidth / max(1.0, cellHeight) - aspect) + emptyCells * 0.15
            if score < bestScore {
                bestScore = score
                cols = candidateCols
            }
        }
        let rows = Int(ceil(Double(count) / Double(cols)))
        
        // Split windows evenly across the rows that exist (Amethyst/AeroSpace parity):
        // 5 -> 3+2, 7 -> 3+2+2, 10 -> 4+3+3. Every row fills the full width and no cell is left empty.
        var rowCounts = [Int](repeating: count / rows, count: rows)
        for index in 0..<(count % rows) {
            rowCounts[index] += 1
        }
        
        let rowHeight = floor((bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        var result: [WindowId: CGRect] = [:]
        var windowIndex = 0
        var currentY = bounds.origin.y
        
        for rowIndex in 0..<rows {
            let itemsInRow = rowCounts[rowIndex]
            let itemWidth = floor((bounds.width - CGFloat(itemsInRow - 1) * gap) / CGFloat(itemsInRow))
            var currentX = bounds.origin.x
            
            for columnIndex in 0..<itemsInRow {
                let isLastColumn = columnIndex == itemsInRow - 1
                let isLastRow = rowIndex == rows - 1
                let w = isLastColumn ? max(minimumWindowDimension, bounds.maxX - currentX) : itemWidth
                let h = isLastRow ? max(minimumWindowDimension, bounds.maxY - currentY) : rowHeight
                
                result[windowIds[windowIndex]] = CGRect(
                    x: round(currentX),
                    y: round(currentY),
                    width: round(w),
                    height: round(h)
                )
                
                currentX += w + gap
                windowIndex += 1
            }
            currentY += rowHeight + gap
        }
        
        return result
    }
    
    // MARK: - Layout Mode 5: Row (All Side by Side, Amethyst Parity)
    
    /// Every window shares the screen in a single horizontal row, sized equally.
    public func computeRowLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        let gap = windowGap
        let count = windowIds.count
        
        if count == 1 { return [windowIds[0]: bounds] }
        
        let itemWidth = floor((bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        var result: [WindowId: CGRect] = [:]
        var currentX = bounds.origin.x
        
        for (index, winId) in windowIds.enumerated() {
            let isLast = index == count - 1
            let w = isLast ? max(minimumWindowDimension, bounds.maxX - currentX) : itemWidth
            result[winId] = CGRect(
                x: round(currentX),
                y: round(bounds.origin.y),
                width: round(w),
                height: round(bounds.height)
            )
            currentX += w + gap
        }
        
        return result
    }
    
    // MARK: - Layout Mode 6: Column (All Stacked, Amethyst Parity)
    
    /// Every window is stacked in one vertical column, sized equally.
    public func computeColumnLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        let gap = windowGap
        let count = windowIds.count
        
        if count == 1 { return [windowIds[0]: bounds] }
        
        let itemHeight = floor((bounds.height - CGFloat(count - 1) * gap) / CGFloat(count))
        var result: [WindowId: CGRect] = [:]
        var currentY = bounds.origin.y
        
        for (index, winId) in windowIds.enumerated() {
            let isLast = index == count - 1
            let h = isLast ? max(minimumWindowDimension, bounds.maxY - currentY) : itemHeight
            result[winId] = CGRect(
                x: round(bounds.origin.x),
                y: round(currentY),
                width: round(bounds.width),
                height: round(h)
            )
            currentY += h + gap
        }
        
        return result
    }
    
    // MARK: - Layout Mode 2: Tall Layout (Main + Stack, Amethyst Parity)
    
    /// Computes frames for Tall layout: 1 primary main pane on left, stacked vertical panes on right.
    public func computeTallLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect,
        customRatio: CGFloat? = nil
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        let count = windowIds.count
        
        if count == 1 {
            return [windowIds[0]: bounds]
        }
        
        let gap = windowGap
        let ratio = max(0.20, min(0.80, customRatio ?? mainPaneRatio))
        let mainWidth = floor((bounds.width - gap) * ratio)
        let stackWidth = bounds.width - mainWidth - gap
        let stackX = bounds.origin.x + mainWidth + gap
        
        var result: [WindowId: CGRect] = [:]
        result[windowIds[0]] = CGRect(x: bounds.origin.x, y: bounds.origin.y, width: mainWidth, height: bounds.height)
        
        let stackCount = count - 1
        let totalGaps = CGFloat(stackCount - 1) * gap
        let itemHeight = floor((bounds.height - totalGaps) / CGFloat(stackCount))
        
        var currentY = bounds.origin.y
        for i in 1..<count {
            let winId = windowIds[i]
            let isLast = (i == count - 1)
            let h = isLast ? max(minimumWindowDimension, bounds.maxY - currentY) : itemHeight
            result[winId] = CGRect(x: stackX, y: currentY, width: stackWidth, height: h)
            currentY += h + gap
        }
        
        return result
    }
    
    // MARK: - Layout Mode 3: Wide Layout (Top + Bottom, Amethyst Parity)
    
    /// Computes frames for Wide layout: 1 primary main pane on top, horizontal stacked panes on bottom.
    public func computeWideLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect,
        customRatio: CGFloat? = nil
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        let count = windowIds.count
        
        if count == 1 {
            return [windowIds[0]: bounds]
        }
        
        let gap = windowGap
        let ratio = max(0.20, min(0.80, customRatio ?? mainPaneRatio))
        let mainHeight = floor((bounds.height - gap) * ratio)
        let stackHeight = bounds.height - mainHeight - gap
        let stackY = bounds.origin.y + mainHeight + gap
        
        var result: [WindowId: CGRect] = [:]
        result[windowIds[0]] = CGRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: mainHeight)
        
        let stackCount = count - 1
        let totalGaps = CGFloat(stackCount - 1) * gap
        let itemWidth = floor((bounds.width - totalGaps) / CGFloat(stackCount))
        
        var currentX = bounds.origin.x
        for i in 1..<count {
            let winId = windowIds[i]
            let isLast = (i == count - 1)
            let w = isLast ? max(minimumWindowDimension, bounds.maxX - currentX) : itemWidth
            result[winId] = CGRect(x: currentX, y: stackY, width: w, height: stackHeight)
            currentX += w + gap
        }
        
        return result
    }
    
    // MARK: - Layout Mode 4: Binary Space Partitioning (BSP, AeroSpace/Amethyst Parity)
    
    /// Recursively splits screen rectangles alternating horizontally and vertically based on aspect ratio.
    public func computeBSPLayout(
        windowIds: [WindowId],
        in visibleFrame: CGRect
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty else { return [:] }
        let bounds = usableBounds(in: visibleFrame)
        var result: [WindowId: CGRect] = [:]
        
        func partition(rect: CGRect, ids: ArraySlice<WindowId>) {
            guard !ids.isEmpty else { return }
            if ids.count == 1 {
                result[ids.first!] = CGRect(
                    x: round(rect.origin.x),
                    y: round(rect.origin.y),
                    width: round(rect.width),
                    height: round(rect.height)
                )
                return
            }
            
            let gap = windowGap
            let mid = ids.startIndex + (ids.count / 2)
            let firstHalf = ids[ids.startIndex..<mid]
            let secondHalf = ids[mid..<ids.endIndex]
            
            // Split along longest axis
            if rect.width >= rect.height {
                let w1 = floor((rect.width - gap) * 0.50)
                let w2 = rect.width - w1 - gap
                let r1 = CGRect(x: rect.origin.x, y: rect.origin.y, width: w1, height: rect.height)
                let r2 = CGRect(x: rect.origin.x + w1 + gap, y: rect.origin.y, width: w2, height: rect.height)
                partition(rect: r1, ids: firstHalf)
                partition(rect: r2, ids: secondHalf)
            } else {
                let h1 = floor((rect.height - gap) * 0.50)
                let h2 = rect.height - h1 - gap
                let r1 = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: h1)
                let r2 = CGRect(x: rect.origin.x, y: rect.origin.y + h1 + gap, width: rect.width, height: h2)
                partition(rect: r1, ids: firstHalf)
                partition(rect: r2, ids: secondHalf)
            }
        }
        
        partition(rect: bounds, ids: ArraySlice(windowIds))
        return result
    }
    
    // MARK: - Cooperative Edge & Corner Resizing (Rectangle & AeroSpace Parity)
    
    public enum MovedEdge: Sendable {
        case left, right, top, bottom
    }
    
    public struct CooperativeAdjustment: Equatable, Sendable {
        public let windowId: WindowId
        public let adjustedFrame: CGRect
        
        public init(windowId: WindowId, adjustedFrame: CGRect) {
            self.windowId = windowId
            self.adjustedFrame = adjustedFrame
        }
    }
    
    /// When `resizingWindowId` has its frame changed to `newResizedFrame`,
    /// this function finds all adjacent windows sharing the moved edge and cooperatively adjusts them
    /// so the boundary moves in lockstep with zero gaps or overlaps!
    public func computeCooperativeAdjustments(
        resizingWindowId: WindowId,
        oldFrame: CGRect,
        newFrame: CGRect,
        tiledWindows: [WindowId: CGRect],
        screenBounds: CGRect
    ) -> [CooperativeAdjustment] {
        var adjustments: [CooperativeAdjustment] = []
        let gap = windowGap
        let minDim = minimumWindowDimension
        
        let deltaLeft = newFrame.minX - oldFrame.minX
        let deltaRight = newFrame.maxX - oldFrame.maxX
        let deltaTop = newFrame.minY - oldFrame.minY
        let deltaBottom = newFrame.maxY - oldFrame.maxY
        let isCornerDrag = (abs(deltaLeft) > 0.5 || abs(deltaRight) > 0.5) && (abs(deltaTop) > 0.5 || abs(deltaBottom) > 0.5)
        
        for (otherId, otherFrame) in tiledWindows where otherId != resizingWindowId {
            var adjusted = otherFrame
            var didAdjust = false
            
            let touchesRight = abs(otherFrame.minX - (oldFrame.maxX + gap)) <= 12.0
            let touchesLeft = abs(otherFrame.maxX - (oldFrame.minX - gap)) <= 12.0
            let touchesBottom = abs(otherFrame.minY - (oldFrame.maxY + gap)) <= 12.0
            let touchesTop = abs(otherFrame.maxY - (oldFrame.minY - gap)) <= 12.0
            
            let verticalOverlap = max(0, min(oldFrame.maxY, otherFrame.maxY) - max(oldFrame.minY, otherFrame.minY))
            let horizontalOverlap = max(0, min(oldFrame.maxX, otherFrame.maxX) - max(oldFrame.minX, otherFrame.minX))
            
            // 1. Right edge of resizing window moved -> affects windows whose left edge touches it
            if abs(deltaRight) > 0.5 && touchesRight && verticalOverlap > 10.0 {
                let newOtherMinX = newFrame.maxX + gap
                let newOtherWidth = max(minDim, otherFrame.maxX - newOtherMinX)
                adjusted.origin.x = newOtherMinX
                adjusted.size.width = newOtherWidth
                didAdjust = true
                
                // If this is a 4-way corner drag, also propagate collinear top/bottom seam movement
                if isCornerDrag {
                    if abs(deltaBottom) > 0.5 && abs(otherFrame.maxY - oldFrame.maxY) <= 12.0 {
                        adjusted.size.height = max(minDim, newFrame.maxY - adjusted.origin.y)
                    } else if abs(deltaTop) > 0.5 && abs(otherFrame.minY - oldFrame.minY) <= 12.0 {
                        let newOtherMinY = newFrame.minY
                        adjusted.size.height = max(minDim, otherFrame.maxY - newOtherMinY)
                        adjusted.origin.y = newOtherMinY
                    }
                }
            }
            
            // 2. Left edge of resizing window moved -> affects windows whose right edge touches it
            if abs(deltaLeft) > 0.5 && touchesLeft && verticalOverlap > 10.0 {
                let newOtherMaxX = newFrame.minX - gap
                let newOtherWidth = max(minDim, newOtherMaxX - otherFrame.minX)
                adjusted.size.width = newOtherWidth
                didAdjust = true
                
                if isCornerDrag {
                    if abs(deltaBottom) > 0.5 && abs(otherFrame.maxY - oldFrame.maxY) <= 12.0 {
                        adjusted.size.height = max(minDim, newFrame.maxY - adjusted.origin.y)
                    } else if abs(deltaTop) > 0.5 && abs(otherFrame.minY - oldFrame.minY) <= 12.0 {
                        let newOtherMinY = newFrame.minY
                        adjusted.size.height = max(minDim, otherFrame.maxY - newOtherMinY)
                        adjusted.origin.y = newOtherMinY
                    }
                }
            }
            
            // 3. Bottom edge of resizing window moved -> affects windows whose top edge touches it
            if abs(deltaBottom) > 0.5 && touchesBottom && horizontalOverlap > 10.0 {
                let newOtherMinY = newFrame.maxY + gap
                let newOtherHeight = max(minDim, otherFrame.maxY - newOtherMinY)
                adjusted.origin.y = newOtherMinY
                adjusted.size.height = newOtherHeight
                didAdjust = true
                
                if isCornerDrag {
                    if abs(deltaRight) > 0.5 && abs(otherFrame.maxX - oldFrame.maxX) <= 12.0 {
                        adjusted.size.width = max(minDim, newFrame.maxX - adjusted.origin.x)
                    } else if abs(deltaLeft) > 0.5 && abs(otherFrame.minX - oldFrame.minX) <= 12.0 {
                        let newOtherMinX = newFrame.minX
                        adjusted.size.width = max(minDim, otherFrame.maxX - newOtherMinX)
                        adjusted.origin.x = newOtherMinX
                    }
                }
            }
            
            // 4. Top edge of resizing window moved -> affects windows whose bottom edge touches it
            if abs(deltaTop) > 0.5 && touchesTop && horizontalOverlap > 10.0 {
                let newOtherMaxY = newFrame.minY - gap
                let newOtherHeight = max(minDim, newOtherMaxY - otherFrame.minY)
                adjusted.size.height = newOtherHeight
                didAdjust = true
                
                if isCornerDrag {
                    if abs(deltaRight) > 0.5 && abs(otherFrame.maxX - oldFrame.maxX) <= 12.0 {
                        adjusted.size.width = max(minDim, newFrame.maxX - adjusted.origin.x)
                    } else if abs(deltaLeft) > 0.5 && abs(otherFrame.minX - oldFrame.minX) <= 12.0 {
                        let newOtherMinX = newFrame.minX
                        adjusted.size.width = max(minDim, otherFrame.maxX - newOtherMinX)
                        adjusted.origin.x = newOtherMinX
                    }
                }
            }
            
            // 5. 4-Way Corner Intersection Diagonal Peer (e.g. Bottom-Right pane when Top-Left pane's bottom-right corner is dragged)
            if !didAdjust && isCornerDrag {
                if abs(deltaRight) > 0.5 && abs(deltaBottom) > 0.5 && touchesRight && touchesBottom {
                    let newOtherMinX = newFrame.maxX + gap
                    let newOtherMinY = newFrame.maxY + gap
                    adjusted.origin.x = newOtherMinX
                    adjusted.origin.y = newOtherMinY
                    adjusted.size.width = max(minDim, otherFrame.maxX - newOtherMinX)
                    adjusted.size.height = max(minDim, otherFrame.maxY - newOtherMinY)
                    didAdjust = true
                } else if abs(deltaLeft) > 0.5 && abs(deltaBottom) > 0.5 && touchesLeft && touchesBottom {
                    let newOtherMaxX = newFrame.minX - gap
                    let newOtherMinY = newFrame.maxY + gap
                    adjusted.origin.y = newOtherMinY
                    adjusted.size.width = max(minDim, newOtherMaxX - otherFrame.minX)
                    adjusted.size.height = max(minDim, otherFrame.maxY - newOtherMinY)
                    didAdjust = true
                } else if abs(deltaRight) > 0.5 && abs(deltaTop) > 0.5 && touchesRight && touchesTop {
                    let newOtherMinX = newFrame.maxX + gap
                    let newOtherMaxY = newFrame.minY - gap
                    adjusted.origin.x = newOtherMinX
                    adjusted.size.width = max(minDim, otherFrame.maxX - newOtherMinX)
                    adjusted.size.height = max(minDim, newOtherMaxY - otherFrame.minY)
                    didAdjust = true
                } else if abs(deltaLeft) > 0.5 && abs(deltaTop) > 0.5 && touchesLeft && touchesTop {
                    let newOtherMaxX = newFrame.minX - gap
                    let newOtherMaxY = newFrame.minY - gap
                    adjusted.size.width = max(minDim, newOtherMaxX - otherFrame.minX)
                    adjusted.size.height = max(minDim, newOtherMaxY - otherFrame.minY)
                    didAdjust = true
                }
            }
            
            if didAdjust {
                adjustments.append(CooperativeAdjustment(
                    windowId: otherId,
                    adjustedFrame: CGRect(
                        x: round(adjusted.origin.x),
                        y: round(adjusted.origin.y),
                        width: round(adjusted.size.width),
                        height: round(adjusted.size.height)
                    )
                ))
            }
        }
        
        return adjustments
    }
    
    /// Directly resizes up to 4 panes meeting at a shared 4-way corner intersection point `(ix, iy)`
    /// by `delta = (dx, dy)`, clamping so no touching pane shrinks below `minimumWindowDimension`.
    public func resizeCornerIntersection(
        intersectionPoint: CGPoint,
        delta: CGVector,
        tiledWindows: [WindowId: CGRect],
        screenBounds: CGRect
    ) -> [WindowId: CGRect] {
        let g = windowGap
        let minDim = minimumWindowDimension
        let reach = max(14.0, (g * 0.5) + 12.0)
        
        // Determine clamp bounds across all panes touching this intersection
        var minDX = -CGFloat.greatestFiniteMagnitude
        var maxDX = CGFloat.greatestFiniteMagnitude
        var minDY = -CGFloat.greatestFiniteMagnitude
        var maxDY = CGFloat.greatestFiniteMagnitude
        
        for (_, frame) in tiledWindows {
            let touchesLeftOfIntersection = abs(frame.maxX - intersectionPoint.x) <= reach
            let touchesRightOfIntersection = abs(frame.minX - intersectionPoint.x) <= reach
            let touchesAboveIntersection = abs(frame.maxY - intersectionPoint.y) <= reach
            let touchesBelowIntersection = abs(frame.minY - intersectionPoint.y) <= reach
            
            if touchesLeftOfIntersection && (touchesAboveIntersection || touchesBelowIntersection) {
                minDX = max(minDX, -(frame.width - minDim))
            }
            if touchesRightOfIntersection && (touchesAboveIntersection || touchesBelowIntersection) {
                maxDX = min(maxDX, frame.width - minDim)
            }
            if touchesAboveIntersection && (touchesLeftOfIntersection || touchesRightOfIntersection) {
                minDY = max(minDY, -(frame.height - minDim))
            }
            if touchesBelowIntersection && (touchesLeftOfIntersection || touchesRightOfIntersection) {
                maxDY = min(maxDY, frame.height - minDim)
            }
        }
        
        let appliedDX = min(max(delta.dx, minDX), maxDX)
        let appliedDY = min(max(delta.dy, minDY), maxDY)
        guard abs(appliedDX) > 0.25 || abs(appliedDY) > 0.25 else { return [:] }
        
        var updated: [WindowId: CGRect] = [:]
        for (id, frame) in tiledWindows {
            let touchesLeftOfIntersection = abs(frame.maxX - intersectionPoint.x) <= reach
            let touchesRightOfIntersection = abs(frame.minX - intersectionPoint.x) <= reach
            let touchesAboveIntersection = abs(frame.maxY - intersectionPoint.y) <= reach
            let touchesBelowIntersection = abs(frame.minY - intersectionPoint.y) <= reach
            
            var newFrame = frame
            var changed = false
            
            if touchesLeftOfIntersection && (touchesAboveIntersection || touchesBelowIntersection) {
                newFrame.size.width = max(minDim, frame.width + appliedDX)
                changed = true
            } else if touchesRightOfIntersection && (touchesAboveIntersection || touchesBelowIntersection) {
                newFrame.origin.x = frame.origin.x + appliedDX
                newFrame.size.width = max(minDim, frame.width - appliedDX)
                changed = true
            }
            
            if touchesAboveIntersection && (touchesLeftOfIntersection || touchesRightOfIntersection) {
                newFrame.size.height = max(minDim, frame.height + appliedDY)
                changed = true
            } else if touchesBelowIntersection && (touchesLeftOfIntersection || touchesRightOfIntersection) {
                newFrame.origin.y = frame.origin.y + appliedDY
                newFrame.size.height = max(minDim, frame.height - appliedDY)
                changed = true
            }
            
            if changed {
                updated[id] = rounded(newFrame)
            }
        }
        return updated
    }
    
    // MARK: - Neighbor-Aware Tiled Resize (AeroSpace Parity)
    
    public enum ResizeEdge: String, Equatable, Sendable {
        case left, right, top, bottom
    }
    
    /// Resizes one edge of a tiled window and gives (or takes) the same amount of space from
    /// every neighbour that shares the moved boundary.
    ///
    /// This is the frame-based equivalent of AeroSpace's weight resize: dragging a window edge
    /// never overlaps a neighbour and never leaves an accidental hole, because the windows on
    /// the other side of the seam move and resize in lockstep. Returns only the frames that
    /// actually changed, so callers apply a minimal update.
    public func resizeTiledWindow(
        windowId: WindowId,
        frames: [WindowId: CGRect],
        edge: ResizeEdge,
        delta: CGFloat,
        screenBounds: CGRect,
        gap: CGFloat? = nil,
        minimumDimension: CGFloat? = nil
    ) -> [WindowId: CGRect] {
        guard let focused = frames[windowId], delta != 0 else { return [:] }
        let g = max(0, gap ?? windowGap)
        let minDim = minimumDimension ?? minimumWindowDimension
        let tolerance: CGFloat = 6.0
        
        func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        }
        func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
        
        // Every window whose shared edge sits on the moved boundary participates.
        let affected: [(id: WindowId, frame: CGRect)] = frames.compactMap { id, frame in
            guard id != windowId else { return nil }
            switch edge {
            case .right:
                guard abs(frame.minX - (focused.maxX + g)) <= tolerance,
                      verticalOverlap(focused, frame) > 1 else { return nil }
            case .left:
                guard abs(frame.maxX - (focused.minX - g)) <= tolerance,
                      verticalOverlap(focused, frame) > 1 else { return nil }
            case .bottom:
                guard abs(frame.minY - (focused.maxY + g)) <= tolerance,
                      horizontalOverlap(focused, frame) > 1 else { return nil }
            case .top:
                guard abs(frame.maxY - (focused.minY - g)) <= tolerance,
                      horizontalOverlap(focused, frame) > 1 else { return nil }
            }
            return (id, frame)
        }
        
        // Clamp the movement so no window crosses its minimum size or the screen boundary.
        var lowerBound = -CGFloat.greatestFiniteMagnitude
        var upperBound = CGFloat.greatestFiniteMagnitude
        
        switch edge {
        case .right:
            if affected.isEmpty {
                upperBound = min(upperBound, screenBounds.maxX - focused.maxX)
            } else {
                for neighbour in affected {
                    upperBound = min(upperBound, neighbour.frame.width - minDim)
                }
            }
            lowerBound = max(lowerBound, -(focused.width - minDim))
            for neighbour in affected {
                lowerBound = max(lowerBound, -(neighbour.frame.minX - screenBounds.minX))
            }
            
        case .left:
            upperBound = min(upperBound, focused.width - minDim)
            if affected.isEmpty {
                lowerBound = max(lowerBound, screenBounds.minX - focused.minX)
            } else {
                for neighbour in affected {
                    upperBound = min(upperBound, screenBounds.maxX - neighbour.frame.maxX)
                    lowerBound = max(lowerBound, -(neighbour.frame.width - minDim))
                }
                lowerBound = max(lowerBound, screenBounds.minX - focused.minX)
            }
            
        case .bottom:
            if affected.isEmpty {
                upperBound = min(upperBound, screenBounds.maxY - focused.maxY)
            } else {
                for neighbour in affected {
                    upperBound = min(upperBound, neighbour.frame.height - minDim)
                }
            }
            lowerBound = max(lowerBound, -(focused.height - minDim))
            for neighbour in affected {
                lowerBound = max(lowerBound, -(neighbour.frame.minY - screenBounds.minY))
            }
            
        case .top:
            upperBound = min(upperBound, focused.height - minDim)
            if affected.isEmpty {
                lowerBound = max(lowerBound, screenBounds.minY - focused.minY)
            } else {
                for neighbour in affected {
                    upperBound = min(upperBound, screenBounds.maxY - neighbour.frame.maxY)
                    lowerBound = max(lowerBound, -(neighbour.frame.height - minDim))
                }
                lowerBound = max(lowerBound, screenBounds.minY - focused.minY)
            }
        }
        
        guard upperBound > 0 || lowerBound < 0 else { return [:] }
        let applied = min(max(delta, lowerBound), upperBound)
        guard abs(applied) > 0.5 else { return [:] }
        
        var result: [WindowId: CGRect] = [:]
        var resizedFocused = focused
        
        switch edge {
        case .right:
            resizedFocused.size.width += applied
            for neighbour in affected {
                var frame = neighbour.frame
                frame.origin.x += applied
                frame.size.width -= applied
                result[neighbour.id] = rounded(frame)
            }
        case .left:
            resizedFocused.origin.x += applied
            resizedFocused.size.width -= applied
            for neighbour in affected {
                var frame = neighbour.frame
                frame.size.width += applied
                result[neighbour.id] = rounded(frame)
            }
        case .bottom:
            resizedFocused.size.height += applied
            for neighbour in affected {
                var frame = neighbour.frame
                frame.origin.y += applied
                frame.size.height -= applied
                result[neighbour.id] = rounded(frame)
            }
        case .top:
            resizedFocused.origin.y += applied
            resizedFocused.size.height -= applied
            for neighbour in affected {
                var frame = neighbour.frame
                frame.size.height += applied
                result[neighbour.id] = rounded(frame)
            }
        }
        
        result[windowId] = rounded(resizedFocused)
        return result
    }
    
    private func rounded(_ frame: CGRect) -> CGRect {
        CGRect(
            x: round(frame.origin.x),
            y: round(frame.origin.y),
            width: round(frame.size.width),
            height: round(frame.size.height)
        )
    }
    
    // MARK: - Balance Sizes (AeroSpace & Amethyst Parity)
    
    /// Balances all open window dimensions equally across the screen.
    public func balanceSizes(
        for windowIds: [WindowId],
        in visibleFrame: CGRect,
        currentLayout: LayoutMode
    ) -> [WindowId: CGRect] {
        switch currentLayout {
        case .grid:
            return computeGridLayout(windowIds: windowIds, in: visibleFrame)
        case .tall:
            var balanced = self
            balanced.mainPaneRatio = 0.50
            return balanced.computeTallLayout(windowIds: windowIds, in: visibleFrame)
        case .wide:
            var balanced = self
            balanced.mainPaneRatio = 0.50
            return balanced.computeWideLayout(windowIds: windowIds, in: visibleFrame)
        case .bsp:
            return computeBSPLayout(windowIds: windowIds, in: visibleFrame)
        case .row:
            return computeRowLayout(windowIds: windowIds, in: visibleFrame)
        case .column:
            return computeColumnLayout(windowIds: windowIds, in: visibleFrame)
        default:
            return computeGridLayout(windowIds: windowIds, in: visibleFrame)
        }
    }
    
    // MARK: - Screen Edge & Corner Drag-to-Snap Detection (Rectangle & Loop Parity)
    
    public enum ScreenSnapZone: String, Equatable, Sendable {
        case topMaximize
        case leftHalf
        case rightHalf
        case bottomHalf
        case topLeftQuarter
        case topRightQuarter
        case bottomLeftQuarter
        case bottomRightQuarter
    }
    
    /// Detects whether a mouse drop point is near a screen edge or corner to trigger automatic box snapping.
    public func detectSnapZone(
        cursorPoint: CGPoint,
        screenVisibleFrame: CGRect,
        cornerTriggerRadius: CGFloat = 40.0,
        edgeTriggerDepth: CGFloat = 12.0
    ) -> ScreenSnapZone? {
        let f = screenVisibleFrame
        
        // Corners take precedence
        let nearLeft = cursorPoint.x <= f.minX + cornerTriggerRadius
        let nearRight = cursorPoint.x >= f.maxX - cornerTriggerRadius
        let nearTop = cursorPoint.y <= f.minY + cornerTriggerRadius
        let nearBottom = cursorPoint.y >= f.maxY - cornerTriggerRadius
        
        if nearTop && nearLeft { return .topLeftQuarter }
        if nearTop && nearRight { return .topRightQuarter }
        if nearBottom && nearLeft { return .bottomLeftQuarter }
        if nearBottom && nearRight { return .bottomRightQuarter }
        
        // Edges
        if cursorPoint.y <= f.minY + edgeTriggerDepth { return .topMaximize }
        if cursorPoint.x <= f.minX + edgeTriggerDepth { return .leftHalf }
        if cursorPoint.x >= f.maxX - edgeTriggerDepth { return .rightHalf }
        if cursorPoint.y >= f.maxY - edgeTriggerDepth { return .bottomHalf }
        
        return nil
    }
    
    /// Maps a detected `ScreenSnapZone` to its corresponding `WindowBoxAction`.
    public func boxAction(for zone: ScreenSnapZone) -> WindowBoxAction {
        switch zone {
        case .topMaximize: return .maximize
        case .leftHalf: return .leftHalf
        case .rightHalf: return .rightHalf
        case .bottomHalf: return .bottomHalf
        case .topLeftQuarter: return .topLeft
        case .topRightQuarter: return .topRight
        case .bottomLeftQuarter: return .bottomLeft
        case .bottomRightQuarter: return .bottomRight
        }
    }
    
    /// Computes the live screen footprint preview frame while dragging a window near any screen edge or corner.
    public func liveFootprintPreview(
        cursorPoint: CGPoint,
        screenVisibleFrame: CGRect,
        cornerTriggerRadius: CGFloat = 44.0,
        edgeTriggerDepth: CGFloat = 16.0
    ) -> (zone: ScreenSnapZone, action: WindowBoxAction, targetFrame: CGRect)? {
        guard let zone = detectSnapZone(
            cursorPoint: cursorPoint,
            screenVisibleFrame: screenVisibleFrame,
            cornerTriggerRadius: cornerTriggerRadius,
            edgeTriggerDepth: edgeTriggerDepth
        ) else {
            return nil
        }
        let action = boxAction(for: zone)
        let target = frame(for: action, in: screenVisibleFrame)
        return (zone, action, target)
    }
    
    // MARK: - Priority 1: Loop-Style Radial Menu Direction Picker
    
    public enum RadialDirection: String, CaseIterable, Equatable, Sendable {
        case center = "Center"
        case east = "Right"
        case northEast = "Top-Right"
        case north = "Top"
        case northWest = "Top-Left"
        case west = "Left"
        case southWest = "Bottom-Left"
        case south = "Bottom"
        case southEast = "Bottom-Right"
    }
    
    public enum RadialRing: String, Equatable, Sendable {
        case center
        case inner
        case outer
    }
    
    public struct RadialSelection: Equatable, Sendable {
        public let direction: RadialDirection
        public let ring: RadialRing
        public let action: WindowBoxAction
        public let angleDegrees: Double
        public let distance: CGFloat
        
        public init(
            direction: RadialDirection,
            ring: RadialRing,
            action: WindowBoxAction,
            angleDegrees: Double,
            distance: CGFloat
        ) {
            self.direction = direction
            self.ring = ring
            self.action = action
            self.angleDegrees = angleDegrees
            self.distance = distance
        }
    }
    
    /// Resolves a cursor vector from `origin` to `cursor` into one of 8 compass sectors + center deadzone
    /// and inner/outer rings (modeled after Loop's radial direction picker).
    /// - Parameter yAxisIncreasesUpward: Pass `false` for Quartz coordinates (where `y` grows downward)
    ///   or `true` for AppKit `NSEvent.mouseLocation` coordinates (where `y` grows upward).
    public func resolveRadialSelection(
        origin: CGPoint,
        cursor: CGPoint,
        deadzoneRadius: CGFloat = 18.0,
        outerRingRadius: CGFloat = 68.0,
        yAxisIncreasesUpward: Bool = false
    ) -> RadialSelection {
        let dx = Double(cursor.x - origin.x)
        // Normalize dy so positive is North (Up) and negative is South (Down)
        let dy = yAxisIncreasesUpward ? Double(cursor.y - origin.y) : Double(origin.y - cursor.y)
        let dist = CGFloat(hypot(dx, dy))
        
        if dist < deadzoneRadius {
            return RadialSelection(
                direction: .center,
                ring: .center,
                action: .center,
                angleDegrees: 0.0,
                distance: dist
            )
        }
        
        // Angle in degrees [-180, 180], where 0 = East (Right), +90 = North (Top), -90 = South (Bottom)
        let deg = atan2(dy, dx) * 180.0 / .pi
        let ring: RadialRing = dist >= outerRingRadius ? .outer : .inner
        
        let direction: RadialDirection
        if deg >= -22.5 && deg < 22.5 {
            direction = .east
        } else if deg >= 22.5 && deg < 67.5 {
            direction = .northEast
        } else if deg >= 67.5 && deg < 112.5 {
            direction = .north
        } else if deg >= 112.5 && deg < 157.5 {
            direction = .northWest
        } else if deg >= -67.5 && deg < -22.5 {
            direction = .southEast
        } else if deg >= -112.5 && deg < -67.5 {
            direction = .south
        } else if deg >= -157.5 && deg < -112.5 {
            direction = .southWest
        } else {
            direction = .west
        }
        
        let action: WindowBoxAction
        switch (direction, ring) {
        case (.center, _), (_, .center):
            // Deadzone selections always mean "center the window", whichever sector the
            // cursor was last in before entering the deadzone.
            action = .center
        case (.east, .inner):
            action = .rightHalf
        case (.east, .outer):
            action = .lastThird
        case (.west, .inner):
            action = .leftHalf
        case (.west, .outer):
            action = .firstThird
        case (.north, .inner):
            action = .topHalf
        case (.north, .outer):
            action = .maximize
        case (.south, .inner):
            action = .bottomHalf
        case (.south, .outer):
            action = .centerThird
        case (.northEast, .inner):
            action = .topRight
        case (.northEast, .outer):
            action = .lastTwoThirds
        case (.northWest, .inner):
            action = .topLeft
        case (.northWest, .outer):
            action = .firstTwoThirds
        case (.southEast, _):
            action = .bottomRight
        case (.southWest, _):
            action = .bottomLeft
        }
        
        return RadialSelection(
            direction: direction,
            ring: ring,
            action: action,
            angleDegrees: deg,
            distance: dist
        )
    }
    
    // MARK: - Priority 2: Interactive Custom Box Grid & Freeform Box Selector ("Adjust Any Way I Want")
    
    public struct GridCellCoord: Equatable, Hashable, Codable, Sendable {
        public let col: Int
        public let row: Int
        
        public init(col: Int, row: Int) {
            self.col = col
            self.row = row
        }
    }
    
    /// Computes the exact window frame spanning any rectangular selection of cells `(start...end)`
    /// on an `N × M` custom grid (`columns × rows`), respecting `usableBounds` and `windowGap`.
    public func frameForGridSpan(
        start: GridCellCoord,
        end: GridCellCoord,
        columns: Int,
        rows: Int,
        in visibleFrame: CGRect
    ) -> CGRect {
        let safeCols = max(1, columns)
        let safeRows = max(1, rows)
        let minCol = max(0, min(safeCols - 1, min(start.col, end.col)))
        let maxCol = max(0, min(safeCols - 1, max(start.col, end.col)))
        let minRow = max(0, min(safeRows - 1, min(start.row, end.row)))
        let maxRow = max(0, min(safeRows - 1, max(start.row, end.row)))
        
        let bounds = usableBounds(in: visibleFrame)
        let gap = windowGap
        
        let totalHorizGaps = CGFloat(safeCols - 1) * gap
        let totalVertGaps = CGFloat(safeRows - 1) * gap
        let cellWidth = (bounds.width - totalHorizGaps) / CGFloat(safeCols)
        let cellHeight = (bounds.height - totalVertGaps) / CGFloat(safeRows)
        
        let spanCols = CGFloat(maxCol - minCol + 1)
        let spanRows = CGFloat(maxRow - minRow + 1)
        
        let x = bounds.origin.x + CGFloat(minCol) * (cellWidth + gap)
        let y = bounds.origin.y + CGFloat(minRow) * (cellHeight + gap)
        let w = (maxCol == safeCols - 1)
            ? max(minimumWindowDimension, bounds.maxX - x)
            : max(minimumWindowDimension, spanCols * cellWidth + CGFloat(maxCol - minCol) * gap)
        let h = (maxRow == safeRows - 1)
            ? max(minimumWindowDimension, bounds.maxY - y)
            : max(minimumWindowDimension, spanRows * cellHeight + CGFloat(maxRow - minRow) * gap)
        
        return rounded(CGRect(x: x, y: y, width: w, height: h))
    }
    
    /// Maps a point inside `canvasRect` to its `(col, row)` cell coordinate in an `N × M` grid.
    public func gridCell(
        at point: CGPoint,
        columns: Int,
        rows: Int,
        in canvasRect: CGRect
    ) -> GridCellCoord? {
        guard canvasRect.width > 1, canvasRect.height > 1,
              columns >= 1, rows >= 1,
              canvasRect.contains(point) else {
            return nil
        }
        let relX = (point.x - canvasRect.minX) / canvasRect.width
        let relY = (point.y - canvasRect.minY) / canvasRect.height
        let col = min(columns - 1, max(0, Int(floor(relX * CGFloat(columns)))))
        let row = min(rows - 1, max(0, Int(floor(relY * CGFloat(rows)))))
        return GridCellCoord(col: col, row: row)
    }
    
    /// Converts a normalized `[0, 1]` freeform box rectangle into a screen frame within `usableBounds`.
    /// Optional `snapIncrement` (e.g. `0.05` for 5% steps) snaps normalized coordinates cleanly.
    public func frameForNormalizedBox(
        _ normalizedRect: CGRect,
        in visibleFrame: CGRect,
        snapIncrement: CGFloat? = nil
    ) -> CGRect {
        let bounds = usableBounds(in: visibleFrame)
        
        func snap(_ val: CGFloat) -> CGFloat {
            guard let inc = snapIncrement, inc > 0 else { return val }
            return (val / inc).rounded() * inc
        }
        
        let minXNorm = min(0.95, max(0.0, snap(normalizedRect.minX)))
        let minYNorm = min(0.95, max(0.0, snap(normalizedRect.minY)))
        let maxXNorm = min(1.0, max(minXNorm + 0.05, snap(normalizedRect.maxX)))
        let maxYNorm = min(1.0, max(minYNorm + 0.05, snap(normalizedRect.maxY)))
        
        let x = bounds.origin.x + bounds.width * minXNorm
        let y = bounds.origin.y + bounds.height * minYNorm
        let w = max(minimumWindowDimension, min(bounds.maxX - x, bounds.width * (maxXNorm - minXNorm)))
        let h = max(minimumWindowDimension, min(bounds.maxY - y, bounds.height * (maxYNorm - minYNorm)))
        
        return rounded(CGRect(x: x, y: y, width: w, height: h))
    }
    
    /// Tiles multiple open windows into arbitrary user-defined normalized boxes.
    public func tileWindowsIntoCustomBoxes(
        windowIds: [WindowId],
        normalizedBoxes: [CGRect],
        in visibleFrame: CGRect
    ) -> [WindowId: CGRect] {
        guard !windowIds.isEmpty, !normalizedBoxes.isEmpty else { return [:] }
        var result: [WindowId: CGRect] = [:]
        for (idx, winId) in windowIds.enumerated() {
            let box = normalizedBoxes[idx % normalizedBoxes.count]
            result[winId] = frameForNormalizedBox(box, in: visibleFrame)
        }
        return result
    }
    
    // MARK: - Priority 4: Modifier-Key Cursor Drag Move & Nearest-Quadrant Resize Anywhere
    
    public enum ResizeCorner: String, CaseIterable, Equatable, Sendable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
    
    /// Determines which corner/quadrant of `frame` is closest to `point` (Quartz coordinates).
    public func nearestCorner(to point: CGPoint, in frame: CGRect) -> ResizeCorner {
        let isLeft = point.x < frame.midX
        let isTop = point.y < frame.midY
        switch (isTop, isLeft) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
    
    /// Set of physical edges that a free-resize drag is allowed to move.
    ///
    /// Rectangle and Loop resize on both axes from a corner, while their free-resize / Pro modes let
    /// a drag move a single edge. Modelling the edges explicitly is what makes "resize any way I
    /// want" possible without the window jumping height when the user only meant to change width.
    public struct ResizeEdgeSet: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        
        public static let left = ResizeEdgeSet(rawValue: 1 << 0)
        public static let right = ResizeEdgeSet(rawValue: 1 << 1)
        public static let top = ResizeEdgeSet(rawValue: 1 << 2)
        public static let bottom = ResizeEdgeSet(rawValue: 1 << 3)
        
        public var isHorizontal: Bool { contains(.left) || contains(.right) }
        public var isVertical: Bool { contains(.top) || contains(.bottom) }
    }
    
    /// Decides which window edges a free-resize drag started at `cursor` should move.
    ///
    /// A grab inside the outer band of one axis moves only that edge, a grab near a corner moves
    /// both, and a grab in the dead centre falls back to the nearest corner (Rectangle Pro parity)
    /// so a modifier drag anywhere inside a window always does something predictable.
    public func freeResizeEdges(
        forCursorIn frame: CGRect,
        cursor: CGPoint,
        edgeBandRatio: CGFloat = 0.34
    ) -> ResizeEdgeSet {
        guard frame.width > 0, frame.height > 0 else {
            return [.left, .right, .top, .bottom]
        }
        let ratioX = min(max(0, (cursor.x - frame.minX) / frame.width), 1)
        let ratioY = min(max(0, (cursor.y - frame.minY) / frame.height), 1)
        
        var edges: ResizeEdgeSet = []
        if ratioX <= edgeBandRatio {
            edges.insert(.left)
        } else if ratioX >= 1.0 - edgeBandRatio {
            edges.insert(.right)
        }
        if ratioY <= edgeBandRatio {
            edges.insert(.top)
        } else if ratioY >= 1.0 - edgeBandRatio {
            edges.insert(.bottom)
        }
        
        if edges.isEmpty {
            edges.insert(ratioX < 0.5 ? .left : .right)
            edges.insert(ratioY < 0.5 ? .top : .bottom)
        }
        return edges
    }
    
    /// Computes a free (unconstrained) resize frame for the given edges, anchoring the opposite
    /// edges of `initialFrame` and clamping to the screen. This is the geometry behind the
    /// modifier-chord resize gesture and the box-aware keyboard nudges.
    public func computeFreeResizeFrame(
        initialFrame: CGRect,
        initialCursor: CGPoint,
        currentCursor: CGPoint,
        edges: ResizeEdgeSet? = nil,
        screenBounds: CGRect? = nil
    ) -> (frame: CGRect, edges: ResizeEdgeSet) {
        let active = edges ?? freeResizeEdges(forCursorIn: initialFrame, cursor: initialCursor)
        let dx = currentCursor.x - initialCursor.x
        let dy = currentCursor.y - initialCursor.y
        let minDim = minimumWindowDimension
        
        var minX = initialFrame.minX
        var maxX = initialFrame.maxX
        var minY = initialFrame.minY
        var maxY = initialFrame.maxY
        
        if active.contains(.left) {
            minX = min(maxX - minDim, initialFrame.minX + dx)
        }
        if active.contains(.right) {
            maxX = max(minX + minDim, initialFrame.maxX + dx)
        }
        if active.contains(.top) {
            minY = min(maxY - minDim, initialFrame.minY + dy)
        }
        if active.contains(.bottom) {
            maxY = max(minY + minDim, initialFrame.maxY + dy)
        }
        
        if let bounds = screenBounds {
            minX = max(bounds.minX, min(minX, maxX - minDim))
            minY = max(bounds.minY, min(minY, maxY - minDim))
            maxX = min(bounds.maxX, max(maxX, minX + minDim))
            maxY = min(bounds.maxY, max(maxY, minY + minDim))
        }
        
        let frame = rounded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        return (frame, active)
    }
    
    /// Computes the resized window frame when the user holds the resize modifier chord and drags from
    /// `initialCursor` to `currentCursor` anywhere inside `initialFrame`, anchoring the opposite corner.
    public func computeQuadrantResizeFrame(
        initialFrame: CGRect,
        initialCursor: CGPoint,
        currentCursor: CGPoint,
        screenBounds: CGRect? = nil
    ) -> (frame: CGRect, corner: ResizeCorner) {
        let corner = nearestCorner(to: initialCursor, in: initialFrame)
        let dx = currentCursor.x - initialCursor.x
        let dy = currentCursor.y - initialCursor.y
        let minDim = minimumWindowDimension
        
        var minX = initialFrame.minX
        var maxX = initialFrame.maxX
        var minY = initialFrame.minY
        var maxY = initialFrame.maxY
        
        switch corner {
        case .topLeft:
            minX = min(maxX - minDim, initialFrame.minX + dx)
            minY = min(maxY - minDim, initialFrame.minY + dy)
        case .topRight:
            maxX = max(minX + minDim, initialFrame.maxX + dx)
            minY = min(maxY - minDim, initialFrame.minY + dy)
        case .bottomLeft:
            minX = min(maxX - minDim, initialFrame.minX + dx)
            maxY = max(minY + minDim, initialFrame.maxY + dy)
        case .bottomRight:
            maxX = max(minX + minDim, initialFrame.maxX + dx)
            maxY = max(minY + minDim, initialFrame.maxY + dy)
        }
        
        if let bounds = screenBounds {
            minX = max(bounds.minX, minX)
            minY = max(bounds.minY, minY)
            maxX = min(bounds.maxX, max(minX + minDim, maxX))
            maxY = min(bounds.maxY, max(minY + minDim, maxY))
        }
        
        let updated = rounded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        return (updated, corner)
    }
    
    /// Computes the translated window frame when the user holds the move modifier chord (`⌃⌥` + Left-Drag)
    /// from `initialCursor` to `currentCursor` anywhere inside `initialFrame`.
    public func computeModifierMoveFrame(
        initialFrame: CGRect,
        initialCursor: CGPoint,
        currentCursor: CGPoint,
        screenBounds: CGRect? = nil
    ) -> CGRect {
        let dx = currentCursor.x - initialCursor.x
        let dy = currentCursor.y - initialCursor.y
        var x = initialFrame.origin.x + dx
        var y = initialFrame.origin.y + dy
        if let bounds = screenBounds {
            x = max(bounds.minX, min(bounds.maxX - initialFrame.width, x))
            y = max(bounds.minY, min(bounds.maxY - initialFrame.height, y))
        }
        return rounded(CGRect(x: x, y: y, width: initialFrame.width, height: initialFrame.height))
    }
}

