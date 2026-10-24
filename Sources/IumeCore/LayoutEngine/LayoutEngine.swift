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

/// On-screen geometry for one strip column, shared by the layout and tab bar.
public struct ColumnScreenFrame: Equatable, Sendable {
    public let columnId: UUID
    public let frame: CGRect
    /// True when the column is parked against a screen edge.
    public let isParked: Bool
    
    public init(columnId: UUID, frame: CGRect, isParked: Bool) {
        self.columnId = columnId
        self.frame = frame
        self.isParked = isParked
    }
}

/// Pure deterministic layout engine for horizontal scrolling window management.
public struct LayoutEngine: Sendable {
    
    public var windowGap: CGFloat
    public var edgeMargins: EdgeMargins
    public var defaultColumnWidthRatio: CGFloat
    public var defaultMinimumColumnWidth: CGFloat
    public var offScreenPeekSliverWidth: CGFloat
    public var centerMode: CenterMode
    
    public init(
        windowGap: CGFloat = 0.0,
        edgeMargins: EdgeMargins = EdgeMargins(top: 0, bottom: 0, left: 0, right: 0),
        defaultColumnWidthRatio: CGFloat = 0.50,
        defaultMinimumColumnWidth: CGFloat = 380.0,
        offScreenPeekSliverWidth: CGFloat = 12.0,
        centerMode: CenterMode = .never
    ) {
        self.windowGap = windowGap
        self.edgeMargins = edgeMargins
        self.defaultColumnWidthRatio = defaultColumnWidthRatio
        self.defaultMinimumColumnWidth = defaultMinimumColumnWidth
        self.offScreenPeekSliverWidth = offScreenPeekSliverWidth
        self.centerMode = centerMode
    }
    
    // MARK: - Column Geometry Helpers
    
    /// Computes the X position on the infinite horizontal strip for each column.
    public func columnStripOffsets(columns: [WindowColumn], gap: CGFloat? = nil) -> [CGFloat] {
        var offsets: [CGFloat] = []
        var currentX: CGFloat = 0.0
        let effectiveGap = gap ?? windowGap
        for col in columns {
            offsets.append(currentX)
            currentX += col.width + effectiveGap
        }
        return offsets
    }
    
