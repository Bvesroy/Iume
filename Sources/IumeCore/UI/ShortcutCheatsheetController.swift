import SwiftUI
import AppKit

/// Floating, always-on-top list of every bound shortcut.
///
/// The content is rendered from `SettingsStore.shortcutBindings`, the same table that drives
/// hotkey registration, so the cheatsheet cannot fall out of date with the real bindings.
@MainActor
public final class ShortcutCheatsheetController {
    public static let shared = ShortcutCheatsheetController()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        let root = ShortcutCheatsheetView(bindings: SettingsStore.shared.shortcutBindings)
        let hosting = NSHostingView(rootView: root)

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            p.title = "Iume Shortcuts"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            p.minSize = NSSize(width: 560, height: 380)
            panel = p
        }

        guard let panel else { return }
        panel.contentView = hosting
        if !panel.isVisible {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    public func hide() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    private func installMonitors() {
        removeMonitors()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 0x35 { // Escape
                DispatchQueue.main.async { self?.hide() }
                return nil
            }
            return event
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeMonitors() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

// MARK: - View

struct ShortcutCheatsheetView: View {
    let bindings: [ShortcutBinding]

    private var boundGroups: [(group: ShortcutGroupID, rows: [ShortcutBinding])] {
        ShortcutGroupID.allCases.compactMap { group in
            let rows = bindings
                .filter { ShortcutCatalog.group(for: $0.action) == group && !$0.chords.isEmpty }
                .sorted { $0.action.rawValue < $1.action.rawValue }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 240), spacing: 18, alignment: .top),
                        GridItem(.flexible(minimum: 240), spacing: 18, alignment: .top),
                    ],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(boundGroups, id: \.group) { entry in
                        card(for: entry.group, rows: entry.rows)
                    }
                }
            }
            .padding(22)
        }
        .frame(minWidth: 540, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 20, weight: .semibold))

            HStack(spacing: 4) {
                Text("Every action is remappable in Settings → Shortcuts.")
                Text("Press")
                KeyCap("⌃")
                KeyCap("⌥")
                KeyCap("/")
                Text("to close.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func card(for group: ShortcutGroupID, rows: [ShortcutBinding]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(group.rawValue, systemImage: group.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows) { binding in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(binding.action.rawValue)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 6)

                        HStack(spacing: 6) {
                            ForEach(Array(binding.chords.enumerated()), id: \.offset) { _, chord in
                                Text(chord.displayString)
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                    )
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
