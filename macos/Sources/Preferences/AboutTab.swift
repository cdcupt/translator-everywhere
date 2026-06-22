import SwiftUI

/// App name, version/build, links, and the `te` CLI mention (DESIGN §2d, Fig 8).
///
/// The standalone "About" menu item shows this same content. Version and build
/// are read from the bundle so they track `MARKETING_VERSION` /
/// `CURRENT_PROJECT_VERSION` without manual edits.
struct AboutTab: View {

    /// Placeholder repository URL (the real repo is private; updated at ship).
    static let gitHubURL = URL(string: "https://github.com/cdcupt/translator-everywhere")!

    /// Privacy Policy placeholder (DESIGN §4 — "Privacy Policy ↗").
    static let privacyPolicyURL = URL(string: "https://translator-everywhere.app/privacy")!

    var body: some View {
        VStack(spacing: 12) {
            Text("Translator Everywhere")
                .font(.title2.weight(.semibold))

            Text("Version \(Self.version) (\(Self.build))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Select any text on screen, press ⌃⌥Y, and read it in your "
                 + "language. OCR runs on-device; nothing but the text you draw "
                 + "leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Prefer the terminal? The companion `te` CLI does the same "
                 + "translation from the command line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                Link("GitHub", destination: Self.gitHubURL)
                Text("·").foregroundStyle(.secondary)
                Text("MIT License").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.secondary)
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
            }
            .font(.callout)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    /// `CFBundleShortVersionString`, e.g. "1.0.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "1.0.0"
    }

    /// `CFBundleVersion`, e.g. "1".
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "1"
    }
}