    /// Computes the total width of the horizontal strip.
    public func totalStripWidth(columns: [WindowColumn], gap: CGFloat? = nil) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let effectiveGap = gap ?? windowGap
        let sumWidths = columns.reduce(0) { $0 + $1.width }
        let totalGaps = CGFloat(columns.count - 1) * effectiveGap
        return sumWidths + totalGaps
    }
    
    /// Computes the maximum allowed viewport offset for the strip, accommodating full column centering for .always and .onOverflow.
    public func maxScrollOffset(
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        centerMode: CenterMode? = nil,
        gap: CGFloat? = nil
    ) -> CGFloat {
        guard columns.count > 1 else { return 0 }
        let effectiveGap = gap ?? windowGap
        let totalWidth = self.totalStripWidth(columns: columns, gap: effectiveGap)
        let baseMax = max(0, totalWidth - visibleWidth)
        let effectiveCenterMode = centerMode ?? self.centerMode
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        let lastOffset = offsets.last ?? 0
        let lastCol = columns.last
        let lastCenter = lastCol != nil ? (lastOffset + (lastCol!.width / 2.0) - (visibleWidth / 2.0)) : 0
        
        switch effectiveCenterMode {
        case .always:
            return max(baseMax, max(0, lastCenter))
        case .onOverflow:
            if totalWidth > visibleWidth {
                return max(baseMax, max(0, lastCenter))
            } else {
                return baseMax
            }
        case .never:
            return baseMax
        }
    }
    
    /// Computes the cyclic strip period: sum of all column widths plus gaps between each column (including gap between last and first).
    public func cyclicStripPeriod(columns: [WindowColumn], gap: CGFloat? = nil) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let effectiveGap = gap ?? windowGap
        let sumWidths = columns.reduce(0) { $0 + $1.width }
        let totalGaps = CGFloat(columns.count) * effectiveGap
        return sumWidths + totalGaps
    }
    
    // MARK: - Viewport Calculation
    
    /// Computes the ideal viewport offset for the given layout mode, center mode, and focused column.
    public func computeViewportOffset(
        columns: [WindowColumn],
        focusedColumnIndex: Int?,
        currentViewportOffset: CGFloat,
        visibleWidth: CGFloat,
        layoutMode: LayoutMode,
        centerMode: CenterMode? = nil,
        gap: CGFloat? = nil,
        loopMode: Bool = false
    ) -> CGFloat {
        guard !columns.isEmpty else { return 0 }
        let effectiveGap = gap ?? windowGap
        let totalWidth = self.totalStripWidth(columns: columns, gap: effectiveGap)
        let effectiveCenterMode = centerMode ?? self.centerMode
        let period = self.cyclicStripPeriod(columns: columns, gap: effectiveGap)
        // Loop only applies to strip modes, and only once one full cycle spans the viewport
        // (period >= visibleWidth, i.e. the columns plus the closing gap fill the screen).
        // Narrower strips stay clamped and never wrap.
        let canLoop = loopMode && layoutMode.supportsLoop && columns.count >= 2 && period > 0 && period >= visibleWidth
        let maxAllowedOffset = canLoop ? CGFloat.greatestFiniteMagnitude : maxScrollOffset(columns: columns, visibleWidth: visibleWidth, centerMode: effectiveCenterMode, gap: effectiveGap)
        
        guard let focusedIdx = focusedColumnIndex, focusedIdx >= 0, focusedIdx < columns.count else {
            return canLoop ? currentViewportOffset : min(max(0, currentViewportOffset), maxAllowedOffset)
        }
        
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        let colLeft = offsets[focusedIdx]
        let colWidth = columns[focusedIdx].width
        let colRight = colLeft + colWidth
        
        if canLoop {
            let targetBase: CGFloat
            switch layoutMode {
            case .scrollStrip:
                switch effectiveCenterMode {
                case .always, .onOverflow:
                    targetBase = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
                case .never:
                    targetBase = colLeft
                }
            case .focusColumn:
                targetBase = colLeft
            case .centeredFocus:
                targetBase = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
            case .manualLayout:
                return currentViewportOffset
            case .grid, .tall, .wide, .bsp, .row, .column:
                return 0.0
            }
            
            // Find minimum circular delta from currentViewportOffset to targetBase
            let rawDelta = targetBase - currentViewportOffset
            let wrappedDelta = rawDelta - period * (rawDelta / period).rounded()
            return currentViewportOffset + wrappedDelta
        }
        
        switch layoutMode {
        case .scrollStrip:
            switch effectiveCenterMode {
            case .always:
                let centerTarget = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
                return min(max(0, centerTarget), maxAllowedOffset)
            case .onOverflow:
                if totalWidth <= visibleWidth {
                    var offset = currentViewportOffset
                    if colLeft < currentViewportOffset {
                        offset = colLeft
                    } else if colRight > currentViewportOffset + visibleWidth {
                        offset = colRight - visibleWidth
                    }
                    return min(max(0, offset), maxAllowedOffset)
                } else {
                    let centerTarget = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
                    return min(max(0, centerTarget), maxAllowedOffset)
                }
            case .never:
                var offset = currentViewportOffset
                if colLeft < currentViewportOffset {
                    offset = colLeft
                } else if colRight > currentViewportOffset + visibleWidth {
                    if colWidth > visibleWidth {
                        offset = colLeft
                    } else {
                        offset = colRight - visibleWidth
                    }
                }
                return min(max(0, offset), maxAllowedOffset)
            }
            
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
            
        case .grid, .tall, .wide, .bsp, .row, .column:
            // All open windows fit directly on the visible display
            return 0.0
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
        layoutMode: LayoutMode,
        centerMode: CenterMode? = nil,
        edgeMargins: EdgeMargins? = nil,
        gap: CGFloat? = nil,
        isBuiltinDisplay: Bool = false,
        disablePaddingOnBuiltinDisplay: Bool = false,
        smartWindowMargins: Bool = false,
        loopMode: Bool = false,
        manualFrames: [WindowId: CGRect] = [:],
        customBoxFrames: [WindowId: CGRect] = [:]
    ) -> LayoutComputation {
        var targetFrames: [WindowId: CGRect] = [:]
        guard !columns.isEmpty else {
            return LayoutComputation(targetFrames: [:], totalStripWidth: 0, targetViewportOffset: 0)
        }
        
        let totalManagedWindows = columns.reduce(0) { $0 + $1.windowIds.count }
        let shouldCollapseMargins = (smartWindowMargins && totalManagedWindows <= 1) || (disablePaddingOnBuiltinDisplay && isBuiltinDisplay)
        let margins = shouldCollapseMargins ? EdgeMargins.zero : (edgeMargins ?? self.edgeMargins)
        let effectiveGap = (smartWindowMargins && totalManagedWindows <= 1) ? 0.0 : (gap ?? self.windowGap)
        
        let usableWidth = max(200, visibleFrame.width - margins.left - margins.right)
        let usableHeight = max(100, visibleFrame.height - margins.top - margins.bottom)
        
        // Manual / Free Layout: every window keeps the exact frame the user gave it.
        // Windows without a stored frame inherit their current physical frame, so switching
        // into the mode never makes anything jump.
        if layoutMode == .manualLayout {
            var frames: [WindowId: CGRect] = [:]
            for column in columns {
                for winId in column.windowIds {
                    guard let win = windows[winId], !win.isFloating, !win.isMinimized else { continue }
                    frames[winId] = customBoxFrames[winId] ?? manualFrames[winId] ?? win.frame
                }
            }
            return LayoutComputation(
                targetFrames: frames,
                totalStripWidth: usableWidth,
                targetViewportOffset: 0.0,
                parkedWindowIds: []
            )
        }
        
        // Handle Box Tiling Modes: Grid, Tall, Wide, BSP, Row, Column
        if layoutMode == .grid || layoutMode == .tall || layoutMode == .wide || layoutMode == .bsp
            || layoutMode == .row || layoutMode == .column {
            var openWindowIds: [WindowId] = []
            for col in columns {
                for winId in col.windowIds {
                    if let win = windows[winId], !win.isFloating, !win.isMinimized {
                        openWindowIds.append(winId)
                    }
                }
            }
            let boxEngine = BoxTilingEngine(
                windowGap: effectiveGap,
                edgeMargins: margins
            )
            var frames: [WindowId: CGRect]
            switch layoutMode {
            case .grid:
                frames = boxEngine.computeGridLayout(windowIds: openWindowIds, in: visibleFrame)
            case .tall:
                frames = boxEngine.computeTallLayout(windowIds: openWindowIds, in: visibleFrame)
            case .wide:
                frames = boxEngine.computeWideLayout(windowIds: openWindowIds, in: visibleFrame)
            case .bsp:
                frames = boxEngine.computeBSPLayout(windowIds: openWindowIds, in: visibleFrame)
            case .row:
                frames = boxEngine.computeRowLayout(windowIds: openWindowIds, in: visibleFrame)
            case .column:
                frames = boxEngine.computeColumnLayout(windowIds: openWindowIds, in: visibleFrame)
            default:
                frames = [:]
            }
            // Apply persistent per-window custom box overrides that survive workspace reflows
            for (winId, customFrame) in customBoxFrames where frames[winId] != nil {
                frames[winId] = customFrame
            }
            return LayoutComputation(
                targetFrames: frames,
                totalStripWidth: usableWidth,
                targetViewportOffset: 0.0,
                parkedWindowIds: []
            )
        }
        
        let totalWidth = self.totalStripWidth(columns: columns, gap: effectiveGap)
        let effectiveCenterMode = centerMode ?? self.centerMode
        let period = self.cyclicStripPeriod(columns: columns, gap: effectiveGap)
        let canLoop = loopMode && layoutMode.supportsLoop && columns.count >= 2 && period > 0 && period >= usableWidth
        
        let idealViewportOffset = computeViewportOffset(
            columns: columns,
            focusedColumnIndex: focusedColumnIndex,
            currentViewportOffset: viewportOffset,
            visibleWidth: usableWidth,
            layoutMode: layoutMode,
            centerMode: effectiveCenterMode,
            gap: effectiveGap,
            loopMode: loopMode
        )
        
        var parkedWindowIds: Set<WindowId> = []
        let minVisibleX = visibleFrame.origin.x + margins.left
        let maxVisibleX = minVisibleX + usableWidth
        let baseOriginY = visibleFrame.origin.y + margins.top
        let screenCenter = minVisibleX + (usableWidth / 2.0)
        
        var activeStripX: CGFloat = 0.0
        for column in columns {
            // Every column occupies its width in the strip, even when it currently has no
            // managed (visible) windows. Keeping the cursor aligned with columnStripOffsets
            // and cyclicStripPeriod is what makes loop wrapping and focus targets consistent.
            let colStripX = activeStripX
            let colWidth = column.width
            activeStripX += colWidth + effectiveGap
            
            let managedInColumn = column.windowIds.compactMap { windows[$0] }.filter { !$0.isFloating && !$0.isMinimized }
            let count = managedInColumn.count
            guard count > 0 else { continue }
            
            let colScreenX: CGFloat
            if canLoop {
                let nominalScreenX = minVisibleX + colStripX - viewportOffset
                let nominalCenter = nominalScreenX + (colWidth / 2.0)
                let delta = nominalCenter - screenCenter
                let wrappedDelta = delta - period * (delta / period).rounded()
                let wrappedCenter = screenCenter + wrappedDelta
                colScreenX = wrappedCenter - (colWidth / 2.0)
            } else {
                colScreenX = minVisibleX + colStripX - viewportOffset
            }
            
            let sliver = max(1.0, offScreenPeekSliverWidth)
            var finalScreenX = colScreenX
            var isParked = false
            
            if colScreenX + colWidth <= minVisibleX + sliver {
                finalScreenX = minVisibleX - colWidth + sliver
                isParked = true
            } else if colScreenX >= maxVisibleX - max(35.0, sliver) {
                finalScreenX = maxVisibleX - sliver
                isParked = true
            }
            
            if column.presentationMode == .tabbed {
                let tabContentY = baseOriginY + PureStripLayoutEngine.tabBarHeight
                let tabContentHeight = max(100, usableHeight - PureStripLayoutEngine.tabBarHeight)
                for (idx, win) in managedInColumn.enumerated() {
                    let isCurrentTab = (idx == column.activeWindowIndex)
                    let screenX = isCurrentTab ? round(finalScreenX) : (minVisibleX - colWidth + sliver)
                    let frame = CGRect(
                        x: screenX,
                        y: round(tabContentY),
                        width: round(colWidth),
                        height: round(tabContentHeight)
                    )
                    targetFrames[win.id] = frame
                    if isParked || !isCurrentTab {
                        parkedWindowIds.insert(win.id)
                    }
                }
            } else {
                let totalVerticalGaps = CGFloat(count - 1) * effectiveGap
                let availableHeight = max(100, usableHeight - totalVerticalGaps)
                let entries = column.windowEntries
                let sumRatios = max(0.01, entries.filter { e in managedInColumn.contains(where: { $0.id == e.id }) }.reduce(0) { $0 + $1.heightRatio })
                
                var currentY = baseOriginY
                for (rowIndex, win) in managedInColumn.enumerated() {
                    let entryRatio = entries.first(where: { $0.id == win.id })?.heightRatio ?? (1.0 / CGFloat(count))
                    let proportionalHeight = floor(availableHeight * (entryRatio / sumRatios))
                    let h = (rowIndex == count - 1)
                        ? max(100, (baseOriginY + usableHeight) - currentY)
                        : max(100, proportionalHeight)
                    let frame = CGRect(
                        x: round(finalScreenX),
                        y: round(currentY),
                        width: round(colWidth),
                        height: round(h)
                    )
                    targetFrames[win.id] = frame
                    if isParked {
                        parkedWindowIds.insert(win.id)
                    }
                    currentY += h + effectiveGap
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
        let usableW = max(200, visibleWidth - edgeMargins.left - edgeMargins.right)
        let halfScreenWidth = floor((usableW - windowGap) * defaultColumnWidthRatio)
        let width = preferredWidth ?? max(defaultMinimumColumnWidth, halfScreenWidth)
        
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
        visibleWidth: CGFloat,
        gap: CGFloat? = nil,
        loopMode: Bool = false
    ) -> Int {
        guard !columns.isEmpty else { return 0 }
        let effectiveGap = gap ?? windowGap
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        
        if loopMode && columns.count >= 2 {
            let period = cyclicStripPeriod(columns: columns, gap: effectiveGap)
            if period > 0 && period >= visibleWidth {
                var bestIndex = 0
                var bestDistance = CGFloat.greatestFiniteMagnitude
                let viewportCenter = viewportOffset + (visibleWidth / 2.0)
                
                for (i, colLeft) in offsets.enumerated() {
                    let col = columns[i]
                    let colCenter = colLeft + (col.width / 2.0)
                    let rawDist = colCenter - viewportCenter
                    let circDist = abs(rawDist - period * (rawDist / period).rounded())
                    if circDist < bestDistance {
                        bestDistance = circDist
                        bestIndex = i
                    }
                }
                return bestIndex
            }
        }
        
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        let viewportCenter = viewportOffset + (visibleWidth / 2.0)
        
        for (i, colLeft) in offsets.enumerated() {
            let col = columns[i]
            // Center-to-center distance or left-to-left distance
            let colCenter = colLeft + (col.width / 2.0)
            let dist = abs(colCenter - viewportCenter)
            
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i
            }
        }
        return bestIndex
    }
    
    /// Result of an edge snapping computation containing target viewport offset and focused column.
    public struct SnapTarget: Equatable, Sendable {
        public let targetOffset: CGFloat
        public let focusedColumnIndex: Int
        
        public init(targetOffset: CGFloat, focusedColumnIndex: Int) {
            self.targetOffset = targetOffset
            self.focusedColumnIndex = focusedColumnIndex
        }
    }
    
    /// Computes the optimal snap target viewport offset and prominent column, taking into account
    /// natural column edge alignments, center modes, and user gesture momentum / flick direction.
    public func computeSnapTarget(
        for projectedOffset: CGFloat,
        velocity: CGFloat = 0.0,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        centerMode: CenterMode? = nil,
        gap: CGFloat? = nil,
        loopMode: Bool = false
    ) -> SnapTarget {
        guard columns.count > 1 else {
            return SnapTarget(targetOffset: 0, focusedColumnIndex: 0)
        }
        
        let effectiveGap = gap ?? self.windowGap
        let effectiveCenterMode = centerMode ?? self.centerMode
        let period = cyclicStripPeriod(columns: columns, gap: effectiveGap)
        let canLoop = loopMode && columns.count >= 2 && period > 0 && period >= visibleWidth
        
        if canLoop {
            let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
            var baseCandidates: [CGFloat] = []
            for (i, col) in columns.enumerated() {
                switch effectiveCenterMode {
                case .always, .onOverflow:
                    baseCandidates.append(offsets[i] + (col.width / 2.0) - (visibleWidth / 2.0))
                case .never:
                    baseCandidates.append(offsets[i])
                }
            }
            
            // Map each column's snap candidate to the integer cycle closest to projectedOffset
            var nearCandidates: [(offset: CGFloat, colIdx: Int)] = []
            for (i, base) in baseCandidates.enumerated() {
                let diff = base - projectedOffset
                let wrappedDiff = diff - period * (diff / period).rounded()
                nearCandidates.append((projectedOffset + wrappedDiff, i))
            }
            
            nearCandidates.sort { $0.offset < $1.offset }
            
            let chosen: (offset: CGFloat, colIdx: Int)
            if velocity > 100.0 {
                let forward = nearCandidates.filter { $0.offset > projectedOffset - 15.0 }
                chosen = forward.first(where: { $0.offset > projectedOffset }) ?? forward.first ?? nearCandidates.first!
            } else if velocity < -100.0 {
                let backward = nearCandidates.filter { $0.offset < projectedOffset + 15.0 }
                chosen = backward.last(where: { $0.offset < projectedOffset }) ?? backward.last ?? nearCandidates.last!
            } else {
                chosen = nearCandidates.min(by: { abs($0.offset - projectedOffset) < abs($1.offset - projectedOffset) }) ?? nearCandidates.first!
            }
            
            return SnapTarget(targetOffset: chosen.offset, focusedColumnIndex: chosen.colIdx)
        }
        
        let totalWidth = self.totalStripWidth(columns: columns, gap: effectiveGap)
        let maxAllowed = maxScrollOffset(columns: columns, visibleWidth: visibleWidth, centerMode: effectiveCenterMode, gap: effectiveGap)
        
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        var candidates: [CGFloat] = [0.0, maxAllowed]
        
        switch effectiveCenterMode {
        case .always:
            for (i, col) in columns.enumerated() {
                let centerTarget = offsets[i] + (col.width / 2.0) - (visibleWidth / 2.0)
                candidates.append(min(max(0, centerTarget), maxAllowed))
            }
        case .onOverflow:
            if totalWidth <= visibleWidth {
                for (i, _) in columns.enumerated() {
                    candidates.append(min(max(0, offsets[i]), maxAllowed))
                }
            } else {
                for (i, col) in columns.enumerated() {
                    let centerTarget = offsets[i] + (col.width / 2.0) - (visibleWidth / 2.0)
                    candidates.append(min(max(0, centerTarget), maxAllowed))
                }
                candidates.append(min(max(0, totalWidth - visibleWidth), maxAllowed))
            }
        case .never:
            for (i, col) in columns.enumerated() {
                // Left-edge snap: aligns column to visible left edge
                candidates.append(min(max(0, offsets[i]), maxAllowed))
                
                // Right-edge snap: ONLY if column is wider than the visible screen
                if col.width > visibleWidth {
                    let rightSnap = offsets[i] + col.width - visibleWidth
                    candidates.append(min(max(0, rightSnap), maxAllowed))
                }
            }
            if totalWidth > visibleWidth {
                candidates.append(min(max(0, totalWidth - visibleWidth), maxAllowed))
            }
        }
        
        // Deduplicate and sort candidates
        let sortedCandidates = Array(Set(candidates.map { round($0 * 2.0) / 2.0 })).sorted()
        
        let clampedProjection = min(max(0, projectedOffset), maxAllowed)
        var chosenOffset: CGFloat = clampedProjection
        
        if velocity > 100.0 {
            // Flick forward (scrolling right, offset increasing) -> look for candidates strictly ahead
            let forwardCandidates = sortedCandidates.filter { $0 > clampedProjection - 20.0 }
            if let best = forwardCandidates.first(where: { $0 > clampedProjection }) ?? forwardCandidates.first {
                chosenOffset = best
            } else {
                chosenOffset = sortedCandidates.last ?? maxAllowed
            }
        } else if velocity < -100.0 {
            // Flick backward (scrolling left, offset decreasing) -> look for candidates strictly behind
            let backwardCandidates = sortedCandidates.filter { $0 < clampedProjection + 20.0 }
            if let best = backwardCandidates.last(where: { $0 < clampedProjection }) ?? backwardCandidates.last {
                chosenOffset = best
            } else {
                chosenOffset = sortedCandidates.first ?? 0.0
            }
        } else {
            // Gentle glide / rest: closest candidate
            if let best = sortedCandidates.min(by: { abs($0 - clampedProjection) < abs($1 - clampedProjection) }) {
                chosenOffset = best
            }
        }
        
        // Find prominent column index for chosenOffset
        var bestColIdx = 0
        var bestScore: CGFloat = -CGFloat.greatestFiniteMagnitude
        let viewportCenter = chosenOffset + (visibleWidth / 2.0)
        
        for (i, col) in columns.enumerated() {
            let colLeft = offsets[i]
            let colRight = colLeft + col.width
            let visLeft = max(colLeft, chosenOffset)
            let visRight = min(colRight, chosenOffset + visibleWidth)
            let visW = max(0, visRight - visLeft)
            let colCenter = colLeft + (col.width / 2.0)
            let distFromCenter = abs(colCenter - viewportCenter)
            
            let isExactLeftSnap: CGFloat = abs(chosenOffset - colLeft) < 1.0 ? 500.0 : 0.0
            let score = (visW * 10.0) + isExactLeftSnap - distFromCenter
            if score > bestScore {
                bestScore = score
                bestColIdx = i
            }
        }
        
        return SnapTarget(targetOffset: chosenOffset, focusedColumnIndex: bestColIdx)
    }
    
    /// Cycles the width of the column through presets ([0.25, 0.333, 0.50, 0.667, 0.75]).
    @discardableResult
    public func cycleColumnWidth(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) -> CGFloat {
        return cyclePresetWidth(at: index, columns: &columns, visibleWidth: visibleWidth, backward: false)
    }
    
    /// Cycles through user preset widths forward or backward.
    @discardableResult
    public func cyclePresetWidth(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat,
        ratios: [CGFloat] = [0.25, 0.333, 0.50, 0.667, 0.75, 1.0],
        backward: Bool = false
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        let currentWidth = columns[index].width
        let currentRatio = currentWidth / max(1.0, visibleWidth)
        
        let presetRatios = ratios.isEmpty ? [0.25, 0.333, 0.50, 0.667, 0.75, 1.0] : ratios
        var nextRatio = presetRatios[0]
        
        if backward {
            nextRatio = presetRatios.last ?? 0.75
            for r in presetRatios.reversed() {
                if r < currentRatio - 0.04 {
                    nextRatio = r
                    break
                }
            }
        } else {
            for r in presetRatios {
                if r > currentRatio + 0.04 {
                    nextRatio = r
                    break
                }
            }
        }
        
        let newWidth = max(defaultMinimumColumnWidth, round(visibleWidth * nextRatio))
        columns[index].width = newWidth
        columns[index].isFullWidth = false
        return newWidth
    }
    
    /// Nudges the column width by a delta ratio (e.g. ±0.05).
    @discardableResult
    public func nudgeColumnWidth(
        at index: Int,
        columns: inout [WindowColumn],
        deltaRatio: CGFloat,
        visibleWidth: CGFloat
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        let currentRatio = columns[index].width / max(1.0, visibleWidth)
        let newRatio = min(1.0, max(0.15, currentRatio + deltaRatio))
        let newWidth = max(defaultMinimumColumnWidth, round(visibleWidth * newRatio))
        columns[index].width = newWidth
        columns[index].isFullWidth = (newRatio >= 0.99)
        return newWidth
    }
    
    /// Toggles full width for the specified column, preserving pre-full-width ratio.
    @discardableResult
    public func toggleFullWidth(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        if columns[index].isFullWidth {
            let restoredWidth = max(defaultMinimumColumnWidth, round(visibleWidth * columns[index].savedPreFullWidthRatio))
            columns[index].width = restoredWidth
            columns[index].isFullWidth = false
            return restoredWidth
        } else {
            columns[index].savedPreFullWidthRatio = columns[index].width / max(1.0, visibleWidth)
            columns[index].width = visibleWidth
            columns[index].isFullWidth = true
            return visibleWidth
        }
    }
    
    /// Stacks a window into a target column.
    public func stackWindow(
        windowId: WindowId,
        fromColumnIndex: Int,
        toColumnIndex: Int,
        columns: inout [WindowColumn]
    ) {
        guard fromColumnIndex >= 0, fromColumnIndex < columns.count,
              toColumnIndex >= 0, toColumnIndex < columns.count,
              fromColumnIndex != toColumnIndex else { return }
        
        columns[fromColumnIndex].windowIds.removeAll { $0 == windowId }
        columns[toColumnIndex].windowIds.append(windowId)
        
        // Clean empty origin column
        columns.removeAll { $0.windowIds.isEmpty }
    }
    
    /// Unstacks a window out of a column into its own independent column adjacent to it.
    public func unstackWindow(
        windowId: WindowId,
        fromColumnIndex: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) -> Int {
        guard fromColumnIndex >= 0, fromColumnIndex < columns.count else { return fromColumnIndex }
        guard columns[fromColumnIndex].windowIds.count > 1 else { return fromColumnIndex }
        
        columns[fromColumnIndex].windowIds.removeAll { $0 == windowId }
        let newCol = WindowColumn(windowIds: [windowId], width: columns[fromColumnIndex].width)
        let insertIndex = fromColumnIndex + 1
        columns.insert(newCol, at: insertIndex)
        return insertIndex
    }
    

    /// Computes the viewport offset required to center the specified column on screen.
    public func centerColumnOffset(
        at index: Int,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        loopMode: Bool = false
    ) -> CGFloat {
        guard index >= 0, index < columns.count else { return 0 }
        let offsets = columnStripOffsets(columns: columns)
        let colLeft = offsets[index]
        let colWidth = columns[index].width
        let totalWidth = totalStripWidth(columns: columns)
        let maxAllowedOffset = max(0, totalWidth - visibleWidth)
        
        let centerTarget = colLeft + (colWidth / 2.0) - (visibleWidth / 2.0)
        // The cyclic scroll controller maps an unclamped target to the nearest copy.
        // Keeping the raw target avoids pinning columns 0 and n-1 to the linear ends.
        if loopMode { return centerTarget }
        return min(max(0, centerTarget), maxAllowedOffset)
    }
    
    /// Maximizes the specified column to fill the entire visible width, or toggles back to previous width.
    public func maximizeColumn(
        at index: Int,
        columns: inout [WindowColumn],
        visibleWidth: CGFloat
    ) {
        guard index >= 0, index < columns.count else { return }
        if columns[index].isFullWidth || abs(columns[index].width - visibleWidth) < 2.0 {
            let ratio = columns[index].savedPreFullWidthRatio > 0 ? columns[index].savedPreFullWidthRatio : 0.50
            columns[index].width = max(300, visibleWidth * ratio)
            columns[index].isFullWidth = false
        } else {
            let currentRatio = max(0.20, min(0.90, columns[index].width / max(1, visibleWidth)))
            columns[index].savedPreFullWidthRatio = currentRatio
            columns[index].width = visibleWidth
            columns[index].isFullWidth = true
        }
    }
    
    /// Adjusts the relative vertical height weight of a window inside a stacked column.
    public func nudgeStackWindowHeight(
        windowId: WindowId,
        at columnIndex: Int,
        deltaRatio: CGFloat,
        columns: inout [WindowColumn]
    ) {
        guard columnIndex >= 0, columnIndex < columns.count else { return }
        guard columns[columnIndex].windowIds.count > 1 else { return }
        if let entryIdx = columns[columnIndex].windowEntries.firstIndex(where: { $0.id == windowId }) {
            let current = columns[columnIndex].windowEntries[entryIdx].heightRatio
            columns[columnIndex].windowEntries[entryIdx].heightRatio = min(0.85, max(0.15, current + deltaRatio))
        }
    }
    
    /// Equalizes vertical heights of all windows inside the specified column stack.
    public func equalizeStackHeights(
        at columnIndex: Int,
        columns: inout [WindowColumn]
    ) {
        guard columnIndex >= 0, columnIndex < columns.count else { return }
        let count = max(1, columns[columnIndex].windowEntries.count)
        let equalRatio = 1.0 / CGFloat(count)
        for i in columns[columnIndex].windowEntries.indices {
            columns[columnIndex].windowEntries[i].heightRatio = equalRatio
        }
    }

    public func columnScreenFrames(
        columns: [WindowColumn],
        viewportOffset: CGFloat,
        visibleFrame: CGRect,
        gap: CGFloat? = nil,
        margins: EdgeMargins? = nil
    ) -> [UUID: ColumnScreenFrame] {
        let effectiveGap = gap ?? windowGap
        let effectiveMargins = margins ?? edgeMargins
        let usableWidth = max(100, visibleFrame.width - effectiveMargins.left - effectiveMargins.right)
        let minVisibleX = visibleFrame.minX + effectiveMargins.left
        let maxVisibleX = minVisibleX + usableWidth
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        let sliver = max(1.0, offScreenPeekSliverWidth)
        
        var result: [UUID: ColumnScreenFrame] = [:]
        for (index, column) in columns.enumerated() where index < offsets.count {
            let colWidth = column.width
            let rawX = minVisibleX + offsets[index] - viewportOffset
            var screenX = rawX
            var isParked = false
            if rawX + colWidth <= minVisibleX + sliver {
                screenX = minVisibleX - colWidth + sliver
                isParked = true
            } else if rawX >= maxVisibleX - max(35.0, sliver) {
                screenX = maxVisibleX - sliver
                isParked = true
            }
            let frame = CGRect(
                x: screenX,
                y: visibleFrame.minY + effectiveMargins.top,
                width: colWidth,
                height: max(PureStripLayoutEngine.tabBarHeight,
                             visibleFrame.height - effectiveMargins.top - effectiveMargins.bottom)
            )
            result[column.id] = ColumnScreenFrame(columnId: column.id, frame: frame, isParked: isParked)
        }
        return result
    }

    /// Finds the prominent column index that has the maximum visible area on-screen for the given viewport offset.
    public func prominentColumnIndex(
        for viewportOffset: CGFloat,
        columns: [WindowColumn],
        visibleWidth: CGFloat,
        gap: CGFloat? = nil
    ) -> Int {
        guard !columns.isEmpty else { return 0 }
        let effectiveGap = gap ?? self.windowGap
        let offsets = columnStripOffsets(columns: columns, gap: effectiveGap)
        var bestColIdx = 0
        var maxVisibleWidth: CGFloat = -1.0
        
        for (i, col) in columns.enumerated() {
            let colLeft = offsets[i]
            let colRight = colLeft + col.width
            let visLeft = max(colLeft, viewportOffset)
            let visRight = min(colRight, viewportOffset + visibleWidth)
            let visW = max(0, visRight - visLeft)
            
            if visW > maxVisibleWidth {
                maxVisibleWidth = visW
                bestColIdx = i
            }
        }
        return bestColIdx
    }

    /// Merges the given windows into one tabbed column, removing them from their
    /// current columns. The active tab is `activeWindowId` when supplied.
    /// Returns the index of the new tab group.
    @discardableResult
    public func groupWindows(
        _ windowIds: [WindowId],
        into columns: inout [WindowColumn],
        at insertionIndex: Int,
        width: CGFloat? = nil,
        activeWindowId: WindowId? = nil
    ) -> Int? {
        let uniqueIds = windowIds.reduce(into: [WindowId]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !uniqueIds.isEmpty else { return nil }
        
        // Preserve the width of the first member column if no explicit width is given.
        let sourceWidth = columns.first(where: { column in
            column.windowIds.contains(where: { uniqueIds.contains($0) })
        })?.width
        let groupWidth = width ?? sourceWidth ?? defaultMinimumColumnWidth
        
        for id in uniqueIds {
            for index in columns.indices {
                columns[index].removeWindow(id)
            }
        }
        columns.removeAll { $0.windowIds.isEmpty }
        
        var group = WindowColumn(
            windowIds: uniqueIds,
            width: groupWidth,
            presentationMode: .tabbed
        )
        if let activeWindowId, let activeIndex = group.windowIds.firstIndex(of: activeWindowId) {
            group.activeWindowIndex = activeIndex
        }
        let targetIndex = max(0, min(insertionIndex, columns.count))
        columns.insert(group, at: targetIndex)
        return targetIndex
    }
    
    /// Moves a window from another column into an existing tab group.
    /// Returns the resulting tab-group index.
    @discardableResult
    public func moveWindowToTabGroup(
        windowId: WindowId,
        fromColumnIndex: Int,
        toColumnIndex: Int,
        columns: inout [WindowColumn]
    ) -> Int? {
        guard fromColumnIndex >= 0, fromColumnIndex < columns.count,
              toColumnIndex >= 0, toColumnIndex < columns.count,
              fromColumnIndex != toColumnIndex,
              columns[fromColumnIndex].windowIds.contains(windowId) else { return nil }
        
        columns[fromColumnIndex].removeWindow(windowId)
        var targetIndex = toColumnIndex
        if columns[fromColumnIndex].windowIds.isEmpty {
            columns.remove(at: fromColumnIndex)
            if fromColumnIndex < targetIndex { targetIndex -= 1 }
        }
        guard targetIndex >= 0, targetIndex < columns.count else { return nil }
        
        columns[targetIndex].windowIds.append(windowId)
        columns[targetIndex].presentationMode = .tabbed
        columns[targetIndex].activeWindowIndex = columns[targetIndex].windowIds.count - 1
        return targetIndex
    }
    
    /// Removes a tab from its group and restores it as an independent column
    /// immediately to the right of the group. Returns the new column index.
    @discardableResult
    public func detachTab(
        windowId: WindowId,
        fromColumnIndex: Int,
        columns: inout [WindowColumn]
    ) -> Int? {
        guard fromColumnIndex >= 0, fromColumnIndex < columns.count,
              columns[fromColumnIndex].windowIds.count > 1,
              columns[fromColumnIndex].windowIds.contains(windowId) else { return nil }
        
        let sourceWidth = columns[fromColumnIndex].width
        columns[fromColumnIndex].removeWindow(windowId)
        columns[fromColumnIndex].normalizeTabPresentation()
        
        let detached = WindowColumn(
            windowIds: [windowId],
            width: sourceWidth,
            presentationMode: .stacked
        )
        let insertIndex = fromColumnIndex + 1
        columns.insert(detached, at: insertIndex)
        return insertIndex
    }
    
    /// Explodes a tab group into one independent, stacked column per tab.
    /// Returns the indices occupied by the resulting columns.
    @discardableResult
    public func ungroupAllTabs(
        at columnIndex: Int,
        columns: inout [WindowColumn]
    ) -> [Int] {
        guard columnIndex >= 0, columnIndex < columns.count,
              columns[columnIndex].windowIds.count > 1 else { return [] }
        
        let source = columns[columnIndex]
        let replacement: [WindowColumn] = source.windowIds.map { windowId in
            WindowColumn(windowIds: [windowId], width: source.width, presentationMode: .stacked)
        }
        columns.replaceSubrange(columnIndex...columnIndex, with: replacement)
        return Array(columnIndex..<(columnIndex + replacement.count))
    }
    
    /// Flips a column between stacked and tabbed presentation. Turning a single
    /// window into a tab group explicitly pins its bar so the "+" affordance stays
    /// visible even before a second tab is added.
    public func toggleColumnTabbedMode(at index: Int, columns: inout [WindowColumn]) {
        guard index >= 0, index < columns.count else { return }
        if columns[index].presentationMode == .tabbed {
            columns[index].presentationMode = .stacked
            columns[index].tabBarPinned = false
        } else {
            columns[index].presentationMode = .tabbed
            columns[index].tabBarPinned = (columns[index].windowIds.count == 1)
            if let activeId = columns[index].activeWindowId,
               let activeIndex = columns[index].windowIds.firstIndex(of: activeId) {
                columns[index].activeWindowIndex = activeIndex
            }
        }
    }
    
    /// Cycles the active window in a stacked or tabbed column.
    public func cycleActiveWindowInColumn(at index: Int, columns: inout [WindowColumn], direction: Int) {
        guard index >= 0, index < columns.count else { return }
        let count = columns[index].windowIds.count
        guard count > 1 else { return }
        var next = columns[index].activeWindowIndex + direction
        if next < 0 { next = count - 1 }
        if next >= count { next = 0 }
        columns[index].activeWindowIndex = next
    }
    
    /// Moves a tab from one column to another at an optional target tab index.
    /// Preserves tab identity, titles, and locked state, and returns the resulting column and tab index.
    @discardableResult
    public func moveTabBetweenGroups(
        windowId: WindowId,
        fromColumnIndex: Int,
        toColumnIndex: Int,
        toIndex: Int? = nil,
        columns: inout [WindowColumn]
    ) -> (targetColumnIndex: Int, targetTabIndex: Int)? {
        guard fromColumnIndex >= 0, fromColumnIndex < columns.count,
              toColumnIndex >= 0, toColumnIndex < columns.count,
              fromColumnIndex != toColumnIndex,
              columns[fromColumnIndex].windowIds.contains(windowId) else { return nil }
        
        let customTitle = columns[fromColumnIndex].customTabTitles[windowId]
        let isLocked = columns[fromColumnIndex].isLocked(windowId)
        
        columns[fromColumnIndex].removeWindow(windowId)
        columns[fromColumnIndex].normalizeTabPresentation()
        
        var adjustedTargetColIndex = toColumnIndex
        if columns[fromColumnIndex].windowIds.isEmpty {
            columns.remove(at: fromColumnIndex)
            if fromColumnIndex < adjustedTargetColIndex {
                adjustedTargetColIndex -= 1
            }
        }
        guard adjustedTargetColIndex >= 0, adjustedTargetColIndex < columns.count else { return nil }
        
        columns[adjustedTargetColIndex].presentationMode = .tabbed
        let insertIndex: Int
        if let toIndex {
            insertIndex = max(0, min(toIndex, columns[adjustedTargetColIndex].windowIds.count))
            columns[adjustedTargetColIndex].windowIds.insert(windowId, at: insertIndex)
        } else {
            columns[adjustedTargetColIndex].windowIds.append(windowId)
            insertIndex = columns[adjustedTargetColIndex].windowIds.count - 1
        }
        
        if let customTitle {
            columns[adjustedTargetColIndex].setCustomTitle(customTitle, for: windowId)
        }
        if isLocked {
            columns[adjustedTargetColIndex].lockedWindowIds.insert(windowId)
        }
        columns[adjustedTargetColIndex].activeWindowIndex = insertIndex
        
        return (adjustedTargetColIndex, insertIndex)
    }
    
    /// Closes all unlocked tabs other than `windowId` in a column. Returns the closed window IDs.
    @discardableResult
    public func closeOtherTabsInGroup(
        windowId: WindowId,
        at columnIndex: Int,
        columns: inout [WindowColumn]
    ) -> [WindowId] {
        guard columnIndex >= 0, columnIndex < columns.count else { return [] }
        return columns[columnIndex].closeOtherWindows(except: windowId)
    }
    
    /// Closes all unlocked tabs to the right of `windowId` in a column. Returns the closed window IDs.
    @discardableResult
    public func closeTabsToRightInGroup(
        windowId: WindowId,
        at columnIndex: Int,
        columns: inout [WindowColumn]
    ) -> [WindowId] {
        guard columnIndex >= 0, columnIndex < columns.count else { return [] }
        return columns[columnIndex].closeWindowsToRight(of: windowId)
    }
}

/// Pure mathematical layout calculator supporting 3 Centre Modes, Vertical Stacks, and Tabbed Columns.
public struct PureStripLayoutEngine {
    public static let minStackedWindowHeight: CGFloat = 200.0
    public static let tabBarHeight: CGFloat = 28.0
    
    /// Calculates target viewport offset for focused column under the three Centre Modes.
    public static func targetViewportOffset(
        columns: [WindowColumn],
        focusedColumnIndex: Int,
        currentViewportOffset: CGFloat,
        visibleFrame: CGRect,
        innerGap: CGFloat,
        outerMargins: EdgeMargins,
        centerMode: CenterMode
    ) -> CGFloat {
        guard columns.indices.contains(focusedColumnIndex) else { return currentViewportOffset }
        let usableWidth = visibleFrame.width - outerMargins.left - outerMargins.right
        
        var stripX: [CGFloat] = []
        var colWidths: [CGFloat] = []
        var cursor: CGFloat = 0
        for col in columns {
            let ratio = col.isFullWidth ? 1.0 : (col.width / max(1.0, usableWidth))
            let w = floor(usableWidth * ratio)
            stripX.append(cursor)
            colWidths.append(w)
            cursor += w + innerGap
        }
        let totalStripWidth = max(0, cursor - innerGap)
        let targetColX = stripX[focusedColumnIndex]
        let targetColW = colWidths[focusedColumnIndex]
        
        switch centerMode {
        case .always:
            return targetColX - ((usableWidth - targetColW) / 2.0)
        case .onOverflow:
            if totalStripWidth <= usableWidth { return 0 }
            let centered = targetColX - ((usableWidth - targetColW) / 2.0)
            return min(max(0, centered), max(0, totalStripWidth - usableWidth))
        case .never:
            if targetColX < currentViewportOffset {
                return targetColX
            } else if (targetColX + targetColW) > (currentViewportOffset + usableWidth) {
                return (targetColX + targetColW) - usableWidth
            }
            return currentViewportOffset
        }
    }
    
    /// Computes physical CGRect frames for all windows, including Stacked and Tabbed modes.
    public static func computeWindowFrames(
        columns: [WindowColumn],
        viewportOffset: CGFloat,
        visibleFrame: CGRect,
        innerGap: CGFloat,
        outerMargins: EdgeMargins
    ) -> [WindowId: CGRect] {
        var result: [WindowId: CGRect] = [:]
        let usableWidth = visibleFrame.width - outerMargins.left - outerMargins.right
        let usableHeight = visibleFrame.height - outerMargins.top - outerMargins.bottom
        let baseOriginY = visibleFrame.minY + outerMargins.top
        
        var stripCursorX: CGFloat = 0
        for col in columns {
            let ratio = col.isFullWidth ? 1.0 : (col.width / max(1.0, usableWidth))
            let colWidth = floor(usableWidth * ratio)
            let rawScreenX = visibleFrame.minX + outerMargins.left + stripCursorX - viewportOffset
            let sliver: CGFloat = 12.0
            var screenX = rawScreenX
            if rawScreenX + colWidth <= visibleFrame.minX + sliver {
                screenX = visibleFrame.minX - colWidth + sliver
            } else if rawScreenX >= visibleFrame.maxX - sliver {
                screenX = visibleFrame.maxX - sliver
            }
            
            let winIds = col.windowIds
            if winIds.count == 1, let single = winIds.first {
                result[single] = CGRect(x: screenX, y: baseOriginY, width: colWidth, height: usableHeight)
            } else if col.presentationMode == .tabbed {
                let tabContentY = baseOriginY + tabBarHeight
                let tabContentHeight = max(minStackedWindowHeight, usableHeight - tabBarHeight)
                for (idx, winId) in winIds.enumerated() {
                    if idx == col.activeWindowIndex {
                        result[winId] = CGRect(x: screenX, y: tabContentY, width: colWidth, height: tabContentHeight)
                    } else {
                        // Park inactive tab cleanly at the left edge sliver
                        result[winId] = CGRect(x: visibleFrame.minX - colWidth + sliver, y: tabContentY, width: colWidth, height: tabContentHeight)
                    }
                }
            } else {
                // Stacked Column: Distribute height proportionally with minStackedWindowHeight clamp
                let count = CGFloat(winIds.count)
                let totalGaps = innerGap * max(0, count - 1)
                let availableStackHeight = max(count * minStackedWindowHeight, usableHeight - totalGaps)
                let entries = col.windowEntries
                let sumRatios = max(0.01, entries.reduce(0) { $0 + $1.heightRatio })
                
                var currentY = baseOriginY
                for (idx, winId) in winIds.enumerated() {
                    let entry = entries.first(where: { $0.id == winId }) ?? StackedWindowEntry(id: winId)
                    let rawH = floor(availableStackHeight * (entry.heightRatio / sumRatios))
                    let h = (idx == winIds.count - 1)
                        ? max(minStackedWindowHeight, (baseOriginY + usableHeight) - currentY)
                        : max(minStackedWindowHeight, rawH)
                    result[winId] = CGRect(x: screenX, y: currentY, width: colWidth, height: h)
                    currentY += h + innerGap
                }
            }
            stripCursorX += colWidth + innerGap
        }
        return result
    }
    
    // MARK: - Requirement 4: Animated "Parting the Strip" Window Insertion Choreography
    
    /// Computes intermediate window frames as a newly opened window (`insertedWindowId` at `insertedColumnIndex`)
    /// makes its way between open strip columns according to `WindowInsertionAnimationStyle`.
    public static func computeInsertionAnimationFrames(
        targetFrames: [WindowId: CGRect],
        insertedWindowId: WindowId,
        insertedColumnIndex: Int,
        columns: [WindowColumn],
        progress: Double,
        style: WindowInsertionAnimationStyle
    ) -> [WindowId: CGRect] {
        let t = min(1.0, max(0.0, progress))
        if style == .instantSlot || t >= 0.999 {
            return targetFrames
        }
        guard let insertedTarget = targetFrames[insertedWindowId] else {
            return targetFrames
        }
        
        // Smooth cubic ease-out curve for parting neighbors
        let inv = 1.0 - t
        let easeOut = CGFloat(1.0 - inv * inv * inv)
        let remaining = 1.0 - easeOut
        
        var animated: [WindowId: CGRect] = targetFrames
        let displacement = insertedTarget.width * 0.48
        
        for (colIdx, col) in columns.enumerated() {
            for winId in col.windowIds {
                guard let finalFrame = targetFrames[winId] else { continue }
                
                if winId == insertedWindowId {
                    switch style {
                    case .partingWave:
                        // Starts as a centered 30% sliver in the parting gap and expands outward
                        let scaleW = 0.30 + 0.70 * easeOut
                        let w = max(180, round(finalFrame.width * scaleW))
                        let x = round(finalFrame.midX - w / 2.0)
                        animated[winId] = CGRect(x: x, y: finalFrame.origin.y, width: w, height: finalFrame.height)
                    case .harmonicSlideIn:
                        // Slides down and expands into the slot next to the focused column
                        let yOffset = -48.0 * remaining
                        let scaleW = 0.65 + 0.35 * easeOut
                        let w = max(200, round(finalFrame.width * scaleW))
                        animated[winId] = CGRect(
                            x: round(finalFrame.origin.x + (finalFrame.width - w) * 0.5),
                            y: round(finalFrame.origin.y + yOffset),
                            width: w,
                            height: finalFrame.height
                        )
                    case .bloomExpand:
                        // Blooms symmetrically from a glowing vertical seam
                        let scaleW = 0.22 + 0.78 * easeOut
                        let scaleH = 0.86 + 0.14 * easeOut
                        let w = max(160, round(finalFrame.width * scaleW))
                        let h = max(120, round(finalFrame.height * scaleH))
                        animated[winId] = CGRect(
                            x: round(finalFrame.midX - w / 2.0),
                            y: round(finalFrame.midY - h / 2.0),
                            width: w,
                            height: h
                        )
                    case .instantSlot:
                        animated[winId] = finalFrame
                    }
                } else if colIdx < insertedColumnIndex {
                    // Left neighbor (the focused window) starts slightly closer to the seam and parts leftward
                    let shiftRight = (colIdx == insertedColumnIndex - 1) ? min(72.0, displacement * 0.35) * remaining : 0.0
                    animated[winId] = CGRect(
                        x: round(finalFrame.origin.x + shiftRight),
                        y: finalFrame.origin.y,
                        width: finalFrame.width,
                        height: finalFrame.height
                    )
                } else if colIdx > insertedColumnIndex {
                    // Right neighbors start shifted left (where they were before insertion) and part rightward as the new window makes its way in!
                    let shiftLeft = displacement * remaining
                    animated[winId] = CGRect(
                        x: round(finalFrame.origin.x - shiftLeft),
                        y: finalFrame.origin.y,
                        width: finalFrame.width,
                        height: finalFrame.height
                    )
                }
            }
        }
        
        return animated
    }
}


