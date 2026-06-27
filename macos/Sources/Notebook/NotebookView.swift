import SwiftUI
import SwiftData
import AppKit

/// The Vocabulary Notebook window body (DESIGN §2c).
///
/// A reverse-chronological table of captures with search, multi-select, soft
/// delete, export (CSV / Markdown), and a client-side Summarize. Works fully
/// local-only; no account or network. The view reads from `NotebookStore` and
/// re-fetches on change rather than binding `@Query` directly, so it stays
/// usable with the injected (possibly in-memory) store.
struct NotebookView: View {

    let store: NotebookStore
    /// Resolves the active engine at call time for Summarize (mirrors capture).
    let resolver: EngineResolver

    @State private var items: [VocabItem] = []
    @State private var searchText = ""
    @State private var selection = Set<UUID>()

    @State private var isSummarizing = false
    @State private var summaryText: String?
    @State private var errorMessage: String?
    @State private var pendingDelete: [VocabItem] = []
    @State private var showDeleteConfirm = false

    /// Transient confirmation toast (e.g. after copying the study prompt).
    @State private var toast: String?
    /// Distinguishes successive toasts so an older auto-dismiss can't clear a
    /// newer message.
    @State private var toastToken = 0

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(minWidth: 720, minHeight: 420)
        .overlay(alignment: .bottom) { toastOverlay }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search captures…")
        .onChange(of: searchText) { _, _ in reload() }
        .toolbar { toolbarContent }
        .onAppear(perform: reload)
        .sheet(item: Binding(
            get: { summaryText.map(IdentifiedString.init) },
            set: { summaryText = $0?.value }
        )) { summary in
            SummarySheet(text: summary.value, store: store, items: items)
        }
        .alert("Couldn’t complete that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(deleteConfirmTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("This removes it from this Mac (and the cloud, if you're synced). This can't be undone.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty && searchText.isEmpty {
            emptyState
        } else {
            table
            footer
        }
    }

    /// Transient confirmation capsule shown after a copy/hand-off action.
    @ViewBuilder
    private var toastOverlay: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .padding(.bottom, 52)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var table: some View {
        Table(items, selection: $selection) {
            TableColumn("Source") { item in
                Text(item.sourceText).lineLimit(2)
            }
            TableColumn("Translation") { item in
                Text(item.translation).lineLimit(2)
            }
            TableColumn("Languages") { item in
                Text("\(item.srcLang) → \(item.tgtLang)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .width(110)
            TableColumn("Engine") { item in
                EngineBadge(kind: item.engineKind)
            }
            .width(64)
            TableColumn("Tag") { item in
                Text(item.tag ?? "—").foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Date") { item in
                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .width(130)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerLabel).foregroundStyle(.secondary).font(.callout)
            Spacer()
            Button(role: .destructive) {
                pendingDelete = selectedItems
                showDeleteConfirm = true
            } label: {
                Label("Delete selected", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No captures yet")
                .font(.system(.title2, design: .serif))
            Text("Press ⌃⌥Y and drag a box around any text — every translation you make lands here automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("As CSV…") { export(.csv) }
                Button("As Markdown…") { export(.markdown) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(items.isEmpty)

            Menu {
                Button("Copy study prompt") { copyStudyPrompt() }
                Button("Open ChatGPT") { openInChatGPT() }
            } label: {
                Label("Ask your AI", systemImage: "sparkles")
            }
            .help("Copy a ready-to-paste study prompt for your own AI (ChatGPT, Claude, …)")
            .disabled(items.isEmpty)

            Button {
                summarize()
            } label: {
                if isSummarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Summarize", systemImage: "star")
                }
            }
            .disabled(items.isEmpty || isSummarizing)
        }
    }

    // MARK: - Derived

    private var selectedItems: [VocabItem] {
        items.filter { selection.contains($0.clientUUID) }
    }

    private var footerLabel: String {
        if selection.isEmpty {
            return items.count == 1 ? "1 capture" : "\(items.count) captures"
        }
        return "\(selection.count) of \(items.count) selected"
    }

    private var deleteConfirmTitle: String {
        let n = pendingDelete.count
        return n == 1 ? "Delete 1 capture?" : "Delete \(n) captures?"
    }

    // MARK: - Actions

    private func reload() {
        do {
            items = try store.all(matching: searchText)
            // Drop selections that no longer match the filter.
            let visible = Set(items.map(\.clientUUID))
            selection = selection.intersection(visible)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performDelete() {
        do {
            for item in pendingDelete {
                try store.softDelete(item)
            }
            pendingDelete = []
            selection = []
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export(_ format: NotebookStore.ExportFormat) {
        let chosen = selectedItems.isEmpty ? items : selectedItems
        let text = store.export(items: chosen, as: format)
        SavePanelPresenter.present(text: text, format: format)
    }

    private func summarize() {
        let chosen = selectedItems.isEmpty ? items : selectedItems
        guard !chosen.isEmpty else {
            errorMessage = "Summarize needs at least one capture. Translate something first, then come back."
            return
        }
        isSummarizing = true
        let engine = resolver.resolve()
        Task {
            do {
                let result = try await engine.summarize(chosen)
                await MainActor.run {
                    summaryText = result
                    isSummarizing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isSummarizing = false
                }
            }
        }
    }

    // MARK: - Hand off to the user's own AI

    /// Writes a ready-to-paste study prompt for the chosen captures onto the
    /// pasteboard. Returns `false` (and shows nothing) when there's nothing to
    /// act on. Selection wins; otherwise everything — same rule as Export.
    @discardableResult
    private func copyPromptToPasteboard() -> Bool {
        let chosen = selectedItems.isEmpty ? items : selectedItems
        guard !chosen.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(StudyListFormatter.studyPrompt(chosen), forType: .string)
        return true
    }

    private func copyStudyPrompt() {
        guard copyPromptToPasteboard() else { return }
        showToast("Prompt copied — paste it into your AI")
    }

    private func openInChatGPT() {
        guard copyPromptToPasteboard() else { return }
        if let url = URL(string: "https://chatgpt.com/") {
            NSWorkspace.shared.open(url)
        }
        showToast("Prompt copied — paste it into ChatGPT")
    }

    private func showToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                if toastToken == token { toast = nil }
            }
        }
    }
}

/// The FREE / AI engine badge as a small colored capsule.
private struct EngineBadge: View {
    let kind: EngineKind
    var body: some View {
        Text(kind.badge)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind == .ai ? Color.purple : Color.blue, in: Capsule())
    }
}

/// Wraps a `String` so it can drive a `.sheet(item:)`. Uses a fresh `id` per
/// instance so re-summarizing to *identical* text still re-presents the sheet
/// (a value-based id would suppress the transition).
private struct IdentifiedString: Identifiable {
    let id = UUID()
    let value: String
}
