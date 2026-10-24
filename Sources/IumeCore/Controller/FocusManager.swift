import Foundation
import CoreGraphics
import ApplicationServices

/// Coordinates keyboard-driven navigation, window activation, and focus synchronization.
@MainActor
public final class FocusManager {
    
    public var onFocusRequested: ((WindowId, Int) -> Void)?
    
    public init() {}
    
    // MARK: - Navigation Operations
    
    public func focusLeft(columns: [WindowColumn], currentColumnIndex: Int?, wrapAround: Bool = false) {
        guard !columns.isEmpty else { return }
        let current = currentColumnIndex ?? 0
        let targetIndex: Int
        if current > 0 {
            targetIndex = current - 1
        } else if wrapAround {
            targetIndex = columns.count - 1
        } else {
            targetIndex = 0
        }
        selectColumn(at: targetIndex, columns: columns)
    }
    
    public func focusRight(columns: [WindowColumn], currentColumnIndex: Int?, wrapAround: Bool = false) {
        guard !columns.isEmpty else { return }
        let current = currentColumnIndex ?? 0
        let targetIndex: Int
        if current < columns.count - 1 {
            targetIndex = current + 1
        } else if wrapAround {
            targetIndex = 0
        } else {
            targetIndex = columns.count - 1
        }
        selectColumn(at: targetIndex, columns: columns)
    }
    
    public func focusFirst(columns: [WindowColumn]) {
        guard !columns.isEmpty else { return }
        selectColumn(at: 0, columns: columns)
    }
    
    public func focusLast(columns: [WindowColumn]) {
        guard !columns.isEmpty else { return }
        selectColumn(at: columns.count - 1, columns: columns)
    }
    
    public func focusUp(columns: [WindowColumn], currentColumnIndex: Int?, currentWindowId: WindowId?, wrapAround: Bool = false) {
        guard let current = currentColumnIndex, current >= 0, current < columns.count else { return }
        let winIds = columns[current].windowIds
        guard winIds.count > 1, let currentWin = currentWindowId, let idx = winIds.firstIndex(of: currentWin) else { return }
        let targetWinIdx: Int
        if idx > 0 {
            targetWinIdx = idx - 1
        } else if wrapAround {
            targetWinIdx = winIds.count - 1
        } else {
            targetWinIdx = 0
        }
        onFocusRequested?(winIds[targetWinIdx], current)
    }
    
    public func focusDown(columns: [WindowColumn], currentColumnIndex: Int?, currentWindowId: WindowId?, wrapAround: Bool = false) {
        guard let current = currentColumnIndex, current >= 0, current < columns.count else { return }
        let winIds = columns[current].windowIds
        guard winIds.count > 1, let currentWin = currentWindowId, let idx = winIds.firstIndex(of: currentWin) else { return }
        let targetWinIdx: Int
        if idx < winIds.count - 1 {
            targetWinIdx = idx + 1
        } else if wrapAround {
            targetWinIdx = 0
        } else {
            targetWinIdx = winIds.count - 1
        }
        onFocusRequested?(winIds[targetWinIdx], current)
    }
    
    public func cycleWindows(columns: [WindowColumn], currentWindowId: WindowId?, forward: Bool) {
        let allWindowIds = columns.flatMap { $0.windowIds }
        guard !allWindowIds.isEmpty else { return }
        
        let currentIndex = currentWindowId.flatMap { allWindowIds.firstIndex(of: $0) } ?? 0
        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % allWindowIds.count
        } else {
            nextIndex = (currentIndex - 1 + allWindowIds.count) % allWindowIds.count
        }
        
        let targetWindowId = allWindowIds[nextIndex]
        let targetColIndex = columns.firstIndex { $0.windowIds.contains(targetWindowId) } ?? 0
        onFocusRequested?(targetWindowId, targetColIndex)
    }
    
    // MARK: - Private Selection Helper
    
    private func selectColumn(at index: Int, columns: [WindowColumn]) {
        guard index >= 0, index < columns.count else { return }
        let col = columns[index]
        let targetWindowId: WindowId? = {
            if col.activeWindowIndex >= 0 && col.activeWindowIndex < col.windowIds.count {
                return col.windowIds[col.activeWindowIndex]
            }
            return col.windowIds.first
        }()
        guard let target = targetWindowId else { return }
        onFocusRequested?(target, index)
    }
}
