import Foundation
@testable import IumeCore

/// A `SettingsStore` that is completely detached from the user's live preferences.
///
/// `SettingsStore()` (and the app's `SettingsStore.shared`) reads and writes the real
/// `com.iume.Iume` domain plus `~/Library/Application Support/Iume/settings_memory.json`.
/// Tests must never touch either: running the suite used to reset the preferences of the
/// installed app, which is indistinguishable from "my settings keep reverting".
@MainActor
struct IsolatedSettingsFixture {
    let store: SettingsStore
    let defaults: UserDefaults
    let memoryManager: SettingsMemoryManager
    let suiteName: String

    private let directory: URL

    init() {
        let id = UUID().uuidString
        let suite = "com.iume.tests.settings.\(id)"
        let domain = UserDefaults(suiteName: suite) ?? .standard
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IumeSettingsFixture-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = SettingsMemoryManager(
            customStorageUrl: dir.appendingPathComponent("settings_memory.json")
        )

        suiteName = suite
        defaults = domain
        directory = dir
        memoryManager = manager
        store = SettingsStore(defaults: domain, memoryManager: manager)
    }

    /// A second store over the same preference domain and memory file, as if the app relaunched.
    var relaunched: SettingsStore {
        store.flushMemoryToDisk()
        return SettingsStore(defaults: defaults, memoryManager: memoryManager)
    }

    /// A second store with the same preference domain but no durable memory file, which forces
    /// the plain UserDefaults path.
    @MainActor
    func relaunchedWithoutMemoryFile() -> SettingsStore {
        let emptyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IumeSettingsFixtureNoMemory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        let emptyManager = SettingsMemoryManager(
            customStorageUrl: emptyDirectory.appendingPathComponent("settings_memory.json")
        )
        return SettingsStore(defaults: defaults, memoryManager: emptyManager)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
