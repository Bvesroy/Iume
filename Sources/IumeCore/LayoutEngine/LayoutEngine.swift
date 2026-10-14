import Foundation
import CoreGraphics

/// Result of a layout computation containing window target frames and viewport offset.
public struct LayoutComputation: Equatable, Sendable {
    public let targetFrames: [WindowId: CGRect]
    public let totalStripWidth: CGFloat
    public let targetViewportOffset: CGFloat
    public let parkedWindowIds: Set<WindowId>
    
    public init(
        targetFrames: [WindowId: CGRect],
        totalStripWidth: CGFloat,
        targetViewportOffset: CGFloat,
        parkedWindowIds: Set<WindowId> = []
    ) {
        self.targetFrames = targetFrames
        self.totalStripWidth = totalStripWidth
        self.targetViewportOffset = targetViewportOffset
        self.parkedWindowIds = parkedWindowIds
    }
}

/// Pure deterministic layout engine for horizontal scrolling window management.
public struct LayoutEngine: Sendable {
    
    public var windowGap: CGFloat
    public var defaultColumnWidthRatio: CGFloat
    public var defaultMinimumColumnWidth: CGFloat
    public var offScreenPeekSliverWidth: CGFloat
    
    public init(
        windowGap: CGFloat = 12.0,
        defaultColumnWidthRatio: CGFloat = 0.5,
        defaultMinimumColumnWidth: CGFloat = 500.0,
        offScreenPeekSliverWidth: CGFloat = 14.0
    ) {
        self.windowGap = windowGap
        self.defaultColumnWidthRatio = defaultColumnWidthRatio
        self.defaultMinimumColumnWidth = defaultMinimumColumnWidth
        self.offScreenPeekSliverWidth = offScreenPeekSliverWidth
    }
    
    // MARK: - Column Geometry Helpers
    
