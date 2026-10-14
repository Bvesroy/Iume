import Foundation
import CoreGraphics
import ApplicationServices

/// Coordinates keyboard-driven navigation, window activation, and focus synchronization.
@MainActor
public final class FocusManager {
    
    public var onFocusRequested: ((WindowId, Int) -> Void)?
    
    public init() {}
    
    // MARK: - Navigation Operations
    
    public func focusLeft(columns: [WindowColumn], currentColumnIndex: Int?) {
        guard !columns.isEmpty else { return }
        let current = currentColumnIndex ?? 0
        let targetIndex = max(0, current - 1)
        selectColumn(at: targetIndex, columns: columns)
    }
    
    public func focusRight(columns: [WindowColumn], currentColumnIndex: Int?) {
        guard !columns.isEmpty else { return }
        let current = currentColumnIndex ?? 0
        let targetIndex = min(columns.count - 1, current + 1)
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
    
    public func focusUp(columns: [WindowColumn], currentColumnIndex: Int?, currentWindowId: WindowId?) {
        guard let current = currentColumnIndex, current >= 0, current < columns.count else { return }
        let winIds = columns[current].windowIds
        guard winIds.count > 1, let currentWin = currentWindowId, let idx = winIds.firstIndex(of: currentWin) else { return }
        let targetWinIdx = max(0, idx - 1)
        onFocusRequested?(winIds[targetWinIdx], current)
    }
    
    public func focusDown(columns: [WindowColumn], currentColumnIndex: Int?, currentWindowId: WindowId?) {
        guard let current = currentColumnIndex, current >= 0, current < columns.count else { return }
        let winIds = columns[current].windowIds
        guard winIds.count > 1, let currentWin = currentWindowId, let idx = winIds.firstIndex(of: currentWin) else { return }
        let targetWinIdx = min(winIds.count - 1, idx + 1)
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
        guard let targetWindowId = col.windowIds.first else { return }
        onFocusRequested?(targetWindowId, index)
    }
}
