import SwiftUI
import AppKit

/// Settings card for choosing how browser-style tab groups move. The card is
/// self-contained so it can be dropped into any settings pane, and the preview
/// is the real `TabBarView` so what you see is what the floating bar does.
@MainActor
struct TabEffectsSettingsCard: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tab Motion & Effects")
                        .font(.headline)
                    Text("Tune how tab groups open, close, switch, reorder, and detach.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Toggle(isOn: $settings.tabAnimationsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Animate Tab Group Motion")
                        .font(.body)
                        .fontWeight(.medium)
                    Text("Turning this off makes every tab action instant. System Reduce Motion is always respected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if settings.tabAnimationsEnabled {
                presetRow

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Tab Switch Effect", selection: $settings.tabSwitchEffect) {
                        ForEach(TabSwitchEffect.allCases) { effect in
                            Text(effect.rawValue).tag(effect)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.tabSwitchEffect.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Open & Close Effect", selection: $settings.tabOpenCloseEffect) {
                        ForEach(TabOpenCloseEffect.allCases) { effect in
                            Text(effect.rawValue).tag(effect)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(settings.tabOpenCloseEffect.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Motion Speed")
                        Spacer()
                        Text(String(format: "%.2f×", settings.tabMotionSpeed))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.tabMotionSpeed, in: 0.5...2.0, step: 0.05)
                    HStack {
                        Text("Calm")
                        Spacer()
                        Text("Balanced")
                        Spacer()
                        Text("Snappy")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }

                Toggle(isOn: $settings.tabHapticsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trackpad Haptics")
                            .font(.body)
                        Text("A subtle tap on tab switch, reorder, and when a drag crosses the detach threshold.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                TabEffectsPreview()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.18), value: settings.tabAnimationsEnabled)
    }

    // MARK: - One-tap presets

    private var presetRow: some View {
        HStack(spacing: 6) {
            presetButton(
                "Balanced",
                switchEffect: .slide,
                openCloseEffect: .scaleFade,
                speed: 1.0
            )
            presetButton(
                "Crisp",
                switchEffect: .crossfade,
                openCloseEffect: .fade,
                speed: 1.6
            )
            presetButton(
                "Playful",
                switchEffect: .springPop,
                openCloseEffect: .scaleFade,
                speed: 1.2
            )
            presetButton(
                "Cinematic",
                switchEffect: .slide,
                openCloseEffect: .materialize,
                speed: 0.7
            )
        }
    }

    private func presetButton(
        _ title: String,
        switchEffect: TabSwitchEffect,
        openCloseEffect: TabOpenCloseEffect,
        speed: Double
    ) -> some View {
        let isSelected = settings.tabSwitchEffect == switchEffect &&
            settings.tabOpenCloseEffect == openCloseEffect &&
            abs(settings.tabMotionSpeed - speed) < 0.01

        return Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                settings.tabSwitchEffect = switchEffect
                settings.tabOpenCloseEffect = openCloseEffect
                settings.tabMotionSpeed = speed
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live Preview

/// Interactive preview built from the production tab bar, backed by three
/// sample windows. Switch tabs by clicking; replay to see close and re-open.
@MainActor
private struct TabEffectsPreview: View {
    @StateObject private var demo = TabEffectsPreviewController()
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Preview")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if settings.reduceMotionIsActive {
                    Label("Reduce Motion is on", systemImage: "figure.walk.motion")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        demo.replay()
                    } label: {
                        Label("Replay Close / Open", systemImage: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            TabBarView(
                model: demo.model,
                onSelectTab: { demo.select($0) },
                onCloseTab: { demo.close($0) },
                onAddNewWindow: { demo.restore() },
                onAddExistingWindow: { _ in demo.restore() },
                onReorderTab: { demo.reorder($0, to: $1) },
                onDetachTab: { demo.close($0) },
                onUngroupAll: {},
                onTogglePin: {}
            )
            .frame(height: PureStripLayoutEngine.tabBarHeight + 4)

            Text("Click a tab to preview switching. Replay demonstrates closing and re-opening a tab.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

@MainActor
private final class TabEffectsPreviewController: ObservableObject {
    let model: TabBarViewModel
    private let catalog: [ManagedWindow]
    private var restoreWorkItem: DispatchWorkItem?

    init() {
        let windows = [
            ManagedWindow(
                id: WindowId(pid: 9001, rawId: 1),
                pid: 9001,
                bundleIdentifier: "com.apple.Safari",
                appName: "Safari",
                title: "Design References",
                frame: .zero
            ),
            ManagedWindow(
                id: WindowId(pid: 9002, rawId: 2),
                pid: 9002,
                bundleIdentifier: "com.apple.Notes",
                appName: "Notes",
                title: "Release Notes",
                frame: .zero
            ),
            ManagedWindow(
                id: WindowId(pid: 9003, rawId: 3),
                pid: 9003,
                bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal",
                title: "iume — swift build",
                frame: .zero
            )
        ]
        self.catalog = windows
        self.model = TabBarViewModel(
            columnId: UUID(),
            windows: windows,
            activeWindowId: windows.first?.id,
            candidates: [],
            isPinned: false
        )
    }

    func select(_ id: WindowId) {
        guard model.windows.contains(where: { $0.id == id }) else { return }
        model.update(
            windows: model.windows,
            activeWindowId: id,
            candidates: [],
            isPinned: false
        )
    }

    func close(_ id: WindowId) {
        guard model.windows.count > 2,
              let index = model.windows.firstIndex(where: { $0.id == id }) else { return }

        var windows = model.windows
        windows.remove(at: index)

        let activeId: WindowId?
        if model.activeWindowId == id {
            activeId = windows.indices.contains(index) ? windows[index].id : windows.last?.id
        } else {
            activeId = model.activeWindowId
        }

        model.update(
            windows: windows,
            activeWindowId: activeId,
            candidates: [],
            isPinned: false
        )
        scheduleRestore(after: 0.85)
    }

    func reorder(_ id: WindowId, to newIndex: Int) {
        var windows = model.windows
        guard let fromIndex = windows.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(newIndex, windows.count - 1))
        guard fromIndex != clamped else { return }

        let moved = windows.remove(at: fromIndex)
        windows.insert(moved, at: clamped)
        model.update(
            windows: windows,
            activeWindowId: model.activeWindowId,
            candidates: [],
            isPinned: false
        )
    }

    func restore() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil

        let windows = model.windows
        let missing = catalog.filter { sample in
            !windows.contains(where: { $0.id == sample.id })
        }
        guard !missing.isEmpty else { return }

        model.update(
            windows: windows + missing,
            activeWindowId: model.activeWindowId ?? windows.first?.id,
            candidates: [],
            isPinned: false
        )
    }

    func replay() {
        if model.windows.count >= catalog.count {
            guard let last = model.windows.last else { return }
            close(last.id)
        } else {
            restore()
        }
    }

    private func scheduleRestore(after delay: TimeInterval) {
        restoreWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.restore()
        }
        restoreWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
