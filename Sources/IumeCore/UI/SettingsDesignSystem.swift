import SwiftUI
import AppKit

// MARK: - Routing

/// The individual panes of the Iume settings window, in sidebar order.
public enum SettingsPaneID: String, CaseIterable, Identifiable, Hashable {
    case general
    case strip
    case motion
    case appearance
    case shortcuts
    case rules
    case macSetup
    case diagnostics

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .strip: return "Strip & Layout"
        case .motion: return "Motion"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .rules: return "Application Rules"
        case .macSetup: return "Mac Setup"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Start Iume, log it in automatically, and grant system access."
        case .strip: return "Window spacing, column width, screen margins, and per-display control."
        case .motion: return "Trackpad physics, animation timing, and scrolling behaviour."
        case .appearance: return "On-screen overlays and focus cues."
        case .shortcuts: return "Keyboard control of the strip."
        case .rules: return "Apps and windows that Iume should leave alone."
        case .macSetup: return "Check this Mac for settings that conflict with the strip."
        case .diagnostics: return "Inspect state, export a report, or reset everything."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .strip: return "rectangle.split.2x1"
        case .motion: return "hand.draw"
        case .appearance: return "eye"
        case .shortcuts: return "keyboard"
        case .rules: return "hand.raised"
        case .macSetup: return "checklist"
        case .diagnostics: return "stethoscope"
        }
    }

    /// Sidebar grouping. Panes without a group render flush in the list.
    var section: String? {
        switch self {
        case .general, .diagnostics: return nil
        case .strip, .motion: return "Window Management"
        case .appearance, .shortcuts: return "Interface"
        case .rules, .macSetup: return "System"
        }
    }

    /// Extra terms so sidebar search finds the pane by concept, not just title.
    var searchTerms: String {
        switch self {
        case .general: return "launch login start accessibility permission enable status"
        case .strip: return "gap margin spacing column width ratio displays monitor arrangement insert center"
        case .motion: return "scroll trackpad smoothness physics animation duration momentum speed gestures"
        case .appearance: return "minimap hud focus border dim overlay visual highlight floating"
        case .shortcuts: return "keyboard hotkey key bindings chords navigation"
        case .rules: return "exclude ignore floating applications bundles"
        case .macSetup: return "compat checker mission control stage manager tiling conflicts health"
        case .diagnostics: return "reset factory defaults export dump report repair tcc crash debug"
        }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = (title + " " + subtitle + " " + searchTerms).lowercased()
        return query
            .lowercased()
            .split(separator: " ")
            .allSatisfy { haystack.contains($0) }
    }
}

/// Lets other parts of the app (status bar menu, shortcuts) deep-link into a specific pane.
@MainActor
public final class SettingsRouter: ObservableObject {
    public static let shared = SettingsRouter()

    public static let notification = Notification.Name("com.iume.settings.requestPane")

    private init() {}

    /// Writes the request to disk (covers cold launches) and posts it (covers an already-open window).
    public static func request(_ pane: SettingsPaneID) {
        let defaults = SettingsStore.applicationDefaults
        defaults.set(pane.rawValue, forKey: "iume.settings.requestedPane")
        NotificationCenter.default.post(name: notification, object: nil)
    }

    public static func consumeStoredRequest() -> SettingsPaneID? {
        let defaults = SettingsStore.applicationDefaults
        guard let raw = defaults.string(forKey: "iume.settings.requestedPane") else { return nil }
        defaults.removeObject(forKey: "iume.settings.requestedPane")
        return SettingsPaneID(rawValue: raw)
    }
}

// MARK: - Metrics

/// Layout constants derived from the macOS layout guidelines: ~20pt window margins,
/// ~8pt between the label column and the control column, 13pt labels, 11pt help text.
public enum SettingsMetrics {
    public static let labelColumn: CGFloat = 170
    public static let columnGap: CGFloat = 10
    public static let contentInset: CGFloat = 20
    public static let cardInset: CGFloat = 14
    public static let groupSpacing: CGFloat = 18
    public static let rowSpacing: CGFloat = 10
    public static let sidebarMin: CGFloat = 196
    public static let sidebarIdeal: CGFloat = 214
    public static let sidebarMax: CGFloat = 260
    public static let windowMinWidth: CGFloat = 720
    public static let windowMinHeight: CGFloat = 480
    public static let defaultWindowWidth: CGFloat = 860
    public static let defaultWindowHeight: CGFloat = 700
}

// MARK: - Semantic colour helpers

extension Color {
    /// Hairline that reads correctly in both appearances.
    static var settingsHairline: Color { Color(nsColor: .separatorColor).opacity(0.7) }
    /// Restrained card surface for grouped settings.
    static var settingsCard: Color { Color(nsColor: .controlBackgroundColor) }
    static var settingsWindow: Color { Color(nsColor: .windowBackgroundColor) }
    static var settingsWell: Color { Color(nsColor: .textBackgroundColor) }
}

// MARK: - Pane scaffold

