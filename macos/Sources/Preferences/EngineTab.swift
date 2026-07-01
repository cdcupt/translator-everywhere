import AppKit
import SwiftUI

/// The live state of an OpenAI key Test (DESIGN §2d, Fig 7).
enum EngineTestState: Equatable {
    case idle
    case testing
    case ok
    case failed(String)
}

/// Engine selection + OpenAI key field + Test (DESIGN §2d, Fig 7).
///
/// A segmented control defaults to Free (Vision + Google). Selecting OpenAI
/// reveals the key field, a Keychain note, and a Test button that runs one real
/// sample translation. Free stays selectable even with a key present (PRD §5).
struct EngineTab: View {

    let settings: SettingsStore
    let keychain: KeychainStore
    /// Drives the "Sync this key across my Macs" toggle + auto-restore (TECH §3).
    let keySync: KeySyncService

    @State private var preference: EnginePreference
    @State private var apiKey: String
    @State private var testState: EngineTestState = .idle
    /// Drives the key field's focus ring so committing (⏎) or clicking away drops
    /// it — the standard "click-outside-deselects" behavior (FIX 1).
    @FocusState private var keyFieldFocused: Bool

    /// Sample text for the live Test call.
    private static let testSample = "Hello"

    /// Target for the live Test call — any valid pair proves the key works; 中文
    /// is the seeded home target. Catalog fallback is purely defensive.
    private static let testTarget: Language =
        LanguageCatalog.language(forCode: "zh-CN")
        ?? Language(code: "zh-CN", englishName: "Chinese (Simplified)", endonym: "简体中文",
                    googleCode: "zh-CN", aiName: "Simplified Chinese", aliases: [])

    init(settings: SettingsStore, keychain: KeychainStore, keySync: KeySyncService) {
        self.settings = settings
        self.keychain = keychain
        self.keySync = keySync
        _preference = State(initialValue: settings.enginePreference)
        _apiKey = State(
            initialValue: keychain.string(for: KeychainStore.openAIKeyAccount) ?? ""
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $preference) {
                    Text("Free (Vision + Google)").tag(EnginePreference.free)
                    Text("OpenAI").tag(EnginePreference.openai)
                }
                .pickerStyle(.segmented)
                .onChange(of: preference) { _, newValue in
                    settings.enginePreference = newValue
                }
            }

