import AppKit
import SwiftUI

/// First-run window. Explains the single permission Iume needs and reflects the
/// live TCC state, so the user never has to guess whether the grant worked.
@MainActor
public final class WelcomeWindowController {
    public static let shared = WelcomeWindowController()

    private var window: NSWindow?

    private init() {}

    public func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView { [weak self] in
                self?.dismiss()
            })
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to Iume"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        // Remember the choice so launch does not nag. The menu keeps a way back in.
        SettingsStore.applicationDefaults.set(true, forKey: "iume.hasDismissedWelcome")
        window?.close()
    }
}

// MARK: - View

struct WelcomeView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    let onClose: () -> Void

    private var granted: Bool { permissions.hasAccessibilityPermission }

    /// The bundle has no custom .icns yet, so a real app icon is used when it exists and a
    /// deliberate mark (the menu-bar symbol on an accent tile) stands in until then.
    @ViewBuilder
    private var appMark: some View {
        if let icon = NSApp.applicationIconImage,
           Bundle.main.infoDictionary?["CFBundleIconFile"] as? String != nil {
            Image(nsImage: icon)
                .resizable()
                .accessibilityHidden(true)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color(nsColor: .controlAccentColor).gradient)
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                appMark
                    .frame(width: 76, height: 76)

                Text("Welcome to Iume")
                    .font(.system(size: 24, weight: .semibold))

                Text("A continuous strip for the windows on your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            .padding(.bottom, 24)

            permissionRow
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .padding(.horizontal, 32)

            Text("Iume moves and resizes windows through macOS Accessibility. You can change this later in System Settings › Privacy & Security › Accessibility.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.top, 12)

            Spacer(minLength: 20)

            HStack(spacing: 12) {
                Button("Open Settings") {
                    StatusBarController.openSettingsWindow()
                    onClose()
                }
                .buttonStyle(.link)

                Spacer(minLength: 0)

                Text("Vibecoded by BvesRoy 😉")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)

                Button(granted ? "Start Using Iume" : "Continue") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility Access")
                    .font(.system(size: 13, weight: .medium))

                Text(granted
                     ? "Granted — Iume can arrange your windows."
                     : "Required to move and resize windows on your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                Button("Grant Access") {
                    PermissionManager.shared.requestPermissionExplicitly()
                }
                .controlSize(.small)
            }
        }
        .padding(14)
    }
}
