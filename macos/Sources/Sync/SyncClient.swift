import Foundation

/// Speaks the §7 backend contract (TECH §8.5).
///
/// An `actor` over `URLSession`: background, best-effort, debounced; never
/// blocks the popup. Strictly additive — remove it and the app is a complete
/// local-only product. Stub for slice 1.
actor SyncClient {
    func sync() async {
        // TODO(slice: sync): push/pull vocab rows; last-write-wins (§7).
    }
}