    /// Computes the X position on the infinite horizontal strip for each column.
    public func columnStripOffsets(columns: [WindowColumn]) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var currentX: CGFloat = 0.0
        for col in columns {
            offsets.append(currentX)
            currentX += col.width + windowGap
        }
        return offsets
    }
    
    /// Computes the total width of the horizontal strip.
    public func totalStripWidth(columns: [WindowColumn]) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let sumWidths = columns.reduce(0) { $0 + $1.width }
        let totalGaps = CGFloat(columns.count - 1) * windowGap
        return sumWidths + totalGaps
    }
    
    // MARK: - Viewport Calculation
    
    /// Computes the ideal viewport offset for the given layout mode and focused column.
    public func computeViewportOffset(
        columns: [WindowColumn],
        focusedColumnIndex: Int?,
        currentViewportOffset: CGFloat,
        visibleWidth: CGFloat,
        layoutMode: LayoutMode
    ) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let totalWidth = self.totalStripWidth(columns: columns)
        let maxAllowedOffset = max(0, totalWidth - visibleWidth)
        
        guard let focusedIdx = focusedColumnIndex, focusedIdx >= 0, focusedIdx < columns.count else {
            return min(max(0, currentViewportOffset), maxAllowedOffset)
        }
        
        let offsets = columnStripOffsets(columns: columns)
        let colLeft = offsets[focusedIdx]
        let colWidth = columns[focusedIdx].width
        let colRight = colLeft + colWidth
        
        switch layoutMode {
        case .scrollStrip:
            // Minimal scrolling: only move if the column is out of visible bounds
            var offset = currentViewportOffset
            if colLeft < currentViewportOffset {
                offset = colLeft
            } else if colRight > currentViewportOffset + visibleWidth {
                offset = colRight - visibleWidth
            }
            return min(max(0, offset), maxAllowedOffset)
            
        case .focusColumn:
            // Snaps focused column to the left edge with a small margin if space allows
            let target = colLeft
            return min(max(0, target), maxAllowedOffset)
            
        case .centeredFocus:
            // Centers the focused column on the display
            let centerTarget = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
            return min(max(0, centerTarget), maxAllowedOffset)
            
        case .manualLayout:
            // Retain user's current offset
            return min(max(0, currentViewportOffset), maxAllowedOffset)
        }
    }
    
    // MARK: - Layout Calculation
    
    /// Computes target frame for each managed window based on columns and viewport offset.
    public func computeLayout(
        columns: [WindowColumn],
        windows: [WindowId: ManagedWindow],
        focusedColumnIndex: Int?,
        visibleFrame: CGRect,
        viewportOffset: CGFloat,
        layoutMode: LayoutMode
    ) -> LayoutComputation {
        var targetFrames: [WindowId: CGRect] = [:]
        guard !columns.isEmpty else {
            return LayoutComputation(targetFrames: [:], totalStripWidth: 0, targetViewportOffset: 0)
        }
        
        let stripOffsets = columnStripOffsets(columns: columns)
        let totalWidth = self.totalStripWidth(columns: columns)
        
        let idealViewportOffset = computeViewportOffset(
            columns: columns,
            focusedColumnIndex: focusedColumnIndex,
            currentViewportOffset: viewportOffset,
            visibleWidth: visibleFrame.width,
            layoutMode: layoutMode
        )
        
        var parkedWindowIds: Set<WindowId> = []
        let minVisibleX = visibleFrame.origin.x
        let maxVisibleX = visibleFrame.origin.x + visibleFrame.width
        let sliver = max(8.0, offScreenPeekSliverWidth)
        
        for (colIndex, column) in columns.enumerated() {
            let colStripX = stripOffsets[colIndex]
            let colScreenX = visibleFrame.origin.x + colStripX - idealViewportOffset
            let colWidth = column.width
            
            let managedInColumn = column.windowIds.compactMap { windows[$0] }.filter { !$0.isFloating && !$0.isMinimized }
            let count = managedInColumn.count
            guard count > 0 else { continue }
            
            // Edge clamping compensation so WindowServer never rejects or shifts windows onto neighboring displays
            var finalScreenX = colScreenX
            var isParked = false
            
            if colScreenX + colWidth <= minVisibleX + sliver {
                // Scrolled completely off the left edge: park with a tiny sliver on the left edge
                finalScreenX = minVisibleX - colWidth + sliver
                isParked = true
            } else if colScreenX >= maxVisibleX - sliver {
                // Scrolled completely off the right edge: park with a tiny sliver on the right edge
                finalScreenX = maxVisibleX - sliver
                isParked = true
            }
            
            let totalVerticalGaps = CGFloat(count - 1) * windowGap
            let availableHeight = max(100, visibleFrame.height - totalVerticalGaps)
            let windowHeight = floor(availableHeight / CGFloat(count))
            
            for (rowIndex, win) in managedInColumn.enumerated() {
                let winScreenY = visibleFrame.origin.y + CGFloat(rowIndex) * (windowHeight + windowGap)
                let frame = CGRect(
                    x: round(finalScreenX),
                    y: round(winScreenY),
                    width: round(colWidth),
                    height: round(windowHeight)
                )
                targetFrames[win.id] = frame
                if isParked {
                    parkedWindowIds.insert(win.id)
                }
            }
        }
        
        return LayoutComputation(
            targetFrames: targetFrames,
            totalStripWidth: totalWidth,
            targetViewportOffset: idealViewportOffset,
            parkedWindowIds: parkedWindowIds
        )
    }
    
    // MARK: - Column Mutations
    
    /// Inserts a new window according to the specified insertion policy.
    public func insertWindow(
        _ windowId: WindowId,
        into columns: inout [WindowColumn],
        focusedColumnIndex: Int?,
        policy: InsertionPolicy,
        preferredWidth: CGFloat? = nil,
        visibleWidth: CGFloat
    ) -> Int {
        let width = preferredWidth ?? max(defaultMinimumColumnWidth, visibleWidth * defaultColumnWidthRatio)
        
        switch policy {
        case .afterFocused:
            if let focusedIdx = focusedColumnIndex, focusedIdx >= 0, focusedIdx < columns.count {
                let insertIdx = focusedIdx + 1
                columns.insert(WindowColumn(windowIds: [windowId], width: width), at: insertIdx)
                return insertIdx
            } else {
                columns.append(WindowColumn(windowIds: [windowId], width: width))
                return columns.count - 1
            }
            
        case .atEnd:
            columns.append(WindowColumn(windowIds: [windowId], width: width))
            return columns.count - 1
            
        case .inCurrentColumn:
            if let focusedIdx = focusedColumnIndex, focusedIdx >= 0, focusedIdx < columns.count {
                columns[focusedIdx].windowIds.append(windowId)
                return focusedIdx
            } else {
                columns.append(WindowColumn(windowIds: [windowId], width: width))
                return columns.count - 1
            }
        }
    }
    
    /// Removes a window from columns, cleaning up empty columns. Returns new focused index.
    public func removeWindow(
        _ windowId: WindowId,
        from columns: inout [WindowColumn],
        currentFocusedIndex: Int?
    ) -> Int? {
        var targetColIndex: Int? = nil
        
        for (idx, col) in columns.enumerated() {
            if let winIdx = col.windowIds.firstIndex(of: windowId) {
                columns[idx].windowIds.remove(at: winIdx)
                targetColIndex = idx
                break
            }
        }
        
        // Remove columns that have become empty
        columns.removeAll { $0.windowIds.isEmpty }
        
        guard !columns.isEmpty else { return nil }
        
        if let focused = currentFocusedIndex {
            if focused >= columns.count {
                return columns.count - 1
            }
            return focused
        } else if let target = targetColIndex {
            return min(target, columns.count - 1)
        }
        
        return 0
    }
    
    /// Moves a column left or right in the sequence. Returns new index.
    public func moveColumn(
        at index: Int,
        direction: Int,
        columns: inout [WindowColumn]
    ) -> Int {
        let newIndex = index + direction
        guard index >= 0, index < columns.count, newIndex >= 0, newIndex < columns.count else {
            return index
        }
        let col = columns.remove(at: index)
        columns.insert(col, at: newIndex)
        return newIndex
    }
    
    // MARK: - Column Sizing & Alignment
    
    /// Finds the index of the column that best aligns with or is centered at the given viewport offset.
    public func findClosestColumnIndex(
        for viewportOffset: CGFloat,
        columns: [WindowColumn],
        visibleWidth: CGFloat
    ) -> Int {
        guard !columns.isEmpty else { return 0 }
        let offsets = columnStripOffsets(columns: columns)
        
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        
        for (i, colLeft) in offsets.enumerated() {
            let col = columns[i]
            // Center-to-center distance or left-to-left distance
            let colCenter = colLeft + (col.width / 2.0)
            let viewportCenter = viewportOffset + (visibleWidth / 2.0)
            let dist = abs(colCenter - viewportCenter)
            
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
            }
        }
        return bestIndex
    }
    
    /// Cycles the width of the column through standard presets: 33%, 50%, 66%, 75%, 100%.
    @discardableResult
    public func cycleColumnWidth(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        let currentWidth = columns[index].width
        let currentRatio = currentWidth / visibleWidth
        
        let ratios: [CGFloat] = [0.333, 0.50, 0.667, 0.75, 1.0]
        // Find next ratio
        var nextRatio = ratios[0]
        for r in ratios {
            if r > currentRatio + 0.04 {
                nextRatio = r
                break
            }
        }
        
        let newWidth = max(defaultMinimumColumnWidth, round(visibleWidth * nextRatio))
        columns[index].width = newWidth
        return newWidth
    }
    
    /// Computes the viewport offset required to center the specified column on screen.
    public func centerColumnOffset(
        at index: Int,
        columns: [WindowColumn],
        visibleWidth: CGFloat
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        let offsets = columnStripOffsets(columns: columns)
        let colLeft = offsets[index]
        let colWidth = columns[index].width
        let totalWidth = totalStripWidth(columns: columns)
        let maxAllowedOffset = max(0, totalWidth - visibleWidth)
        
        let centerTarget = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
        return min(max(0, centerTarget), maxAllowedOffset)
    }
    
    /// Maximizes the specified column to fill the entire visible width.
    public func maximizeColumn(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) {
        guard index >= 0, index < columns.count else { return }
        columns[index].width = visibleWidth
    }
}