/// Standard scrolling body for every settings pane: grouped rows, no repeated page title.
/// The window title and the sidebar already name the pane, so the body starts with content.
public struct SettingsPane<Content: View>: View {
    private let content: Content

    public init(_ pane: SettingsPaneID, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                content
            }
            .padding(.horizontal, SettingsMetrics.contentInset)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.settingsWindow)
    }
}

// MARK: - Group

/// A titled cluster of related settings rows.
public struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let symbol: String?
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = nil
        self.content = content()
    }

    public init(@ViewBuilder content: () -> Content) {
        self.title = nil
        self.symbol = nil
        self.content = content()
    }

    public init(symbol: String, _ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
                content
            }
            .padding(SettingsMetrics.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.settingsCard)
            )
        }
    }
}

/// Hairline divider used inside a group when rows need a hard boundary.
public struct SettingsRule: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Color.settingsHairline)
            .frame(height: 0.5)
    }
}

// MARK: - Preference row

/// The canonical macOS settings row: label right-aligned in a fixed column,
/// control on the left of the remaining space, explanatory text beneath in 11pt secondary.
public struct PreferenceRow<Content: View>: View {
    private let label: String
    private let footnote: String?
    private let control: Content

    public init(_ label: String, footnote: String? = nil, @ViewBuilder control: () -> Content) {
        self.label = label
        self.footnote = footnote
        self.control = control()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.columnGap) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: SettingsMetrics.labelColumn, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)

                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Native settings align help text with the control column, not the label.
                    .padding(.leading, SettingsMetrics.labelColumn + SettingsMetrics.columnGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Convenience row for plain on/off choices. macOS uses checkboxes, not switches, in settings.
public struct PreferenceToggle: View {
    private let label: String
    private let footnote: String?
    private let isOn: Binding<Bool>

    public init(_ label: String, footnote: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.footnote = footnote
        self.isOn = isOn
    }

    public var body: some View {
        PreferenceRow(label, footnote: footnote) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(label)
        }
    }
}

// MARK: - Slider row

/// Slider with a monospaced readout and an optional segmented preset picker.
public struct SliderPreferenceRow: View {
    public struct Preset: Identifiable, Hashable {
        public let label: String
        public let value: Double
        public var id: Double { value }

        public init(_ label: String, _ value: Double) {
            self.label = label
            self.value = value
        }
    }

    private let label: String
    private let footnote: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double
    private let presets: [Preset]
    private let readout: (Double) -> String

    public init(
        _ label: String,
        footnote: String? = nil,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        presets: [Preset] = [],
        readout: @escaping (Double) -> String
    ) {
        self.label = label
        self.footnote = footnote
        self._value = value
        self.range = range
        self.step = step
        self.presets = presets
        self.readout = readout
    }

    private var isSelected: (Preset) -> Bool {
        { abs($0.value - value) <= step / 2 + 0.0001 }
    }

    public var body: some View {
        PreferenceRow(label, footnote: footnote) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Slider(value: $value, in: range, step: step)
                        .frame(maxWidth: .infinity)
                        .controlSize(.small)

                    Text(readout(value))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                if !presets.isEmpty {
                    Picker("", selection: Binding(
                        get: { presets.first(where: isSelected)?.id ?? -1 },
                        set: { id in
                            if let match = presets.first(where: { $0.id == id }) { value = match.value }
                        }
                    )) {
                        ForEach(presets) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 340)
                }
            }
        }
    }
}

// MARK: - Small parts

/// Restrained status pill. Used only where a state genuinely needs a word.
public struct StatusPill: View {
    public enum Tone {
        case good, warning, neutral, accent

        var color: Color {
            switch self {
            case .good: return Color(nsColor: .systemGreen)
            case .warning: return Color(nsColor: .systemOrange)
            case .accent: return Color.accentColor
            case .neutral: return Color.secondary
            }
        }
    }

    private let text: String
    private let tone: Tone

    public init(_ text: String, _ tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.color.opacity(0.13), in: Capsule())
    }
}

/// Small dot indicator paired with a status word.
public struct StatusIndicator: View {
    private let isGood: Bool
    private let text: String
    private let help: String?

    public init(isGood: Bool, text: String, help: String? = nil) {
        self.isGood = isGood
        self.text = text
        self.help = help
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isGood ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13))
        }
        .help(help ?? text)
    }
}

// MARK: - Key caps

/// Renders a single key as a macOS keycap.
public struct KeyCap: View {
    private let glyph: String

    public init(_ glyph: String) {
        self.glyph = glyph
    }

    public var body: some View {
        Text(glyph)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: 19)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 0.5, y: 0.5)
    }
}

// MARK: - Sidebar search

/// Search field for the sidebar, modelled on the System Settings sidebar filter.
public struct SidebarSearchField: View {
    @Binding private var text: String
    private let prompt: String

    public init(text: Binding<String>, prompt: String = "Search") {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.settingsWell, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
        )
    }
}

// MARK: - Preview surface

/// Neutral canvas used to frame live previews inside settings.
public struct PreviewSurface<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(Color.settingsWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.settingsHairline, lineWidth: 0.5)
            )
    }
}