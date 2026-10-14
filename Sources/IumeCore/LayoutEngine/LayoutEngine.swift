import Foundation
import CoreGraphics

/// Result of a layout computation containing window target frames and viewport offset.
public struct LayoutComputation: Equatable, Sendable {
    public let targetFrames: [WindowId: CGRect]
    public let totalStripWidth: CGFloat
    public let targetViewportOffset: CGFloat
    
    public init(targetFrames: [WindowId: CGRect], totalStripWidth: CGFloat, targetViewportOffset: CGFloat) {
        self.targetFrames = targetFrames
        self.totalStripWidth = totalStripWidth
        self.targetViewportOffset = targetViewportOffset
    }
}

/// Pure deterministic layout engine for horizontal scrolling window management.
public struct LayoutEngine: Sendable {
    
    public var windowGap: CGFloat
    public var defaultColumnWidthRatio: CGFloat
    public var defaultMinimumColumnWidth: CGFloat
    
    public init(
        windowGap: CGFloat = 12.0,
        defaultColumnWidthRatio: CGFloat = 0.5,
        defaultMinimumColumnWidth: CGFloat = 500.0
    ) {
        self.windowGap = windowGap
        self.defaultColumnWidthRatio = defaultColumnWidthRatio
        self.defaultMinimumColumnWidth = defaultMinimumColumnWidth
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
        
        for (colIndex, column) in columns.enumerated() {
            let colStripX = stripOffsets[colIndex]
            let colScreenX = visibleFrame.origin.x + colStripX - idealViewportOffset
            let colWidth = column.width
            
            let managedInColumn = column.windowIds.compactMap { windows[$0] }.filter { !$0.isFloating && !$0.isMinimized }
            let count = managedInColumn.count
            guard count > 0 else { continue }
            
            let totalVerticalGaps = CGFloat(count - 1) * windowGap
            let availableHeight = max(100, visibleFrame.height - totalVerticalGaps)
            let windowHeight = floor(availableHeight / CGFloat(count))
            
            for (rowIndex, win) in managedInColumn.enumerated() {
                let winScreenY = visibleFrame.origin.y + CGFloat(rowIndex) * (windowHeight + windowGap)
                let frame = CGRect(
                    x: colScreenX,
                    y: winScreenY,
                    width: colWidth,
                    height: windowHeight
                )
                targetFrames[win.id] = frame
            }
        }
        
        return LayoutComputation(
            targetFrames: targetFrames,
            totalStripWidth: totalWidth,
            targetViewportOffset: idealViewportOffset
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
}