            if preference == .openai {
                Section("OpenAI API key") {
                    SecureField("Paste your key (sk-…)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFieldFocused)
                        // Committing the field (⏎) drops the focus ring too.
                        .onSubmit { keyFieldFocused = false }
                        .onChange(of: apiKey) { _, newValue in
                            persistKey()
                            testState = .idle
                            // Re-upload on edit when sync is ON; a no-op otherwise.
                            Task { await keySync.uploadIfEnabled(key: newValue) }
                        }

                    // Empty-state hint: the field is BYOK, and OpenAI isn't active
                    // until a key is present (the engine falls back to Free).
                    if trimmedKey.isEmpty {
                        Label("Paste your own OpenAI API key above to turn on the "
                              + "OpenAI engine. Until then, translation uses "
                              + "Free (Vision + Google).",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Field-level "reached the server" confirmation (FIX 2). Only
                    // rendered while sync is ON — that's the only time the key is
                    // uploaded; when OFF it stays local-only (Keychain).
                    accountSaveStatusView

                    syncControls

                    HStack {
                        Button("Test") { runTest() }
                            .disabled(trimmedKey.isEmpty || testState == .testing)
                        testStatusView
                    }
                }
            }
        }
        .formStyle(.grouped)
        // Click-outside-deselects: a window-level mouse-down monitor drops the key
        // field's focus ring when the click lands anywhere but a text field (FIX 1).
        .background(FocusResignOnOutsideClick())
        // Don't-clobber prompt: a restore found a *different* local key.
        .alert(
            "Use this Mac's key or the synced one?",
            isPresented: Binding(
                get: { keySync.pendingConflict != nil },
                set: { presenting in if !presenting { keySync.resolveConflictKeepingLocal() } }
            )
        ) {
            // First button is the default (⏎) — keep local, per DESIGN §3.
            Button("Keep this Mac's key") { keySync.resolveConflictKeepingLocal() }
            Button("Use synced key") {
                keySync.resolveConflictAdoptingSynced()
                apiKey = keychain.string(for: KeychainStore.openAIKeyAccount) ?? apiKey
            }
        } message: {
            Text("This Mac already has an OpenAI key saved. Keep it, or replace it "
                 + "with the key synced from your account?")
        }
    }

    /// The sync toggle, its disabled-reason, the context-sensitive privacy copy,
    /// and the restored-key confirmation (TECH §3.3, R5). The live save status is
    /// now surfaced at the field itself via `accountSaveStatusView` (FIX 2).
    @ViewBuilder
    private var syncControls: some View {
        Toggle("Sync this key across my Macs", isOn: Binding(
            get: { keySync.isEnabled },
            set: { turnOn in
                Task {
                    if turnOn { await keySync.enable(key: trimmedKey) }
                    else { await keySync.disable() }
                }
            }
        ))
        .disabled(syncDisabledReason != nil)

        if let reason = syncDisabledReason {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Truth-in-UI: the copy flips with the sync state (DESIGN §5).
        Label(keySync.isEnabled ? KeySyncCopy.engineSyncOn : KeySyncCopy.engineSyncOff,
              systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)

        if keySync.showRestoredToast {
            Label(KeySyncCopy.restoredToast, systemImage: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    /// The reason the toggle is disabled (signed out / no key), or `nil`.
    private var syncDisabledReason: String? {
        keySync.syncDisabledReason(hasKey: !trimmedKey.isEmpty)
    }

    /// A field-level "reached the server" confirmation (FIX 2). Renders only when
    /// sync is ON — mapping via the pure `accountSaveStatus` so the copy is unit-
    /// tested and can never claim a server save while the key is local-only.
    @ViewBuilder
    private var accountSaveStatusView: some View {
        if let status = Self.accountSaveStatus(state: keySync.state, syncEnabled: keySync.isEnabled) {
            switch status.kind {
            case .saving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status.text).font(.caption).foregroundStyle(.secondary)
                }
            case .saved:
                Label(status.text, systemImage: "icloud.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed:
                Label(status.text, systemImage: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Key works", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    /// Writes the current key to the Keychain (empty input clears it).
    private func persistKey() {
        try? keychain.set(apiKey, for: KeychainStore.openAIKeyAccount)
    }

    /// Runs one sample translation via `OpenAIEngine` and reports OK / error.
    private func runTest() {
        persistKey()
        let key = trimmedKey
        guard !key.isEmpty else { return }
        testState = .testing
        Task {
            let engine = OpenAIEngine(apiKey: key)
            do {
                let request = TranslationRequest(text: Self.testSample, from: nil, to: Self.testTarget)
                _ = try await engine.translate(request)
                await MainActor.run { testState = .ok }
            } catch {
                await MainActor.run {
                    testState = .failed(Self.message(for: error))
                }
            }
        }
    }

    /// Human-readable reason for a failed Test.
    private static func message(for error: Error) -> String {
        if let translationError = error as? TranslationError {
            switch translationError {
            case .api(let message):
                return message
            case .network:
                return "Couldn't reach OpenAI. Check your connection."
            default:
                return translationError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: - Account save status (FIX 2, testable mapping)

    /// The field-level save-status line, derived purely from the sync state so QA
    /// can assert the copy without mounting the view.
    ///
    /// Returns `nil` when sync is OFF: the key is then stored only in this Mac's
    /// Keychain, so we must NOT claim it reached the server ("…to your account"
    /// wording is only honest while sync is ON). `now` is injectable for tests.
    static func accountSaveStatus(
        state: KeySyncState,
        syncEnabled: Bool,
        now: Date = Date()
    ) -> AccountSaveStatus? {
        guard syncEnabled else { return nil }
        switch state {
        case .off:
            return nil
        case .syncing:
            return AccountSaveStatus(kind: .saving, text: "Saving…")
        case .synced(let date):
            return AccountSaveStatus(
                kind: .saved,
                text: "Saved to your account ✓ · \(savedTimeDescription(date, now: now))"
            )
        case .failed(let message):
            return AccountSaveStatus(
                kind: .failed,
                text: "Couldn't save to your account — \(message)"
            )
        }
    }

    /// A short, non-ticking timestamp for the "Saved" line: "just now" within the
    /// last minute, otherwise a short clock time (e.g. "10:42 AM").
    private static func savedTimeDescription(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Click-outside-deselects (FIX 1)

    /// Whether a left-click resolving to `hitView` should drop keyboard focus.
    /// Clicks inside an editable text field (the key field or its field editor)
    /// keep focus; clicks anywhere else — labels, the toggle, buttons, blank Form
    /// space — resign it. Walks the ancestry so a hit on a field's internal
    /// subview still counts as "inside the text". Mirrors `ResultPanel`'s v1.2.3
    /// deselect precedent.
    static func clickShouldResignFocus(forHit hitView: NSView?) -> Bool {
        var view = hitView
        while let current = view {
            if current is NSTextView || current is NSTextField { return false }
            view = current.superview
        }
        return true
    }
}

/// The visual kind + copy of the field-level save-status line (FIX 2). A plain
/// value so the state→string mapping is unit-testable without mounting the view.
struct AccountSaveStatus: Equatable {
    enum Kind: Equatable { case saving, saved, failed }
    let kind: Kind
    let text: String
}

/// Drops keyboard focus (and the SecureField's focus ring) when the user clicks
/// anywhere in the Preferences window that isn't a text field — the standard
/// macOS "click-outside-deselects" behavior (FIX 1). A SwiftUI `.onTapGesture`
/// on a grouped Form's background is unreliable because the Form's backing
/// `NSScrollView` swallows blank-area clicks, so we watch the window's
/// left-mouse-downs with a local event monitor and resign at the AppKit level.
private struct FocusResignOnOutsideClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MonitorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Re-arm per window move; tear down when the tab leaves the hierarchy.
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      let contentView = window.contentView
                else { return event }
                let point = contentView.convert(event.locationInWindow, from: nil)
                if EngineTab.clickShouldResignFocus(forHit: contentView.hitTest(point)) {
                    window.makeFirstResponder(nil)
                }
                return event   // never consume — normal dispatch is untouched
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
