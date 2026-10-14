import Foundation

/// Structured diagnostic logging and runtime performance metrics for Iume.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = Diagnostics()
    
    public struct LogEntry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let level: String
        public let category: String
        public let message: String
        
        public var formatted: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return "[\(df.string(from: timestamp))] [\(level)] [\(category)] \(message)"
        }
    }
    
    private let lock = NSLock()
    private var logs: [LogEntry] = []
    private let maxLogs = 500
    
    public private(set) var managedWindowCount: Int = 0
    public private(set) var activeColumnCount: Int = 0
    public private(set) var totalNotificationsHandled: Int = 0
    public private(set) var failedOperationsCount: Int = 0
    
    public init() {}
    
    public func log(level: String = "INFO", category: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }
    
    public func updateMetrics(windows: Int, columns: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.managedWindowCount = windows
        self.activeColumnCount = columns
    }
    
    public func recordNotification() {
        lock.lock()
        defer { lock.unlock() }
        self.totalNotificationsHandled += 1
    }
    
    public func recordFailedOperation() {
        lock.lock()
        defer { lock.unlock() }
        self.failedOperationsCount += 1
    }
    
    public func recentLogs() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }
    
    public func exportDiagnosticReport() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        var report = "=== Iume Diagnostics Report ===\n"
        report += "Date: \(Date())\n"
        report += "Managed Windows: \(managedWindowCount)\n"
        report += "Active Columns: \(activeColumnCount)\n"
        report += "Total Notifications Handled: \(totalNotificationsHandled)\n"
        report += "Failed Operations: \(failedOperationsCount)\n"
        report += "\n=== Recent Logs (Last \(logs.count)) ===\n"
        for log in logs {
            report += "\(log.formatted)\n"
        }
        return report
    }
}
