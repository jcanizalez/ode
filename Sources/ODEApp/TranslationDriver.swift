import SwiftUI
import NaturalLanguage
import ODEKit
#if canImport(Translation)
import Translation
#endif

// All Translation-framework code lives here, availability-gated, so the rest
// of the app stays macOS 14-buildable. The driver watches the model's caption
// target, owns the TranslationSession via .translationTask, and continuously
// translates whatever segments the current transcript has that the model's
// cache lacks — which makes it work identically for live meetings (segments
// keep arriving) and saved ones (one big batch).

extension View {
    /// Attach translated-caption support to a transcript view. No-op below
    /// macOS 15 (the Translation framework's floor).
    @ViewBuilder
    func translationDriver(model: MeetingsModel,
                           transcript: @escaping () -> Transcript?) -> some View {
        if #available(macOS 15.0, *) {
            modifier(TranslationDriverModifier(model: model, transcript: transcript))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationDriverModifier: ViewModifier {
    @ObservedObject var model: MeetingsModel
    let transcript: () -> Transcript?
    @State private var config: TranslationSession.Configuration?
    /// Source language detected from the transcript itself. Passing an
    /// explicit source to the framework is what stops it from showing
    /// "confirm the source language" sheets on every ambiguous batch.
    @State private var sourceID: String?

    func body(content: Content) -> some View {
        content
            .task { await loadSupportedTargets() }
            .task(id: model.captionTargetID) { await detectSourceLoop() }
            .onChange(of: sourceID) { rebuildConfig() }
            .onChange(of: model.captionTargetID) { rebuildConfig() }
            .translationTask(config) { session in
                await translateContinuously(session)
            }
    }

    /// Watch the transcript until it has enough text to identify the spoken
    /// language confidently (live meetings start with too little). Restarts
    /// whenever the caption target changes.
    private func detectSourceLoop() async {
        guard model.captionTargetID != nil else { return }
        while !Task.isCancelled {
            if let detected = detectDominantLanguage() {
                if detected != sourceID { sourceID = detected }
                // Keep watching: a meeting can drift languages; if the
                // dominant changes, the config rebuilds with the new source.
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func detectDominantLanguage() -> String? {
        guard let t = transcript() else { return nil }
        let text = t.ordered.suffix(60).map(\.text).joined(separator: " ")
        guard text.count >= 40 else { return nil }  // too little to be sure
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(2_000)))
        guard let lang = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang],
              confidence > 0.6 else { return nil }
        return lang.rawValue
    }

    /// The full runtime-queried language list — ODE gains languages the
    /// moment Apple ships them.
    private func loadSupportedTargets() async {
        guard model.supportedTargets.isEmpty else { return }
        let langs = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        let targets: [(id: String, name: String)] = langs.compactMap { lang in
            let id = lang.minimalIdentifier
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            let name = Locale.current.localizedString(forIdentifier: id) ?? id
            return (id, name.prefix(1).capitalized + name.dropFirst())
        }
        .sorted { $0.name < $1.name }
        model.supportedTargets = targets
    }

    private func rebuildConfig() {
        guard let targetID = model.captionTargetID else {
            config = nil
            model.translating = false
            return
        }
        guard let sourceID else {
            // Not enough transcript yet to know the spoken language — the
            // detection loop will set it; show the working state meanwhile.
            config = nil
            model.translating = true
            return
        }
        // Speaking the target language already? Nothing to translate.
        if Locale.Language(identifier: sourceID).languageCode ==
           Locale.Language(identifier: targetID).languageCode {
            config = nil
            model.translating = false
            model.translationNote = String(
                localized: "The meeting is already in this language.")
            return
        }
        model.translationNote = nil
        config = TranslationSession.Configuration(
            source: Locale.Language(identifier: sourceID),
            target: Locale.Language(identifier: targetID))
    }

    /// Runs for the lifetime of one configuration (SwiftUI cancels and
    /// restarts it when the target changes). Batches whatever the transcript
    /// has that the cache lacks, then naps — live meetings keep feeding it.
    ///
    /// Failure handling matters more than the happy path here: the first
    /// batch often fails transiently (language pack warming up), and one
    /// too-short segment ("ok") can be unidentifiable and would otherwise
    /// poison the whole batch. So: batch first; on batch failure retry each
    /// segment individually; give up on a segment only after 3 strikes
    /// (empty-string sentinel — the row just shows no caption); and surface
    /// a status note only when failures PERSIST, not on the first hiccup.
    private func translateContinuously(_ session: TranslationSession) async {
        try? await session.prepareTranslation()  // language download if needed
        var strikes: [TranscriptSegment.ID: Int] = [:]
        var quietPassesFailed = 0
        defer { Task { @MainActor in model.translating = false } }
        while !Task.isCancelled {
            if let t = transcript() {
                let pending = t.ordered.filter { seg in
                    model.translations[seg.id] == nil &&
                    !seg.text.trimmingCharacters(in: .whitespaces).isEmpty
                }
                model.translating = !pending.isEmpty
                if !pending.isEmpty {
                    var byClientID: [String: TranscriptSegment.ID] = [:]
                    let requests = pending.map { seg -> TranslationSession.Request in
                        let cid = UUID().uuidString
                        byClientID[cid] = seg.id
                        return TranslationSession.Request(sourceText: seg.text,
                                                          clientIdentifier: cid)
                    }
                    var anySuccess = false
                    do {
                        let responses = try await session.translations(from: requests)
                        for r in responses {
                            if let cid = r.clientIdentifier, let segID = byClientID[cid] {
                                model.translations[segID] = r.targetText
                                anySuccess = true
                            }
                        }
                    } catch {
                        // Batch failed — try each segment alone so one bad
                        // apple doesn't block the rest.
                        for seg in pending {
                            do {
                                let r = try await session.translations(from:
                                    [TranslationSession.Request(sourceText: seg.text)])
                                if let first = r.first {
                                    model.translations[seg.id] = first.targetText
                                    anySuccess = true
                                }
                            } catch {
                                let count = (strikes[seg.id] ?? 0) + 1
                                strikes[seg.id] = count
                                if count >= 3 {
                                    // Untranslatable (too short, ambiguous):
                                    // stop retrying; the row shows no caption.
                                    model.translations[seg.id] = ""
                                }
                            }
                        }
                    }
                    if anySuccess {
                        quietPassesFailed = 0
                        model.translationNote = nil
                        model.translating = false
                    } else {
                        quietPassesFailed += 1
                        // Only speak up when it KEEPS failing (pack download,
                        // unsupported pair) — never for a first-pass hiccup.
                        if quietPassesFailed >= 3 {
                            model.translationNote = String(
                                localized: "Preparing translation… (the language may still be downloading)")
                        }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
