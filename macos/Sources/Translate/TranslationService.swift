import Foundation

/// The translate boundary `CaptureCoordinator` depends on — the seam that lets
/// the orchestration (and its generation-token race) be unit-tested with a stub.
/// `TranslationService` is the production conformer.
protocol Translating {
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult
}

/// The single place a translation happens (TECH §3-4, §8.2).
///
/// Owns the full sequence so capture (and any future surface — clipboard, CLI)
/// never touches engines directly: **detect → guard → resolve → translate →
/// AI-fallback**. This replaces slice-3's interim `CaptureCoordinator.translateWithGuard`.
///
/// Detect-first, uniformly: a single keyless Google detect runs before every
/// translate regardless of the resolved engine, so the detected source is
/// authoritative on both the Google and AI paths (the AI path no longer reports
/// `.unavailable`). The small extra latency is an accepted default (TECH §3).
struct TranslationService: Translating {

    private let resolver: EngineResolver
    private let settings: SettingsStore
    /// Injected so unit tests can pin the detected source without the network.
    private let detect: (String) async -> DetectedSource
    /// The engine the runtime AI-error safety net retries on (TECH §4). A factory
    /// so a fresh Google engine is built per retry; injected for tests.
    private let makeGoogleFallback: () -> any TranslationEngine

    /// Production initializer — detects via a keyless Google call and falls back
    /// to a fresh `GoogleEngine` on the same session.
    init(
        resolver: EngineResolver = EngineResolver(),
        settings: SettingsStore = SettingsStore(),
        session: URLSession = .shared
    ) {
        self.init(
            resolver: resolver,
            settings: settings,
            detect: { await SourceDetector(session: session).detect($0) },
            makeGoogleFallback: { GoogleEngine(session: session) }
        )
    }

    /// Testable initializer — injects the detector and the fallback factory so
    /// orchestration can be exercised without the network (the resolved engine
    /// still comes from `resolver`, driven over a stubbed session).
    init(
        resolver: EngineResolver,
        settings: SettingsStore,
        detect: @escaping (String) async -> DetectedSource,
        makeGoogleFallback: @escaping () -> any TranslationEngine
    ) {
        self.resolver = resolver
        self.settings = settings
        self.detect = detect
        self.makeGoogleFallback = makeGoogleFallback
    }

    /// Translates `text` for `pair`, returning the translation plus the detected
    /// source, the engine that served it, and the authoritative "via Google" flag.
    ///
    /// Sequence:
    /// 1. **Detect** the source (keyless Google), uniformly across engines.
    /// 2. **Guard** — `PairResolver.effectiveTo` flips Auto + detected==to to the
    ///    secondary (preserves EN⇄ZH); uncertain/unavailable detection suppresses it.
    /// 3. **Resolve** the engine for the pair (`resolve(for:)`).
    /// 4. **Translate** the request `{text, from: pair.from, to: effectiveTo}`.
    /// 5. **Safety net** — an AI translate failure retries the same request once
    ///    on Google and flags `viaGoogleFallback`; a Google failure (or a
    ///    resolved-Google engine failing) propagates.
    func translate(text: String, pair: LanguagePair) async throws -> TranslationResult {
        let detected = await detect(text)
        let effectiveTo = PairResolver.effectiveTo(
            detected: detected, pair: pair, secondary: settings.secondaryLanguage
        )
        let request = TranslationRequest(text: text, from: pair.from, to: effectiveTo)
        // Resolve on the EFFECTIVE pair (post-guard target), not the pre-guard
        // `pair.to`: a guard flip can change which engine should serve the request
        // (a language whose AI route differs). Dormant today — every catalog
        // language has an `aiName` — but correct.
        let resolved = resolver.resolve(for: LanguagePair(from: pair.from, to: effectiveTo))

        do {
            let result = try await resolved.engine.translate(request)
            return TranslationResult(
                translation: result.translation,
                detected: detected,
                servedBy: result.servedBy,
                viaGoogleFallback: resolved.viaGoogleFallback,
                effectiveTo: effectiveTo
            )
        } catch {
            // Runtime AI→Google safety net (TECH §4): only an AI failure retries;
            // a Google failure has nothing to fall back to, so it propagates.
            guard resolved.engine.kind == .ai else { throw error }
            let result = try await makeGoogleFallback().translate(request)
            return TranslationResult(
                translation: result.translation,
                detected: detected,
                servedBy: result.servedBy,
                viaGoogleFallback: true,
                effectiveTo: effectiveTo
            )
        }
    }
}
