import SwiftUI
import KeyboardShortcuts

/// The Preferences window root — a standard macOS toolbar-tab layout with four
/// tabs (DESIGN §2d). Fixed width; height adapts per tab.
struct PreferencesView: View {

    let settings: SettingsStore
    let keychain: KeychainStore
    let launchAtLogin: LaunchAtLogin
    let accountModel: AccountViewModel

    var body: some View {
        TabView {
            GeneralTab(launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }

            EngineTab(settings: settings, keychain: keychain)
                .tabItem { Label("Engine", systemImage: "globe") }

            AccountTab(model: accountModel)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

// MARK: - General

/// Hotkey Recorder + Launch at login (DESIGN §2d, Fig 6).
private struct GeneralTab: View {

    let launchAtLogin: LaunchAtLogin

    @State private var launchEnabled: Bool
    @State private var launchError: String?

    init(launchAtLogin: LaunchAtLogin) {
        self.launchAtLogin = launchAtLogin
        _launchEnabled = State(initialValue: launchAtLogin.isEnabled)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Capture & Translate") {
                    // The KeyboardShortcuts Recorder — click, press a combo, done.
                    // No System Settings, no Accessibility permission (PRD G2).
                    KeyboardShortcuts.Recorder(for: .captureTranslate)
                }
                Text("Click the field and press a key combination. Default is ⌃⌥Y.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchEnabled)
                    .onChange(of: launchEnabled) { _, newValue in
                        do {
                            try launchAtLogin.setEnabled(newValue)
                            launchError = nil
                        } catch {
                            // Revert the toggle to reflect the real system state.
                            launchEnabled = launchAtLogin.isEnabled
                            launchError = error.localizedDescription
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Translate to Simplified Chinese or English automatically, "
                     + "based on what you capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

