import Foundation

/// The local notebook + offline change queue (TECH §8.3).
///
/// Backed by SwiftData; the single source of truth the UI binds to. Emits dirty
/// rows to `SyncClient`. The app is fully usable with no account and no network.
/// Stub for slice 1 (the SwiftData `ModelContainer` arrives with the notebook
/// slice).
final class NotebookStore {
    // TODO(slice: notebook): SwiftData ModelContainer + VocabItem model.
}
