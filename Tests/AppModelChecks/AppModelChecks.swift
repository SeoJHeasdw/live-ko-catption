import CaptionCore
import Foundation

struct ModelCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ModelCheckFailure(description: message) }
}

@MainActor
func waitUntil(_ message: String, seconds: Double = 2,
               condition: @MainActor () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else {
            throw ModelCheckFailure(description: message)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Holding continuations deliberately ignores cancellation, like a stuck system
/// framework. Tests release them afterward and verify their late output is inert.
@MainActor
final class TranslatorProbe {
    struct Call: Equatable {
        let source: String
        let context: Bool
    }
    var calls: [Call] = []
    var heldSources: Set<String> = []
    var holdContexts = false
    var failuresRemaining: [String: Int] = [:]
    var cancellationsRemaining: [String: Int] = [:]
    var responseDelay: Duration?
    var rejectsForCapacity = false
    private var held: [(Call, CheckedContinuation<String, any Error>)] = []

    func translate(_ source: String, context: Bool) async throws -> String {
        let call = Call(source: source, context: context)
        calls.append(call)
        if rejectsForCapacity { throw TranslationSessionLease.CapacityReached(lane: .live) }
        if heldSources.contains(source) || (context && holdContexts) {
            return try await withCheckedThrowingContinuation { held.append((call, $0)) }
        }
        if let responseDelay { try await Task.sleep(for: responseDelay) }
        if let remaining = cancellationsRemaining[source], remaining > 0 {
            cancellationsRemaining[source] = remaining - 1
            throw CancellationError()
        }
        if let remaining = failuresRemaining[source], remaining > 0 {
            failuresRemaining[source] = remaining - 1
            throw ModelCheckFailure(description: "Injected translation failure")
        }
        return "KO: \(source)"
    }

    func release(source: String? = nil, context: Bool? = nil, translation: String) {
        let matching = held.filter {
            (source == nil || $0.0.source == source) && (context == nil || $0.0.context == context)
        }
        held.removeAll {
            (source == nil || $0.0.source == source) && (context == nil || $0.0.context == context)
        }
        for (_, continuation) in matching { continuation.resume(returning: translation) }
    }

    func failHeldContexts() {
        let matching = held.filter { $0.0.context }
        held.removeAll { $0.0.context }
        for (_, continuation) in matching {
            continuation.resume(throwing: ModelCheckFailure(description: "Injected context failure"))
        }
    }

    func releaseAll() {
        let pending = held
        held.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: "Ignored late response") }
    }
}

@MainActor
final class PermissionProbe {
    var calls = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    func request() async -> Bool {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func releaseFirst(_ allowed: Bool) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: allowed)
    }

    func releaseAll() {
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: false) }
    }
}

@MainActor
final class ReadinessProbe {
    var calls: [CaptionDirection] = []
    private var waiting: [(CaptionDirection, CheckedContinuation<Bool, any Error>)] = []

    func check(_ direction: CaptionDirection) async throws -> Bool {
        calls.append(direction)
        return try await withCheckedThrowingContinuation { waiting.append((direction, $0)) }
    }

    func release(_ direction: CaptionDirection, ready: Bool) {
        guard let index = waiting.firstIndex(where: { $0.0 == direction }) else { return }
        waiting.remove(at: index).1.resume(returning: ready)
    }

    func fail(_ direction: CaptionDirection) {
        guard let index = waiting.firstIndex(where: { $0.0 == direction }) else { return }
        waiting.remove(at: index).1.resume(throwing: ModelCheckFailure(description: "Old pair unavailable"))
    }

    func releaseAll() {
        let pending = waiting
        waiting.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: false) }
    }
}

/// Optional local refinement deliberately ignores cancellation when held, so a
/// deadline or a new conversation must make its eventual output harmless.
@MainActor
final class PolisherProbe {
    var calls: [LocalTranslationRequest] = []
    var heldSources: Set<String> = []
    var failingSources: Set<String> = []
    var nativeTimeoutSources: Set<String> = []
    private var held: [(String, CheckedContinuation<String, any Error>)] = []

    func polish(_ request: LocalTranslationRequest) async throws -> String {
        calls.append(request)
        if heldSources.contains(request.source) {
            return try await withCheckedThrowingContinuation { held.append((request.source, $0)) }
        }
        if failingSources.contains(request.source) {
            throw ModelCheckFailure(description: "Injected optional polish failure")
        }
        if nativeTimeoutSources.contains(request.source) {
            throw LocalTranslationError.native(2, "Injected native context timeout")
        }
        return "다듬은 자막: \(request.source)"
    }

    func release(source: String, translation: String) {
        let matching = held.filter { $0.0 == source }
        held.removeAll { $0.0 == source }
        for (_, continuation) in matching { continuation.resume(returning: translation) }
    }

    func releaseAll() {
        let pending = held
        held.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: "무시해야 하는 늦은 보정") }
    }
}

@MainActor
func makePolishModel(_ translator: TranslatorProbe, polisher: PolisherProbe,
                     defaults: UserDefaults, timeout: Double = 1.8) -> CaptionModel {
    let model = CaptionModel(translationOverride: { source, isContext in
        try await translator.translate(source, context: isContext)
    }, preferencesDefaults: defaults, polishOverride: {
        try await polisher.polish($0)
    }, polishTimeoutSeconds: timeout)
    model.isChecking = false
    model.assetsReady = true
    model.contextCorrectionEnabled = false
    model.polishEnabled = true
    return model
}

@MainActor
func makeModel(_ probe: TranslatorProbe, context: Bool = false) -> CaptionModel {
    let model = CaptionModel(translationOverride: { source, isContext in
        try await probe.translate(source, context: isContext)
    })
    model.isChecking = false
    model.assetsReady = true
    model.contextCorrectionEnabled = context
    return model
}

@main @MainActor
struct AppModelChecks {
    static func main() async {
        let savedContextPreference = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        defer {
            if let savedContextPreference {
                UserDefaults.standard.set(savedContextPreference, forKey: "contextCorrectionEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled")
            }
        }
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("saved enabled refinement blocks microphone start until preparation or safe fallback", {
                let suite = "LiveKoCaption.SavedPolishReadinessChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(true, forKey: "localPolishEnabled")
                var microphoneRequests = 0
                let missingRuntime = FileManager.default.temporaryDirectory
                    .appendingPathComponent("missing-caption-runtime-\(UUID().uuidString).dylib")
                let model = CaptionModel(microphoneAccessOverride: {
                    microphoneRequests += 1
                    return false
                }, readinessOverride: { _ in true }, preferencesDefaults: defaults,
                    localEngine: LocalTranslationEngine(runtimeURL: missingRuntime))
                try expect(model.polishEnabled && !model.isPreparingLocalModel,
                    "Saved enabled setting did not restore before local preparation begins")
                await model.checkReadiness()
                try expect(model.assetsReady && !model.isChecking && !model.canStart,
                    "Apple readiness opened Start while saved local refinement was still unprepared")
                await model.start()
                try expect(microphoneRequests == 0 && model.phase == .idle,
                    "Unprepared saved refinement admitted microphone startup")
                // A deliberately absent runtime cannot load a model or perform
                // GPU inference. An absent model file is an equivalent fallback.
                await model.prepareLocalModel()
                try expect(!model.polishEnabled && !model.isPreparingLocalModel && model.canStart,
                    "Unavailable local preparation did not restore the fast engine's Start control")
                try expect(!defaults.bool(forKey: "localPolishEnabled") && microphoneRequests == 0,
                    "Safe fallback left an enabled unprepared preference or requested microphone access")
            }),
            ("enabling refinement blocks Start synchronously before its preparation task runs", {
                let suite = "LiveKoCaption.TogglePolishReadinessChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(true, forKey: "localPolishEnabled")
                let model = CaptionModel(translationOverride: { _, _ in "빠른 번역입니다." },
                    preferencesDefaults: defaults, polishOverride: { _ in "다듬은 번역입니다." })
                model.isChecking = false
                model.assetsReady = true
                try expect(!model.polishEnabled && model.canStart,
                    "Injected baseline fixture unexpectedly restored an enabled native model")
                model.polishEnabled = true
                try expect(model.polishEnabled && !model.canStart && !model.isPreparingLocalModel,
                    "Toggle-on left a gap admitting Start before the preparation task's first actor turn")
                await model.prepareLocalModel()
                try expect(model.canStart && model.polishEnabled,
                    "Prepared injected refinement did not restore Start without model loading")
                model.polishEnabled = false
                try expect(model.canStart, "Toggle-off unnecessarily kept the fast engine blocked")
                model.polishEnabled = true
                try expect(!model.canStart, "A later toggle reused an obsolete prepared readiness flag")
                await model.prepareLocalModel()
                try expect(model.canStart, "A later successful preparation did not publish readiness")
            }),
            ("fast Apple baseline is visible and gray until exact final refinement completes", {
                let suite = "LiveKoCaption.PolishBaselineChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["A final sentence."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                try expect(model.polishEnabled, "Injected optional refinement could not be enabled without installing a model")
                model.receive(source: "A final sentence.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Baseline waited for the held local model") {
                    polisher.calls.count == 1 && model.segments.first?.translation == "KO: A final sentence."
                }
                let awaiting = model.segments[0]
                try expect(awaiting.sourceIsFinal && !awaiting.isFinal && awaiting.translatedRevision != awaiting.revision,
                    "Pending optional refinement was shown as finalized")
                try expect(model.displaySegments.first?.isFinal == false && model.hasPendingTranslations,
                    "Gray baseline/pending presentation was lost")
                try expect(polisher.calls[0].source == awaiting.source && polisher.calls[0].baseline == awaiting.translation,
                    "Local refinement was not given the exact current source and Apple baseline")
                polisher.release(source: "A final sentence.", translation: "완료된 문장입니다.")
                try await waitUntil("Validated local result did not finalize") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(model.segments[0].translation == "완료된 문장입니다." && model.segments[0].source == awaiting.source &&
                    model.segments[0].revision == awaiting.revision, "Refinement changed source records or used an unrelated revision")
                try expect(model.segments[0].translationError == nil && translator.calls.count == 1,
                    "Successful refinement created failure state or duplicate baseline work")
            }),
            ("partials remain Apple-only and an unchanged final is refined exactly once", {
                let suite = "LiveKoCaption.PolishPartialChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["An unchanged sentence."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "An unchanged sentence.", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Partial baseline was not translated") {
                    model.segments.first?.translation == "KO: An unchanged sentence." && !model.hasPendingTranslations
                }
                try expect(polisher.calls.isEmpty && model.segments.first?.isFinal == false,
                    "A provisional source triggered local GPU refinement")
                model.receive(source: "An unchanged sentence.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Confirming an unchanged draft skipped final refinement") { polisher.calls.count == 1 }
                try expect(translator.calls.count == 1 && model.segments.first?.isFinal == false,
                    "Confirming a translated draft repeated Apple work or finalized before refinement")
                polisher.release(source: "An unchanged sentence.", translation: "바뀌지 않은 문장입니다.")
                try await waitUntil("Unchanged final refinement never finished") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                let finalized = model.segments[0]
                model.receive(source: "An unchanged sentence.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await Task.sleep(for: .milliseconds(50))
                try expect(polisher.calls.count == 1 && model.segments[0] == finalized,
                    "Repeated ASR confirmation reopened or refined a completed final caption")
            }),
            ("a corrected draft refines only the current final source revision", {
                let suite = "LiveKoCaption.PolishRevisionChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["The value is 50."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "The value is 15.", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Old draft did not finish") { !model.hasPendingTranslations && model.segments.first?.translation != nil }
                let oldRevision = model.segments[0].revision
                model.receive(source: "The value is 50.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Corrected final was not sent to refinement") { polisher.calls.count == 1 }
                try expect(polisher.calls[0].source == "The value is 50." && polisher.calls[0].baseline == "KO: The value is 50.",
                    "Refinement reused the obsolete draft source or number")
                try expect(model.segments[0].revision > oldRevision && !model.segments[0].isFinal,
                    "Corrected source revision was not pending")
                polisher.release(source: "The value is 50.", translation: "값은 50입니다.")
                try await waitUntil("Corrected final refinement did not complete") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                try expect(model.segments[0].translation == "값은 50입니다." && polisher.calls.count == 1,
                    "Final refinement changed a corrected number or also refined a partial")
            }),
            ("an in-flight unchanged partial confirmed final promotes its single baseline request", {
                let suite = "LiveKoCaption.PolishInFlightChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                translator.heldSources = ["Confirmed while translating."]
                defer { translator.releaseAll() }
                let polisher = PolisherProbe()
                polisher.heldSources = ["Confirmed while translating."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "Confirmed while translating.", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Held partial Apple request did not start") { translator.calls.count == 1 }
                model.receive(source: "Confirmed while translating.", audioStart: 0, audioEnd: 1, isFinal: true)
                translator.release(source: "Confirmed while translating.", translation: "번역 중 확정된 원문입니다.")
                try await waitUntil("Confirmed in-flight partial did not enter final refinement") { polisher.calls.count == 1 }
                try expect(translator.calls.count == 1 && model.segments.first?.translation == "번역 중 확정된 원문입니다." &&
                    model.segments.first?.isFinal == false, "In-flight confirmation repeated baseline work or bypassed gray final refinement")
                polisher.release(source: "Confirmed while translating.", translation: "번역하는 동안 확정된 문장입니다.")
                try await waitUntil("Promoted final refinement did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                try expect(model.segments[0].translation == "번역하는 동안 확정된 문장입니다." && polisher.calls.count == 1,
                    "Promoted source was refined twice or retained the obsolete intermediate wording")
            }),
            ("a new conversation rejects late local refinement output", {
                let suite = "LiveKoCaption.PolishNewSessionChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["Old final."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "Old final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Old refinement never started") { polisher.calls.count == 1 }
                model.newSession()
                model.receive(source: "New final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("New conversation blocked behind canceled refinement") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                let current = model.segments
                polisher.release(source: "Old final.", translation: "이전 대화에서 늦게 도착했습니다.")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments == current && current.count == 1 && current[0].source == "New final.",
                    "Previous conversation local output changed new caption records")
                try expect(model.message == nil && !model.hasPendingTranslations,
                    "Late local refinement polluted warnings or worker state")
            }),
            ("abort releases controls and late refinement cannot overwrite a resumed caption", {
                let suite = "LiveKoCaption.PolishAbortChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["Before abort."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.phase = .listening
                model.receive(source: "Before abort.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Abort refinement fixture did not start") { polisher.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                await model.stop(aborting: true)
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.5 && model.canStart && !model.hasPendingTranslations,
                    "Aborting waited for an uncooperative local refinement")
                try expect(model.segments[0].translation == "KO: Before abort.", "Aborting discarded the visible fast translation")
                try expect(model.segments[0].isFinal && model.segments[0].translationError == nil,
                    "Aborting left an exact source-final Apple baseline unfinished")
                model.phase = .listening
                model.receive(source: "After abort.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Resumed captions blocked behind old local work") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                let resumed = model.segments
                polisher.release(source: "Before abort.", translation: "중단 전에 생성한 늦은 결과")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments == resumed && model.segments.last?.source == "After abort.",
                    "Late aborted refinement changed the old or resumed caption")
                await model.stop(aborting: true)
            }),
            ("a held refinement never delays a current draft and still finalizes its own sentence", {
                let suite = "LiveKoCaption.DraftPolishLaneChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["Already spoken."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "Already spoken.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Held optional refinement did not start") { polisher.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                model.receive(source: "Now speaking quickly", audioStart: 1, audioEnd: 2, isFinal: false)
                try await waitUntil("Current draft waited behind optional refinement", seconds: 0.35) {
                    model.segments.count == 2 && model.segments[1].translation == "KO: Now speaking quickly"
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.35 &&
                    !model.segments[0].isFinal && model.segments[0].translation == "KO: Already spoken." &&
                    !model.segments[1].isFinal && model.segments.allSatisfy { $0.translationError == nil },
                    "Live speech canceled the earlier refinement, lost its baseline or falsely finalized a caption")
                polisher.release(source: "Already spoken.", translation: "먼저 말한 문장을 다듬었습니다.")
                try await waitUntil("Held refinement did not finalize after live speech continued") {
                    model.segments[0].isFinal && !model.hasPendingTranslations
                }
                try expect(model.segments[0].translation == "먼저 말한 문장을 다듬었습니다." &&
                    model.segments[1].translation == "KO: Now speaking quickly" && !model.segments[1].isFinal &&
                    polisher.calls.count == 1 && model.message == nil,
                    "Refinement finishing during live speech changed the draft or was not applied")
            }),
            ("a draft queued during Apple work translates at once and the earlier final is still refined", {
                let suite = "LiveKoCaption.QueuedDraftPolishChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                translator.heldSources = ["First final."]
                defer { translator.releaseAll() }
                let polisher = PolisherProbe()
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "First final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Final Apple baseline did not start") { translator.calls.count == 1 }
                model.receive(source: "Following live speech", audioStart: 1, audioEnd: 2, isFinal: false)
                translator.release(source: "First final.", translation: "첫 문장의 빠른 번역입니다.")
                try await waitUntil("Queued live speech or the earlier refinement did not finish") {
                    model.segments.last?.translation == "KO: Following live speech" &&
                        model.segments[0].isFinal && !model.hasPendingTranslations
                }
                try expect(polisher.calls.count == 1 && polisher.calls[0].baseline == "첫 문장의 빠른 번역입니다." &&
                    model.segments[0].translation == "다듬은 자막: First final." && !model.segments[1].isFinal,
                    "A waiting draft skipped the earlier refinement or refinement touched live speech")
            }),
            ("following finals show fast baselines while a refinement is held and the waiting limit keeps baselines", {
                let suite = "LiveKoCaption.PolishWaitingLimitChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["First quick caption."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults, timeout: 1.8)
                model.receive(source: "First quick caption.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First held local refinement never started") { polisher.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                model.receive(source: "Second quick caption.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Second fast caption waited for the held refinement", seconds: 0.6) {
                    model.segments.count == 2 && model.segments[1].translation == "KO: Second quick caption."
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.6 && polisher.calls.count == 1 &&
                    !model.segments[0].isFinal && !model.segments[1].isFinal,
                    "Held refinement blocked a fast baseline, ran two local requests at once or finalized early")
                model.receive(source: "Third quick caption.", audioStart: 2, audioEnd: 3, isFinal: true)
                model.receive(source: "Fourth quick caption.", audioStart: 3, audioEnd: 4, isFinal: true)
                try await waitUntil("Further fast speech was blocked by held local work", seconds: 0.6) {
                    model.segments.count == 4 && model.segments[3].translation == "KO: Fourth quick caption."
                }
                // Two sentences may wait. The oldest waiting one keeps its baseline.
                try expect(model.segments[1].isFinal && model.segments[1].translation == "KO: Second quick caption." &&
                    !model.segments[0].isFinal && !model.segments[2].isFinal && !model.segments[3].isFinal &&
                    polisher.calls.count == 1 && model.segments.allSatisfy { $0.translationError == nil },
                    "Waiting limit did not finalize the oldest waiting baseline or dropped a newer sentence")
                polisher.release(source: "First quick caption.", translation: "첫 문장을 다듬었습니다.")
                try await waitUntil("Waiting refinements did not finish in order") {
                    model.segments.allSatisfy(\.isFinal) && !model.hasPendingTranslations
                }
                try expect(model.segments.map(\.translation) == ["첫 문장을 다듬었습니다.", "KO: Second quick caption.",
                        "다듬은 자막: Third quick caption.", "다듬은 자막: Fourth quick caption."] &&
                    polisher.calls.map(\.source) == ["First quick caption.", "Third quick caption.", "Fourth quick caption."] &&
                    translator.calls.count == 4 && model.message == nil && model.canStart,
                    "Refinement lane changed order, repeated work or reported a degraded run")
            }),
            ("a final queued during Apple work gets its baseline without waiting for the earlier refinement", {
                let suite = "LiveKoCaption.PolishAlreadyQueuedChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                translator.heldSources = ["First queued final."]
                defer { translator.releaseAll() }
                let polisher = PolisherProbe()
                polisher.heldSources = ["First queued final.", "Second queued final."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults, timeout: 1.8)
                model.receive(source: "First queued final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First final never entered held Apple baseline work") { translator.calls.count == 1 }
                model.receive(source: "Second queued final.", audioStart: 1, audioEnd: 2, isFinal: true)
                let began = ProcessInfo.processInfo.systemUptime
                translator.release(source: "First queued final.", translation: "첫 원문의 빠른 번역입니다.")
                try await waitUntil("Queued second baseline waited for the earlier refinement", seconds: 0.6) {
                    model.segments.count == 2 && model.segments[1].translation == "KO: Second queued final." && polisher.calls.count == 1
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.6 &&
                    polisher.calls[0].source == "First queued final." &&
                    model.segments[0].translation == "첫 원문의 빠른 번역입니다." &&
                    !model.segments[0].isFinal && !model.segments[1].isFinal,
                    "Refinement order changed, or a gray baseline was lost or finalized early")
                polisher.release(source: "First queued final.", translation: "첫 문장을 다듬었습니다.")
                try await waitUntil("Second refinement did not start after the first") {
                    polisher.calls.count == 2 && model.segments[0].isFinal
                }
                polisher.release(source: "Second queued final.", translation: "두 번째 문장을 다듬었습니다.")
                try await waitUntil("Queued finals did not finish optional refinement") {
                    model.segments.allSatisfy(\.isFinal) && !model.hasPendingTranslations
                }
                try expect(translator.calls.count == 2 && polisher.calls.count == 2 && model.message == nil &&
                    model.segments.map(\.translation) == ["첫 문장을 다듬었습니다.", "두 번째 문장을 다듬었습니다."],
                    "Queued finals repeated work, degraded refinement or applied the wrong wording")
            }),
            ("native local context timeout disables only further context for the current run", {
                let suite = "LiveKoCaption.NativeContextTimeoutChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.nativeTimeoutSources = ["First. Second."]
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.contextCorrectionEnabled = true
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First local caption never finished") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Injected native context timeout did not finish", seconds: 1.2) {
                    polisher.calls.contains { $0.source == "First. Second." } && !model.hasPendingTranslations
                }
                try expect(model.segments.allSatisfy(\.isFinal) && model.segments.allSatisfy { $0.translationError == nil } &&
                    model.displaySegments.count == 2 && model.displaySegments.allSatisfy(\.isFinal),
                    "Native optional context timeout damaged exact finalized captions or left them gray")
                try expect(model.message?.contains("문맥 보정이 지연") == true,
                    "Native timeout status did not report disabled context for this run")
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Per-caption local refinement stopped after a context-only native timeout") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(model.segments.last?.translation == "다듬은 자막: Third." && translator.calls.count == 3,
                    "Context-only native timeout disabled normal caption translation or refinement")
                let combinedRequests = polisher.calls.filter { $0.source != "First." && $0.source != "Second." && $0.source != "Third." }
                try expect(combinedRequests.count == 1 && combinedRequests[0].source == "First. Second.",
                    "Native context timeout kept admitting further aggregate context work")
                try expect(model.canStart && !model.displaySegments.contains(where: \.contextIsPending),
                    "Native context timeout left controls or pending context stuck")
            }),
            ("abort cannot finalize a newer source with a cleared conversation's stale baseline", {
                let suite = "LiveKoCaption.PolishStaleAbortChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                translator.heldSources = ["Current unfinished source."]
                defer { translator.releaseAll() }
                let polisher = PolisherProbe()
                polisher.heldSources = ["Discarded source."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "Discarded source.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Old baseline never entered held refinement") { polisher.calls.count == 1 }
                model.newSession()
                model.phase = .listening
                model.receive(source: "Current unfinished source.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Current untranslated source did not enter Apple work") {
                    translator.calls.contains(.init(source: "Current unfinished source.", context: false))
                }
                await model.stop(aborting: true)
                try expect(model.canStart && model.segments.count == 1 && model.segments[0].source == "Current unfinished source.",
                    "Abort recovered an earlier conversation instead of keeping the current source")
                try expect(!model.segments[0].isFinal && model.segments[0].translation == nil && model.segments[0].translationError != nil,
                    "Stale fast baseline falsely finalized a source that Apple never translated")
                let aborted = model.segments
                polisher.release(source: "Discarded source.", translation: "지워진 대화에서 생성된 늦은 보정입니다.")
                translator.release(source: "Current unfinished source.", translation: "중단 후 도착한 빠른 번역입니다.")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments == aborted && !model.hasPendingTranslations,
                    "Late stale polish or canceled Apple work finalized an aborted source")
            }),
            ("local timeout retains final Apple output and skips further optional work for the run", {
                let suite = "LiveKoCaption.PolishTimeoutChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.heldSources = ["Timed out final."]
                defer { polisher.releaseAll() }
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults, timeout: 0.05)
                let began = ProcessInfo.processInfo.systemUptime
                model.receive(source: "Timed out final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Optional timeout kept the baseline pending", seconds: 0.8) {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.5 && model.canStart,
                    "Optional deadline waited for ignored cancellation or left Start unavailable")
                try expect(model.segments[0].translation == "KO: Timed out final." && model.segments[0].translationError == nil,
                    "Optional timeout erased or marked valid Apple output as failed")
                model.receive(source: "Following final.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Apple translation did not continue after optional timeout") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(polisher.calls.count == 1 && model.segments.last?.translation == "KO: Following final.",
                    "Timed-out optional refinement continued occupying the run")
                let finalRecords = model.segments
                polisher.release(source: "Timed out final.", translation: "기한을 넘긴 늦은 보정입니다.")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments == finalRecords && model.canStart,
                    "Late expired optional result changed finalized baseline records")
            }),
            ("optional refinement failure preserves valid baseline and following caption translation", {
                let suite = "LiveKoCaption.PolishFailureChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                polisher.failingSources = ["Failed refinement."]
                let model = makePolishModel(translator, polisher: polisher, defaults: defaults)
                model.receive(source: "Failed refinement.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Optional failure left baseline unfinished") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(model.segments[0].translation == "KO: Failed refinement." && model.segments[0].translationError == nil,
                    "Optional failure damaged a validated Apple translation")
                model.receive(source: "Still translating.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Following Apple caption stopped after optional failure") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(polisher.calls.count == 1 && translator.calls.count == 2 && model.canStart,
                    "Optional failure was retried endlessly or blocked the fast path")
            }),
            ("switching direction while paused keeps earlier captions and labels each row with its own languages", {
                let suite = "LiveKoCaption.DirectionSwitchChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-direction-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                try Data("risk factor = 위험 요인\nrisk-factor = 위험 요소\n".utf8).write(to: file)
                let probe = TranslatorProbe()
                let model = CaptionModel(translationOverride: { source, isContext in
                    try await probe.translate(source, context: isContext)
                }, readinessOverride: { _ in true }, preferencesDefaults: defaults, glossaryURL: file)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.selectedDictionaryIDs = [CaptionDictionary.legacyPersonalID]
                try expect(model.dictionaryConflictMessage.contains("risk factor"),
                    "The initial direction did not report its normalized dictionary conflict")
                model.receive(source: "Any questions?", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("English caption did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                let english = model.segments[0]
                try expect(model.canSwitchDirection && !model.canChangeSessionSettings,
                    "A paused conversation with captions could not switch direction")
                await model.switchDirection()
                try expect(model.selectedDirection == .koreanToEnglish && model.segments == [english] &&
                    model.sourceDisplayName == "한국어" && model.canStart && model.message == nil,
                    "Switching changed recorded captions, kept the old input language or blocked Start")
                try expect(model.dictionaryConflictMessage.isEmpty && model.selectedDictionaryIDs == [CaptionDictionary.legacyPersonalID],
                    "Switching kept a stale direction-specific conflict or changed dictionary selection")
                try expect(defaults.string(forKey: CaptionDirection.preferenceKey) == CaptionDirection.koreanToEnglish.rawValue,
                    "The switched direction was not kept for the next launch")
                model.receive(source: "질문이 있습니다.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Korean caption did not finish") { model.segments.count == 2 && model.segments[1].isFinal && !model.hasPendingTranslations }
                try expect(model.segments.map(\.direction) == [.englishToKorean, .koreanToEnglish],
                    "Captions were not tagged with the direction that was active when they were spoken")
                let text = model.transcriptText
                try expect(text.contains("]\nEN: Any questions?\nKO: ") && text.contains("]\nKO: 질문이 있습니다.\nEN: "),
                    "Saved rows did not carry their own source and target language labels")
                await model.switchDirection()
                try expect(model.selectedDirection == .englishToKorean && model.segments.count == 2 &&
                    model.dictionaryConflictMessage.contains("risk factor"),
                    "Switching back lost captions, kept the wrong direction or failed to refresh dictionary conflicts")
            }),
            ("direction asset checks exclude public resume and conversation edits until the new language is committed", {
                let suite = "LiveKoCaption.DirectionAdmissionChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let readiness = ReadinessProbe()
                defer { readiness.releaseAll() }
                var microphoneDirections: [CaptionDirection] = []
                var model: CaptionModel!
                model = CaptionModel(translationOverride: { source, _ in "KO: " + source },
                    microphoneAccessOverride: {
                        microphoneDirections.append(model.selectedDirection)
                        return false
                    }, readinessOverride: { try await readiness.check($0) }, preferencesDefaults: defaults)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.selectedDeviceUID = ""
                model.receive(source: "Keep this conversation.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Original caption did not finish") { !model.hasPendingTranslations }
                let original = model.segments
                let switching = Task { await model.switchDirection() }
                try await waitUntil("Direction check did not suspend") { readiness.calls == [.koreanToEnglish] }
                try expect(model.isSwitchingDirection && !model.canStart && !model.canChangeSessionSettings && model.isBusy,
                    "Pending direction lookup left public start or settings available")
                await model.start()
                model.newSession()
                model.polishEnabled = true
                model.retryFailedTranslations()
                try expect(microphoneDirections.isEmpty && model.phase == .idle && model.segments == original && !model.polishEnabled,
                    "Public action raced the direction check or discarded the conversation")
                readiness.release(.koreanToEnglish, ready: true)
                await switching.value
                try expect(model.selectedDirection == .koreanToEnglish && model.canStart && !model.isSwitchingDirection &&
                           model.segments == original,
                    "Direction was lost or admission remained closed after readiness returned")
                await model.start()
                try expect(microphoneDirections == [.koreanToEnglish] && model.phase == .idle,
                    "User resume did not request only the committed input language")
            }),
            ("a direction switch is refused when the other language is not installed", {
                let suite = "LiveKoCaption.DirectionSwitchMissingChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let probe = TranslatorProbe()
                let model = CaptionModel(translationOverride: { source, isContext in
                    try await probe.translate(source, context: isContext)
                }, readinessOverride: { $0 == .englishToKorean }, preferencesDefaults: defaults)
                model.isChecking = false; model.assetsReady = true
                model.receive(source: "Keep this direction.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Caption did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                await model.switchDirection()
                try expect(model.selectedDirection == .englishToKorean && model.canStart &&
                    model.message?.contains("준비되지 않아") == true && model.segments.count == 1,
                    "A switch to an uninstalled language changed direction, hid the reason or blocked the current one")
            }),
            ("switching while listening finishes the run, flips direction and starts listening again", {
                let suite = "LiveKoCaption.DirectionSwitchLiveChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let probe = TranslatorProbe()
                var startAttempts: [CaptionDirection] = []
                var model: CaptionModel!
                // Denying the microphone ends the restart before any audio
                // device or language engine is opened by this check.
                model = CaptionModel(translationOverride: { source, isContext in
                    try await probe.translate(source, context: isContext)
                }, microphoneAccessOverride: {
                    startAttempts.append(model.selectedDirection)
                    return false
                }, readinessOverride: { _ in true }, preferencesDefaults: defaults)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.selectedDeviceUID = ""
                model.phase = .listening
                model.receive(source: "Thank you. Any questions?", audioStart: 0, audioEnd: 2, isFinal: true)
                try expect(model.canSwitchDirection, "A listening session could not switch direction")
                await model.switchDirection()
                try expect(startAttempts == [.koreanToEnglish],
                    "The switch did not restart in the other direction exactly once: \(startAttempts)")
                try expect(model.selectedDirection == .koreanToEnglish && model.phase == .idle && !model.hasPendingTranslations &&
                    model.segments.count == 1 && model.segments[0].isFinal && model.segments[0].direction == .englishToKorean &&
                    model.segments[0].translation == "KO: Thank you. Any questions?",
                    "The last sentence before the switch was lost, left unfinished or relabeled")
                try expect(model.message?.contains("마이크 접근") == true && !model.isSwitchingDirection,
                    "A failed restart hid its reason or left the switch in progress")
            }),
            ("oversized personal corrections preserve the full ASR and report their fallback", {
                let suite = "LiveKoCaption.GlossaryExpansionChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-expansion-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                let term = "A" + String(repeating: "\u{0301}", count: 1_000)
                try Data((term + " = 단어 | heard\n").utf8).write(to: file)
                let model = CaptionModel(translationOverride: { _, _ in "원문 보존 번역" },
                    preferencesDefaults: defaults, glossaryURL: file)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.selectedDictionaryIDs = [CaptionDictionary.legacyPersonalID]
                let source = Array(repeating: "heard", count: 40).joined(separator: " ")
                model.receive(source: source, audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Bounded correction fallback did not translate") { !model.hasPendingTranslations }
                try expect(model.segments[0].source == source && model.segments[0].isFinal &&
                           model.transcriptText.contains("인식한 원문을 그대로 유지"),
                    "Overflow changed/truncated the ASR or hid the correction fallback")
            }),
            ("invalid personal dictionary headers show a warning and valid terms still translate", {
                let suite = "LiveKoCaption.GlossaryHeaderChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-headers-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                try Data("# 이름: Invalid\u{0}Name\n# 문맥: Finance\u{0}Ignore source\nloan = 대출\n".utf8).write(to: file)
                let model = CaptionModel(translationOverride: { _, _ in "번역" },
                    preferencesDefaults: defaults, glossaryURL: file)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                let local = model.dictionaries.first { $0.id == CaptionDictionary.legacyPersonalID }!
                try expect(local.validationWarnings.count == 2 && local.context.isEmpty && local.glossary.entries.count == 1 &&
                           model.glossaryMessage.contains("사전 필드 2개를 제외"),
                    "Invalid personal context survived or its safe fallback was hidden")
                do {
                    _ = try model.createDictionary(named: "Invalid\u{0}Name")
                    throw ModelCheckFailure(description: "Dictionary creation wrote an invalid header")
                } catch is ModelCheckFailure { throw ModelCheckFailure(description: "Dictionary creation accepted NUL") }
                catch { }
                let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                try expect(remainingFiles.count == 1,
                    "Invalid dictionary creation left a file behind")
            }),
            ("only selected local dictionaries correct listed spellings before translation and guide refinement", {
                let suite = "LiveKoCaption.GlossaryChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-check-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                let personalID = CaptionDictionary.localID(fileName: file.lastPathComponent)
                try Data("Northwind = 노스윈드 | north wind\nOpenShift | open shift\n".utf8).write(to: file)
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                let model = CaptionModel(translationOverride: { source, isContext in
                    try await translator.translate(source, context: isContext)
                }, preferencesDefaults: defaults, polishOverride: { try await polisher.polish($0) }, glossaryURL: file)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.polishEnabled = true
                try expect(model.dictionaries.first(where: { $0.id == personalID })?.glossary.entries.count == 2 && !model.glossaryMessage.isEmpty,
                    "The glossary file was not read at launch")
                model.receive(source: "The north wind team uses open shift.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Caption without dictionaries did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                try expect(model.segments[0].source == "The north wind team uses open shift." &&
                    polisher.calls.count == 1 && polisher.calls[0].dictionaries.isEmpty,
                    "A local dictionary changed a conversation that did not select it")
                model.newSession()
                model.selectedDictionaryIDs = [BuiltInDictionaries.aiID, personalID]
                try expect(model.selectedDictionaryIDs == [BuiltInDictionaries.aiID, personalID],
                    "Multiple dictionaries could not be selected in an empty conversation")
                model.receive(source: "The north wind team uses", audioStart: 0, audioEnd: 1, isFinal: false)
                model.receive(source: "The north wind team uses open shift.", audioStart: 0, audioEnd: 2, isFinal: true)
                try await waitUntil("Caption with a local dictionary did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                try expect(model.segments[0].source == "The Northwind team uses OpenShift." &&
                    translator.calls.last?.source == "The Northwind team uses OpenShift.",
                    "Listed spellings were not corrected before the fast translation: \(model.segments[0].source)")
                let request = polisher.calls.last
                try expect(polisher.calls.count == 2 && request?.source == "The Northwind team uses OpenShift." &&
                    Set(request?.dictionaries.map(\.id) ?? []) == [BuiltInDictionaries.aiID, personalID] &&
                    request?.prompt.contains("Northwind translates to 노스윈드") == true,
                    "Refinement was not given the corrected source and the owner's terms")
                try Data("Northwind = 노스윈드\n".utf8).write(to: file)
                model.reloadGlossary()
                let reloaded = model.dictionaries.first(where: { $0.id == personalID })?.glossary.entries
                try expect(reloaded?.count == 1 && reloaded?.first?.heardAs.isEmpty == true,
                    "An edited glossary file was not read again")
            }),
            ("multiple local files compose their terms and report conflicting translations", {
                let suite = "LiveKoCaption.DictionaryCompositionChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-composition-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let primary = directory.appendingPathComponent("glossary.txt")
                let secondary = directory.appendingPathComponent("product-names.txt")
                try Data("# 이름: 이름 사전\n# 문맥: Technical team names.\nNorthwind = 노스윈드 | north wind\nHarbor = 하버\n".utf8).write(to: primary)
                try Data("# 이름: 제품 사전\n# 문맥: Product platform names.\nOpenShift | open shift\nHarbor = 항구\n".utf8).write(to: secondary)
                let translator = TranslatorProbe()
                let polisher = PolisherProbe()
                let model = CaptionModel(translationOverride: { source, isContext in
                    try await translator.translate(source, context: isContext)
                }, preferencesDefaults: defaults, polishOverride: { try await polisher.polish($0) }, glossaryURL: primary)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.polishEnabled = true
                let personalIDs: Set<String> = [CaptionDictionary.legacyPersonalID, CaptionDictionary.localID(fileName: secondary.lastPathComponent)]
                try expect(Set(model.dictionaries.filter(\.isPersonal).map(\.id)) == personalIDs &&
                    model.dictionaries.first(where: { $0.id == CaptionDictionary.legacyPersonalID })?.name == "이름 사전" &&
                    model.dictionaries.first(where: { $0.id == CaptionDictionary.localID(fileName: secondary.lastPathComponent) })?.name == "제품 사전",
                    "The dictionary folder did not load both local files with their names")
                model.selectedDictionaryIDs = personalIDs.union([BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID])
                try expect(model.dictionaryConflictMessage.contains("Harbor"),
                    "The selected local translation conflict was not visible")
                model.receive(source: "The north wind team uses open shift near Harbor.", audioStart: 0, audioEnd: 2, isFinal: true)
                try await waitUntil("Multiple dictionary caption did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                let request = polisher.calls.last
                try expect(model.segments[0].source == "The Northwind team uses OpenShift near Harbor." &&
                    Set(request?.dictionaries.map(\.id) ?? []) == model.selectedDictionaryIDs,
                    "The selected files did not compose source corrections and translation references")
                try expect(request?.prompt.contains("Northwind translates to 노스윈드") == true &&
                    request?.prompt.contains("OpenShift translates to OpenShift") == true &&
                    request?.prompt.contains("Technical team names.") == true &&
                    request?.prompt.contains("Product platform names.") == true &&
                    request?.relevantTerms.contains(where: { $0.0 == "Harbor" }) == false,
                    "A selected term/context was lost or a conflicting term was passed to refinement")
            }),
            ("dictionary reload waits for pending translations and preserves completed captions", {
                let suite = "LiveKoCaption.DictionaryReloadChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-reload-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                try Data("Northwind = 노스윈드 | north wind\n".utf8).write(to: file)
                let translator = TranslatorProbe()
                defer { translator.releaseAll() }
                let correctedSource = "The Northwind team is ready."
                translator.heldSources = [correctedSource]
                let model = CaptionModel(translationOverride: { source, isContext in
                    try await translator.translate(source, context: isContext)
                }, preferencesDefaults: defaults, glossaryURL: file)
                model.isChecking = false; model.assetsReady = true; model.contextCorrectionEnabled = false
                model.selectedDictionaryIDs = [CaptionDictionary.legacyPersonalID]
                model.receive(source: "The north wind team is ready.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("The held translation did not start") { translator.calls.count == 1 }
                try expect(model.hasPendingTranslations, "The pending-translation reload fixture did not hold any work")
                try Data("Northwind = 북쪽바람 | northern wind\n".utf8).write(to: file)
                model.reloadGlossary()
                let pendingEntries = model.dictionaries.first(where: { $0.id == CaptionDictionary.legacyPersonalID })?.glossary.entries
                try expect(pendingEntries?.first?.korean == "노스윈드" && pendingEntries?.first?.heardAs == ["north wind"],
                    "Reload changed dictionary content while a translation was pending")
                translator.release(source: correctedSource, translation: "KO: \(correctedSource)")
                try await waitUntil("The held translation did not finish") { model.segments.first?.isFinal == true && !model.hasPendingTranslations }
                let completed = model.segments[0]
                model.reloadGlossary()
                let completedEntries = model.dictionaries.first(where: { $0.id == CaptionDictionary.legacyPersonalID })?.glossary.entries
                try expect(completedEntries?.first?.korean == "북쪽바람" && completedEntries?.first?.heardAs == ["northern wind"],
                    "Reload did not read edited local terms after translation completed")
                try expect(model.segments[0] == completed,
                    "Reload rewrote a completed caption using later dictionary content")
            }),
            ("legacy domains migrate once and an explicit empty selection takes precedence", {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-migration-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let file = directory.appendingPathComponent("glossary.txt")
                let cases: [(domain: TranslationDomain, personalFileExists: Bool, expected: Set<String>)] = [
                    (.general, false, []),
                    (.it, false, [BuiltInDictionaries.aiID]),
                    (.custom, true, [BuiltInDictionaries.aiID, CaptionDictionary.legacyPersonalID]),
                    (.custom, false, [BuiltInDictionaries.aiID, CaptionDictionary.legacyPersonalID])
                ]
                for fixture in cases {
                    if fixture.personalFileExists { try Data("Northwind = 노스윈드\n".utf8).write(to: file) }
                    else { try? FileManager.default.removeItem(at: file) }
                    let suite = "LiveKoCaption.DictionaryMigrationChecks.\(UUID().uuidString)"
                    let defaults = UserDefaults(suiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    defaults.set(fixture.domain.rawValue, forKey: TranslationDomain.preferenceKey)
                    let model = CaptionModel(preferencesDefaults: defaults, glossaryURL: file)
                    try expect(model.selectedDictionaryIDs == fixture.expected,
                        "Legacy \(fixture.domain.rawValue) domain did not preserve its dictionary selection")
                    if fixture.domain == .custom && !fixture.personalFileExists {
                        try expect(model.dictionaryConflictMessage.contains("찾지 못") &&
                            model.selectedDictionaries.map(\.id) == [BuiltInDictionaries.aiID],
                            "A missing legacy local file was not reported or supplied unavailable terms")
                    }
                    let restored = CaptionModel(preferencesDefaults: defaults, glossaryURL: file)
                    try expect(restored.selectedDictionaryIDs == fixture.expected,
                        "Migrated dictionary selection did not survive restoration")
                    defaults.set([String](), forKey: CaptionDictionary.preferenceKey)
                    let explicitlyEmpty = CaptionModel(preferencesDefaults: defaults, glossaryURL: file)
                    try expect(explicitlyEmpty.selectedDictionaryIDs.isEmpty,
                        "A legacy domain re-enabled dictionaries after an explicit empty selection")
                }
            }),
            ("creating a local dictionary selects and restores it while previews keep personal data private", {
                let suite = "LiveKoCaption.DictionaryCreationChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-creation-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: directory) }
                let glossaryURL = directory.appendingPathComponent("glossary.txt")
                let model = CaptionModel(preferencesDefaults: defaults, glossaryURL: glossaryURL)
                let createdFile = try model.createDictionary(named: "회의\n이름")
                let createdID = CaptionDictionary.localID(fileName: createdFile.lastPathComponent)
                let createdDictionary = model.dictionaries.first(where: { $0.id == createdID })
                try expect(createdFile.deletingLastPathComponent().path == directory.path && createdFile.pathExtension == "txt" &&
                    FileManager.default.fileExists(atPath: createdFile.path) &&
                    createdDictionary?.name == "회의 이름" && createdDictionary?.isPersonal == true &&
                    createdDictionary?.glossary.entries.isEmpty == true && model.selectedDictionaryIDs == [createdID],
                    "Creating a named dictionary did not save and select a usable empty local file: path=\(createdFile.path), name=\(createdDictionary?.name ?? "missing"), terms=\(createdDictionary?.glossary.entries.count ?? -1), ids=\(model.selectedDictionaryIDs)")
                try expect(defaults.stringArray(forKey: CaptionDictionary.preferenceKey) == [createdID],
                    "Creating a dictionary did not persist its selection")
                try Data("# 이름: 회의 이름\nPrivateTerm = 개인용어\n".utf8).write(to: createdFile)
                model.reloadGlossary()
                let restored = CaptionModel(preferencesDefaults: defaults, glossaryURL: glossaryURL)
                try expect(restored.selectedDictionaryIDs == [createdID] &&
                    restored.selectedDictionaries.first?.glossary.entries.first?.english == "PrivateTerm",
                    "A created dictionary's edited terms or selection did not survive restoration")
                let preview = CaptionModel(preview: true, preferencesDefaults: defaults, glossaryURL: glossaryURL)
                try expect(preview.selectedDictionaryIDs.isEmpty && preview.glossary.entries.isEmpty &&
                    preview.dictionaries.allSatisfy({ !$0.isPersonal }) &&
                    !preview.dictionarySelectionLabel.contains("회의 이름"),
                    "Preview exposed personal dictionary names, terms or selection")
                try expect(defaults.stringArray(forKey: CaptionDictionary.preferenceKey) == [createdID],
                    "Preview overwrote the user's created dictionary selection")
                model.phase = .listening
                var refused = false
                do { _ = try model.createDictionary(named: "실행 중 사전") }
                catch { refused = true }
                try expect(refused && model.selectedDictionaryIDs == [createdID] &&
                    model.dictionaries.filter(\.isPersonal).count == 1,
                    "Creating a dictionary changed the active conversation's settings")
            }),
            ("invalid leading files do not consume the local limit or displace selected legacy terms on creation", {
                let suite = "LiveKoCaption.DictionaryLimitChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-limit-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                try Data([0xFF]).write(to: directory.appendingPathComponent("000-invalid.txt"))
                for index in 0..<30 {
                    let name = String(format: "dictionary-%02d.txt", index)
                    try Data("term\(index) = 용어\(index)\n".utf8).write(to: directory.appendingPathComponent(name))
                }
                let glossaryURL = directory.appendingPathComponent("glossary.txt")
                try Data("LegacyName = 기존이름\n".utf8).write(to: glossaryURL)
                defaults.set([CaptionDictionary.legacyPersonalID], forKey: CaptionDictionary.preferenceKey)
                let model = CaptionModel(preferencesDefaults: defaults, glossaryURL: glossaryURL)
                let originalIDs = Set(model.dictionaries.filter(\.isPersonal).map(\.id))
                try expect(originalIDs.count == 31 && originalIDs.contains(CaptionDictionary.legacyPersonalID) &&
                    model.glossaryMessage.contains("읽지 못"),
                    "The invalid leading file was not reported or consumed a valid local dictionary slot")
                let createdFile = try model.createDictionary(named: "마지막 개인 사전")
                let createdID = CaptionDictionary.localID(fileName: createdFile.lastPathComponent)
                try expect(Set(model.dictionaries.filter(\.isPersonal).map(\.id)) == originalIDs.union([createdID]) &&
                    model.selectedDictionaryIDs == [CaptionDictionary.legacyPersonalID, createdID] &&
                    model.selectedDictionaries.first(where: { $0.id == CaptionDictionary.legacyPersonalID })?.glossary.entries.first?.english == "LegacyName" &&
                    model.dictionaryConflictMessage.isEmpty,
                    "Creating a dictionary at the valid-file limit displaced selected existing terms")
                let restored = CaptionModel(preferencesDefaults: defaults, glossaryURL: glossaryURL)
                try expect(Set(restored.dictionaries.filter(\.isPersonal).map(\.id)) == originalIDs.union([createdID]) &&
                    restored.selectedDictionaryIDs == model.selectedDictionaryIDs && restored.dictionaryConflictMessage.isEmpty,
                    "Restoration changed the retained valid dictionaries or selected legacy file")
                var refused = false
                do { _ = try model.createDictionary(named: "제한을 넘는 사전") }
                catch { refused = true }
                try expect(refused && Set(model.dictionaries.filter(\.isPersonal).map(\.id)) == originalIDs.union([createdID]),
                    "Creating beyond the valid dictionary limit succeeded or changed the catalog")
            }),
            ("direction and multiple dictionary selections persist and freeze for recorded sessions", {
                let suite = "LiveKoCaption.ModelChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let model = CaptionModel(readinessOverride: { _ in true }, preferencesDefaults: defaults)
                try expect(model.selectedDirection == .englishToKorean && model.selectedDictionaryIDs.isEmpty,
                    "Empty preferences did not use English to Korean with no dictionaries")
                model.isChecking = false; model.assetsReady = true
                model.selectedDirection = .koreanToEnglish
                try expect(!model.canStart && model.isChecking && !model.assetsReady,
                    "Changing direction left the previous pair ready before checking")
                let selection: Set<String> = [BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID, BuiltInDictionaries.financeID]
                model.selectedDictionaryIDs = selection
                try await waitUntil("Changed pair readiness never finished") { !model.isChecking && model.assetsReady }
                let restored = CaptionModel(preferencesDefaults: defaults)
                try expect(restored.selectedDirection == .koreanToEnglish && restored.selectedDictionaryIDs == selection &&
                    Set(restored.selectedDictionaries.map(\.id)) == selection,
                    "Direction or multiple dictionary selections were not restored")
                try expect(model.sourceDisplayName == "한국어" && model.targetDisplayName == "영어",
                    "Selected direction labels remained English input")
                model.phase = .listening
                try expect(model.statusText == "한국어를 듣고 있습니다", "Listening status used the wrong input language")
                for phase in [CaptionModel.Phase.starting, .listening, .stopping] {
                    model.phase = phase
                    model.selectedDirection = .englishToKorean; model.selectedDictionaryIDs = []
                    try expect(model.selectedDirection == .koreanToEnglish && model.selectedDictionaryIDs == selection,
                        "Session settings changed during an active phase")
                }
                model.phase = .idle; model.isPreparing = true
                model.selectedDirection = .englishToKorean; model.selectedDictionaryIDs = []
                try expect(model.selectedDirection == .koreanToEnglish && model.selectedDictionaryIDs == selection,
                    "Session settings changed during model preparation")
                model.isPreparing = false
                model.receive(source: "캐시를 비웁니다.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.selectedDirection = .englishToKorean; model.selectedDictionaryIDs = []
                try expect(!model.canChangeSessionSettings && model.selectedDirection == .koreanToEnglish && model.selectedDictionaryIDs == selection,
                    "Recorded sources were relabeled without a new session")
                try expect(model.transcriptText.contains("KO: 캐시를 비웁니다.\nEN: 번역 없음"),
                    "Korean input export used English input labels")
                model.newSession()
                try expect(model.canChangeSessionSettings, "New conversation did not unlock settings")
                model.selectedDictionaryIDs = []
                let withoutDictionaries = CaptionModel(preferencesDefaults: defaults)
                try expect(withoutDictionaries.selectedDictionaryIDs.isEmpty,
                    "An explicitly empty dictionary selection did not persist")
                model.requestPreparation()
                try expect(model.translationConfiguration != nil, "Preparation did not create a translation configuration")
                model.isPreparing = false
                model.selectedDirection = .englishToKorean
                try expect(model.translationConfiguration == nil, "Old direction translation configuration survived")
                try await waitUntil("New conversation readiness never finished") { !model.isChecking }
                let preview = CaptionModel(preview: true, preferencesDefaults: defaults)
                try expect(preview.selectedDirection == .englishToKorean && preview.selectedDictionaryIDs.isEmpty,
                    "Preview used persisted non-fixture languages or dictionaries")
                defaults.set(CaptionDirection.koreanToEnglish.rawValue, forKey: CaptionDirection.preferenceKey)
                defaults.set([BuiltInDictionaries.ibmID], forKey: CaptionDictionary.preferenceKey)
                let soak = CaptionModel(preferencesDefaults: defaults)
                soak.isUISoak = true
                try expect(soak.selectedDirection == .englishToKorean && soak.selectedDictionaryIDs.isEmpty,
                    "Synthetic soak used persisted non-fixture languages or dictionaries")
                try expect(defaults.string(forKey: CaptionDirection.preferenceKey) == CaptionDirection.koreanToEnglish.rawValue,
                    "Synthetic fixtures overwrote user direction")
                try expect(defaults.stringArray(forKey: CaptionDictionary.preferenceKey) == [BuiltInDictionaries.ibmID],
                    "Synthetic fixtures overwrote user dictionary selection")
            }),
            ("stale readiness cannot enable Start or overwrite the current direction error", {
                let suite = "LiveKoCaption.ReadinessChecks.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let probe = ReadinessProbe()
                defer { probe.releaseAll() }
                let model = CaptionModel(readinessOverride: { try await probe.check($0) }, preferencesDefaults: defaults)
                let oldCheck = Task { await model.checkReadiness() }
                try await waitUntil("Old readiness did not start") { probe.calls == [.englishToKorean] }
                model.selectedDirection = .koreanToEnglish
                try await waitUntil("New direction check did not start") { probe.calls.count == 2 }
                probe.release(.englishToKorean, ready: true)
                await oldCheck.value
                try expect(model.isChecking && !model.assetsReady && !model.canStart,
                    "Stale readiness enabled a pair that is still being checked")
                probe.release(.koreanToEnglish, ready: false)
                try await waitUntil("Current readiness did not finish") { !model.isChecking }
                try expect(!model.assetsReady, "Unavailable current pair inherited old installed assets")
                let staleErrorCheck = Task { await model.checkReadiness() }
                try await waitUntil("Error readiness fixture did not start") { probe.calls.count == 3 }
                model.selectedDirection = .englishToKorean
                try await waitUntil("Replacement error check did not start") { probe.calls.count == 4 }
                probe.release(.englishToKorean, ready: true)
                try await waitUntil("Replacement installed pair did not finish") { !model.isChecking && model.assetsReady }
                probe.fail(.koreanToEnglish)
                await staleErrorCheck.value
                try expect(model.canStart && model.message == nil && model.selectedDirection == .englishToKorean,
                    "Old readiness error polluted the current ready pair")
            }),
            ("a canceled startup cannot resurrect itself or overwrite a newer startup", {
                let permission = PermissionProbe()
                defer { permission.releaseAll() }
                let model = CaptionModel(microphoneAccessOverride: { await permission.request() })
                let savedInput = model.selectedDeviceUID
                defer { model.selectedDeviceUID = savedInput }
                model.selectedDeviceUID = ""
                model.isChecking = false
                model.assetsReady = true
                let oldStart = Task { await model.start() }
                try await waitUntil("Initial startup did not reach permission wait") { permission.calls == 1 && model.phase == .starting }
                await model.stop()
                try expect(model.phase == .idle && model.canStart, "Canceling startup left controls blocked")
                let newStart = Task { await model.start() }
                try await waitUntil("New startup did not reach permission wait") { permission.calls == 2 && model.phase == .starting }
                permission.releaseFirst(true)
                await oldStart.value
                try expect(model.phase == .starting && model.message == nil, "Old startup modified the newer run")
                permission.releaseFirst(false)
                await newStart.value
                try expect(model.phase == .idle && !model.hasPendingTranslations, "Denied new startup did not clean up")
                try expect(model.message?.contains("마이크 접근") == true, "New startup permission error was lost")
                try expect(model.segments.isEmpty, "Startup cancellation invented caption content")
            }),
            ("an empty audio-input failure immediately restores Start after repeated failures", {
                let probe = TranslatorProbe()
                let model = makeModel(probe)
                let problem = "마이크를 시작했지만 오디오 입력이 도착하지 않습니다."
                for _ in 0..<3 {
                    try expect(model.canStart, "Empty run could not be started again")
                    model.phase = .listening
                    model.audioLevel = 0.4
                    let began = ProcessInfo.processInfo.systemUptime
                    await model.receiveAudioProblem(problem)
                    try expect(ProcessInfo.processInfo.systemUptime - began < 0.5,
                               "Empty audio failure kept the Start control blocked")
                    try expect(model.phase == .idle && model.canStart && !model.canStop,
                               "Empty audio failure did not restore idle controls")
                    try expect(!model.hasPendingTranslations && model.queuedTranslations == 0,
                               "Empty audio failure retained a phantom worker")
                    try expect(model.audioLevel == 0 && model.segments.isEmpty,
                               "Empty audio failure retained input or invented a caption")
                    try expect(model.message == problem,
                               "Input failure message was lost or overwritten by normal cleanup")
                }
                try expect(probe.calls.isEmpty, "Empty run unnecessarily called the translator")
                try expect(model.transcriptText.components(separatedBy: problem).count == 2,
                           "Repeated identical audio problems polluted the export warnings")
                await model.receiveAudioProblem("Stale input failure")
                try expect(model.canStart && model.message == problem,
                           "A late input problem modified an already stopped run")
            }),
            ("repeated denied starts remain retryable after their asynchronous cleanup", {
                let permission = PermissionProbe()
                defer { permission.releaseAll() }
                let model = CaptionModel(microphoneAccessOverride: { await permission.request() })
                let savedInput = model.selectedDeviceUID
                defer { model.selectedDeviceUID = savedInput }
                model.selectedDeviceUID = ""
                model.isChecking = false
                model.assetsReady = true
                for attempt in 1...3 {
                    try expect(model.canStart, "A prior failed start left the Start control disabled")
                    let start = Task { await model.start() }
                    try await waitUntil("Retry did not invoke the permission path") {
                        permission.calls == attempt && model.phase == .starting
                    }
                    permission.releaseFirst(false)
                    await start.value
                    try expect(model.canStart && model.phase == .idle && !model.hasPendingTranslations,
                               "A denied start failed to restore retry controls")
                }
                try expect(permission.calls == 3, "Retry clicks did not enter startup independently")
                try expect(model.segments.isEmpty, "Repeated startup failures invented caption content")
            }),
            ("an aborted run releases Start despite an uncooperative translation", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Before input failure."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "Before input failure.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Abort fixture translation never started") { probe.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                await model.receiveAudioProblem("Injected audio-input failure")
                try expect(ProcessInfo.processInfo.systemUptime - began < 1,
                           "Input failure waited for an uncooperative translation before enabling Start")
                try expect(model.canStart && model.phase == .idle && !model.hasPendingTranslations,
                           "Input failure left Start disabled by a canceled worker")
                try expect(model.queuedTranslations == 0, "Input failure left phantom queued translations")
                try expect(model.segments.count == 1 && model.segments[0].source == "Before input failure.",
                           "Input failure discarded recognized source")
                try expect(model.segments[0].translationError != nil && !model.segments[0].isFinal,
                           "Aborted translation was not preserved as retryable")
                probe.release(source: "Before input failure.", translation: "Late aborted Korean")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments[0].translation == nil && model.canStart,
                           "Late aborted output changed the caption or blocked Start again")
            }),
            ("finals preempt a stuck draft, coalesce revisions, and beat queued drafts", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Old draft", "First final."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Old draft", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("First draft never started") { probe.calls.count == 1 }
                model.receive(source: "Updated draft", audioStart: 0, audioEnd: 2, isFinal: false)
                model.receive(source: "First final.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Final remained blocked behind a canceled draft", seconds: 1) {
                    probe.calls.contains(.init(source: "First final.", context: false))
                }
                model.receive(source: "Newest draft", audioStart: 3, audioEnd: 4, isFinal: false)
                model.receive(source: "Second final.", audioStart: 4, audioEnd: 5, isFinal: true)
                probe.release(source: "First final.", translation: "첫 확정 문장.")
                try await waitUntil("Second final never translated") {
                    probe.calls.contains(.init(source: "Second final.", context: false))
                }
                let finalIndex = probe.calls.firstIndex(of: .init(source: "Second final.", context: false))!
                if let draftIndex = probe.calls.firstIndex(of: .init(source: "Newest draft", context: false)) {
                    try expect(finalIndex < draftIndex, "Queued draft ran before queued final")
                }
                probe.release(source: "Old draft", translation: "잘못된 이전 번역")
                try await waitUntil("Draft revisions did not finish", seconds: 3) { !model.hasPendingTranslations }
                try expect(model.segments.first?.source == "Updated draft", "Draft source was lost")
                try expect(model.segments.first?.translation == "KO: Updated draft", "Late draft overwrote current text")
                try expect(model.queuedTranslations == 0, "Queue counter stayed nonzero after drain")
                try expect(!probe.calls.contains(.init(source: "Old draft", context: true)), "Context ran while disabled")
            }),
            ("an unchanged in-flight draft becomes final without a second call", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Hello."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Draft never started") { probe.calls.count == 1 }
                model.receive(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await Task.sleep(for: .milliseconds(50))
                try expect(probe.calls.count == 1, "ASR confirmation repeated or preempted matching translation")
                probe.release(source: "Hello.", translation: "안녕하세요.")
                try await waitUntil("Confirmed in-flight draft did not finalize") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 1, "Matching final queued a redundant translation")
            }),
            ("final translation interrupts the draft admission wait", {
                let probe = TranslatorProbe()
                let model = makeModel(probe)
                model.receive(source: "First live hypothesis", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Initial draft did not translate") { !model.hasPendingTranslations && probe.calls.count == 1 }
                model.receive(source: "Changed live hypothesis", audioStart: 0, audioEnd: 2, isFinal: false)
                // The final arrives while the revised draft is still settling.
                try await Task.sleep(for: .milliseconds(15))
                let began = ProcessInfo.processInfo.systemUptime
                model.receive(source: "Urgent final.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Final remained inside the draft admission wait", seconds: 0.25) {
                    model.segments.last?.isFinal == true
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.25 &&
                    probe.calls[1] == .init(source: "Urgent final.", context: false),
                    "Final failed to wake draft admission or lost priority to the queued draft")
                try await waitUntil("Remaining current draft did not drain") { !model.hasPendingTranslations }
                try expect(model.segments[0].translation == "KO: Changed live hypothesis" &&
                    model.segments[1].translation == "KO: Urgent final." && model.segments[1].isFinal,
                    "Interrupting draft admission discarded a source or changed final output")
            }),
            ("a burst of draft revisions translates only its newest text without a long wait", {
                let probe = TranslatorProbe()
                let model = makeModel(probe)
                let began = ProcessInfo.processInfo.systemUptime
                // The recognizer delivers each revision as a separate actor turn.
                for (index, source) in ["The", "The proposal", "The proposal sounds"].enumerated() {
                    model.receive(source: source, audioStart: 0, audioEnd: Double(index + 1), isFinal: false)
                    try await Task.sleep(for: .milliseconds(3))
                }
                try await waitUntil("Newest burst revision waited behind an obsolete draft", seconds: 0.3) {
                    model.segments.first?.translation == "KO: The proposal sounds" && !model.hasPendingTranslations
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.3 &&
                    probe.calls == [.init(source: "The proposal sounds", context: false)] &&
                    model.segments.first?.isFinal == false,
                    "Draft admission translated an obsolete burst revision or finalized live speech")
            }),
            ("a steady trickle of draft revisions is translated within the hold limit", {
                let probe = TranslatorProbe()
                let model = makeModel(probe)
                // Revisions closer together than the settle time never go quiet.
                for index in 1...16 {
                    model.receive(source: "Trickle \(index)", audioStart: 0, audioEnd: Double(index), isFinal: false)
                    try await Task.sleep(for: .milliseconds(25))
                }
                try expect(!probe.calls.isEmpty && probe.calls.count <= 5,
                    "A continuous trickle starved draft translation or translated every revision")
                try await waitUntil("Final trickle revision did not drain") {
                    model.segments.first?.translation == "KO: Trickle 16" && !model.hasPendingTranslations
                }
            }),
            ("context waits for a quiet final tail and never starts behind a live draft", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Initial exact final translations did not finish") {
                    model.segments.count == 2 && model.segments.allSatisfy(\.isFinal)
                }
                model.receive(source: "Still speaking", audioStart: 2, audioEnd: 3, isFinal: false)
                try await waitUntil("Following draft did not translate") {
                    model.segments.last?.translation == "KO: Still speaking" && !model.hasPendingTranslations
                }
                try await Task.sleep(for: .milliseconds(850))
                try expect(!probe.calls.contains(where: \.context) &&
                    !model.displaySegments.contains(where: \.contextIsPending),
                    "Context started or stayed pending while the latest source was still a draft")
                let confirmedAt = ProcessInfo.processInfo.systemUptime
                model.receive(source: "Still speaking", audioStart: 2, audioEnd: 3, isFinal: true)
                try await Task.sleep(for: .milliseconds(350))
                try expect(!probe.calls.contains(where: \.context), "Context skipped the source quiet interval")
                try await waitUntil("Quiet confirmed final tail never received context") { probe.calls.contains(where: \.context) }
                try expect(ProcessInfo.processInfo.systemUptime - confirmedAt >= 0.70,
                    "Context started before the accepted source settled")
                let raw = model.segments
                probe.release(context: true, translation: "첫째, 둘째, 이어서 말했습니다.")
                try await waitUntil("Quiet context did not finish") { !model.hasPendingTranslations }
                try expect(model.segments == raw && model.displaySegments.count == 2 &&
                    model.displaySegments.last?.contextSegmentCount == 2 &&
                    model.recentCompactSegments().map(\.source) == ["Second.", "Still speaking"] &&
                    model.recentCompactSegments().allSatisfy(\.isFinal),
                    "Quiet context changed ASR records or exposed a merged passage in the compact feed")
            }),
            ("a current draft preempts held context and does not retry it during live speech", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Held context did not start") { probe.calls.contains(where: \.context) }
                let beforeDraft = model.segments
                let began = ProcessInfo.processInfo.systemUptime
                model.receive(source: "New live speech", audioStart: 2, audioEnd: 3, isFinal: false)
                try await waitUntil("Current draft waited for the context deadline", seconds: 0.35) {
                    model.segments.last?.translation == "KO: New live speech" && !model.hasPendingTranslations
                }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.35 &&
                    Array(model.segments.prefix(2)) == beforeDraft &&
                    !model.displaySegments.contains(where: \.contextIsPending),
                    "Draft context preemption damaged earlier exact captions or left pending gray state")
                let beforeLateResult = model.segments
                probe.release(source: "First. Second.", context: true, translation: "양보한 문맥의 늦은 번역입니다.")
                try await Task.sleep(for: .milliseconds(850))
                try expect(probe.calls.filter(\.context).count == 1 && model.segments == beforeLateResult &&
                    !model.displaySegments.contains { $0.translation == "양보한 문맥의 늦은 번역입니다." },
                    "Canceled context retried during a draft or accepted late obsolete output")
            }),
            ("compact retains readable phrases during queued finals and clears with a new conversation", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Second pending.", "Third pending."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "First readable.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First readable caption did not translate") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                let first = model.segments[0]
                model.receive(source: "Second pending.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Second baseline did not enter its held request") {
                    probe.calls.contains(.init(source: "Second pending.", context: false))
                }
                model.receive(source: "Third pending.", audioStart: 2, audioEnd: 3, isFinal: true)
                try expect(model.recentCompactSegments() == [first] &&
                    model.segments.suffix(2).allSatisfy { $0.translation == nil },
                    "Two untranslated newer phrases evicted the readable compact caption")
                probe.release(source: "Second pending.", translation: "둘째 구절입니다.")
                try await waitUntil("Third baseline did not enter its held request") {
                    probe.calls.contains(.init(source: "Third pending.", context: false))
                }
                try expect(model.recentCompactSegments().map(\.source) == ["First readable.", "Second pending."] &&
                    model.recentCompactSegments().allSatisfy(\.isFinal),
                    "Completing one queued phrase lost exact final state or the earlier readable phrase")
                probe.release(source: "Third pending.", translation: "셋째 구절입니다.")
                try await waitUntil("Queued final baselines did not drain") { !model.hasPendingTranslations }
                try expect(model.recentCompactSegments().map(\.source) == ["Second pending.", "Third pending."] &&
                    model.recentCompactSegments(limit: 1).map(\.source) == ["Third pending."] &&
                    model.recentCompactSegments(limit: 0).isEmpty,
                    "New readable phrases did not replace the compact tail in speech order")
                model.newSession()
                try expect(model.recentCompactSegments().isEmpty,
                    "A new conversation retained the previous compact caption")
            }),
            ("compact preserves current provisional state and exposes translation errors", {
                let probe = TranslatorProbe()
                probe.failuresRemaining = ["Failed next phrase.": 1]
                let model = makeModel(probe)
                model.receive(source: "Old live hypothesis", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Initial compact hypothesis did not translate") { !model.hasPendingTranslations }
                probe.heldSources = ["Corrected live hypothesis"]
                defer { probe.releaseAll() }
                model.receive(source: "Corrected live hypothesis", audioStart: 0, audioEnd: 2, isFinal: false)
                let currentDraft = model.recentCompactSegments().first
                try expect(currentDraft?.source == "Corrected live hypothesis" &&
                    currentDraft?.translation == "KO: Old live hypothesis" &&
                    currentDraft?.translatedRevision != currentDraft?.revision && currentDraft?.isFinal == false,
                    "Compact fallback cached an old source revision or falsely finalized stale translated text")
                try await waitUntil("Corrected draft did not enter its held translation") {
                    probe.calls.contains(.init(source: "Corrected live hypothesis", context: false))
                }
                probe.release(source: "Corrected live hypothesis", translation: "현재 수정된 구절입니다.")
                try await waitUntil("Corrected draft did not drain") { !model.hasPendingTranslations }
                model.receive(source: "Failed next phrase.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Injected translation failure was not recorded") { !model.hasPendingTranslations }
                let tail = model.recentCompactSegments()
                try expect(tail.count == 2 && tail.last?.source == "Failed next phrase." &&
                    tail.last?.translationError != nil && tail.last?.isFinal == false,
                    "Readable fallback masked the latest translation error")
                model.newSession()
                probe.heldSources.insert("First new pending.")
                model.receive(source: "First new pending.", audioStart: 0, audioEnd: 1, isFinal: false)
                try expect(model.recentCompactSegments().map(\.source) == ["First new pending."] &&
                    model.recentCompactSegments().first?.translation == nil,
                    "An untranslated new conversation reused text from the previous conversation")
                model.newSession()
            }),
            ("context goes gray, corrects earlier Korean, and preserves ASR records", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "I saw her duck.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First final did not translate") { model.segments.first?.isFinal == true }
                model.receive(source: "She bent down to avoid the ball.", audioStart: 1, audioEnd: 3, isFinal: true)
                try await waitUntil("Context was not scheduled") { probe.calls.contains(where: \.context) }
                let originals = model.segments
                try expect(model.displaySegments.allSatisfy(\.contextIsPending), "Context work was not shown as pending")
                try expect(model.displaySegments.allSatisfy { !$0.isFinal }, "Pending context stayed final-colored")
                probe.release(context: true, translation: "그녀가 공을 피하려고 몸을 숙이는 모습을 봤습니다.")
                try await waitUntil("Context did not replace display passage") {
                    model.displaySegments.count == 1 && !model.hasPendingTranslations
                }
                try expect(model.segments == originals, "Context changed stable ASR records")
                try expect(model.displaySegments[0].isFinal, "Completed context stayed gray")
                try expect(model.displaySegments[0].contextSegmentCount == 2, "Passage membership lost")
                try expect(model.displaySegments[0].translation == "그녀가 공을 피하려고 몸을 숙이는 모습을 봤습니다.",
                           "Earlier Korean was not reconsidered")
            }),
            ("a new final preempts uncooperative context and rejects its late result", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("First context never started") { probe.calls.contains(where: \.context) }
                let oldContextSource = "First. Second."
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("New final blocked behind stale context", seconds: 1) {
                    probe.calls.contains(.init(source: "Third.", context: false))
                }
                probe.release(source: oldContextSource, context: true, translation: "늦은 이전 문맥 결과")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "늦은 이전 문맥 결과" },
                           "Late superseded context changed captions")
                model.contextCorrectionEnabled = false
                try await waitUntil("Disabling context did not clear pending display", seconds: 1) {
                    !model.displaySegments.contains(where: \.contextIsPending) && !model.hasPendingTranslations
                }
                probe.release(context: true, translation: "설정 해제 후 도착한 결과")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "설정 해제 후 도착한 결과" },
                           "Disabled context still replaced captions")
            }),
            ("a new conversation rejects late old worker output", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Old conversation."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Old conversation.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Old worker never started") { probe.calls.count == 1 }
                model.newSession()
                model.receive(source: "New conversation.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("New worker failed to finish") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                probe.release(source: "Old conversation.", translation: "이전 대화의 늦은 번역")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments.count == 1 && model.segments[0].source == "New conversation.", "Old conversation reappeared")
                try expect(model.segments[0].translation == "KO: New conversation.", "Old worker polluted new translation")
                try expect(model.segments[0].translationError == nil, "Old worker polluted new error state")
                try expect(model.queuedTranslations == 0 && !model.hasPendingTranslations, "Old worker left scheduling state stuck")
            }),
            ("failed final translations retry through the production scheduler", {
                let probe = TranslatorProbe()
                probe.failuresRemaining["Retry me."] = 1
                let model = makeModel(probe)
                model.receive(source: "Retry me.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Injected failure did not finish") {
                    model.segments.first?.translationError != nil && !model.hasPendingTranslations
                }
                try expect(model.segments.first?.isFinal == false, "Failed final appeared complete")
                model.retryFailedTranslations()
                try await waitUntil("Retry did not recover exact final revision") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 2, "Retry did not make exactly one replacement call")
                try expect(model.segments.first?.translationError == nil, "Successful retry kept failure state")
                try expect(model.message == nil, "Successful retry kept a stale translation-failure warning")
            }),
            ("unexpected framework cancellation leaves the current final retryable", {
                let probe = TranslatorProbe()
                probe.cancellationsRemaining["Canceled final."] = 1
                let model = makeModel(probe)
                model.receive(source: "Canceled final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Unexpected cancellation vanished without a retryable failure") {
                    model.segments.first?.translationError != nil && !model.hasPendingTranslations
                }
                try expect(model.segments.first?.isFinal == false, "Canceled final was presented as complete")
                model.retryFailedTranslations()
                try await waitUntil("Unexpectedly canceled final could not recover") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 2, "Canceled source was not retried exactly once")
                try expect(model.segments.first?.translation == "KO: Canceled final.", "Retry used wrong source text")
            }),
            ("optional context failure preserves exact translations and later context recovers", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Optional context never started") { probe.calls.contains(where: \.context) }
                let originalTranslations = model.segments.map(\.translation)
                probe.failHeldContexts()
                try await waitUntil("Optional context failure left the display pending") { !model.hasPendingTranslations }
                try expect(model.displaySegments.allSatisfy(\.isFinal), "Optional context failure invalidated exact translations")
                try expect(model.segments.map(\.translation) == originalTranslations, "Optional failure erased valid Korean")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Optional failure appeared as isolated translation failure")
                probe.holdContexts = false
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Following context did not recover after optional failure") {
                    !model.hasPendingTranslations && model.displaySegments.contains { $0.contextSegmentCount == 2 }
                }
                try expect(probe.calls.filter(\.context).count == 2, "Later context was not retried after ordinary failure")
            }),
            ("context timeout clears gray state, reports degradation, and keeps live translation working", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Timeout fixture context never started") { probe.calls.contains(where: \.context) }
                try await waitUntil("Optional context timeout did not return", seconds: 5) { !model.hasPendingTranslations }
                try expect(model.displaySegments.allSatisfy(\.isFinal), "Context timeout left gray or unfinished captions")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Context timeout damaged validated translations")
                try expect(model.message?.contains("문맥 보정이 지연") == true, "Disabled correction after timeout was hidden")
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Caption translation did not continue after context timeout") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.filter(\.context).count == 1, "Timed-out correction kept blocking this run")
                probe.release(context: true, translation: "시간 초과 뒤 도착한 이전 문맥")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "시간 초과 뒤 도착한 이전 문맥" },
                           "Expired context changed completed captions")
            }),
            ("final overload stops input, preserves all sources, and retries every incomplete revision", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Final 0."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "Final 0.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Held final never started") { probe.calls.count == 1 }
                for index in 1...13 {
                    model.receive(source: "Final \(index).", audioStart: Double(index), audioEnd: Double(index + 1), isFinal: true)
                }
                try await waitUntil("Final queue overload did not stop input", seconds: 1) { model.phase != .listening }
                try await waitUntil("Overload stop never returned", seconds: 9) { model.phase == .idle && !model.hasPendingTranslations }
                let allSources = (0...13).map { "Final \($0)." }
                try expect(model.segments.map(\.source) == allSources, "Overload dropped a source-final caption")
                try expect(model.segments.allSatisfy { $0.translationError != nil && !$0.isFinal },
                           "Overload hid incomplete revisions or falsely finalized them")
                try expect(model.queuedTranslations == 0, "Overload left phantom queue items")
                probe.heldSources.removeAll()
                probe.release(source: "Final 0.", translation: "기한을 넘긴 결과")
                model.retryFailedTranslations()
                try expect(!model.canStart, "Capture was allowed to restart during recovery")
                try await waitUntil("Overload recovery did not retry all preserved sources", seconds: 3) {
                    model.segments.allSatisfy(\.isFinal) && !model.hasPendingTranslations
                }
                try expect(model.segments.map(\.source) == allSources, "Retry changed or dropped source text")
                try expect(model.segments[0].translation == "KO: Final 0.", "Late timed-out final replaced retry output")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Retry left an incomplete error state")
            }),
            ("unfinished native capacity stops input, preserves sources and recovers retry", {
                let probe = TranslatorProbe()
                probe.rejectsForCapacity = true
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "First retained.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second retained.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Physical capacity failure left input or controls blocked", seconds: 1) {
                    model.phase == .idle && !model.hasPendingTranslations
                }
                try expect(model.canStart, "Physical capacity failure did not restore Start")
                try expect(model.message?.contains("이전 번역 작업") == true, "Physical capacity degradation was hidden")
                try expect(model.segments.map(\.source) == ["First retained.", "Second retained."], "Physical capacity discarded sources")
                try expect(model.segments.allSatisfy { !$0.isFinal && $0.translationError != nil }, "Physical capacity finalized missing translations")
                probe.rejectsForCapacity = false
                model.retryFailedTranslations()
                try await waitUntil("Retry did not recover after native capacity became available") {
                    model.segments.allSatisfy(\.isFinal) && !model.hasPendingTranslations
                }
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Recovered native capacity left source failures")
            }),
            ("stopping has an overall deadline and retains incomplete source", {
                let probe = TranslatorProbe()
                probe.responseDelay = .seconds(4)
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "First pending.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second pending.", audioStart: 1, audioEnd: 2, isFinal: true)
                model.receive(source: "Third pending.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Worker never started") { probe.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                await model.stop()
                let duration = ProcessInfo.processInfo.systemUptime - began
                try expect(duration < 9, "Stop blocked beyond its overall deadline")
                try expect(model.phase == .idle && !model.hasPendingTranslations, "Stop left controls or worker blocked")
                try expect(model.segments.map(\.source) == ["First pending.", "Second pending.", "Third pending."], "Stop dropped ASR source")
                try expect(model.segments.contains { $0.translationError != nil && !$0.isFinal }, "Incomplete source falsely finalized")
                try expect(model.queuedTranslations == 0, "Stop retained phantom queue items")
            }),
            ("deadline and cancellation return even when underlying work ignores cancellation", {
                let probe = TranslatorProbe()
                probe.heldSources = ["timeout", "cancel"]
                defer { probe.releaseAll() }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    _ = try await OperationDeadline.run(seconds: 0.04, name: "check") {
                        try await probe.translate("timeout", context: false)
                    }
                    throw ModelCheckFailure(description: "Deadline accepted an unfinished operation")
                } catch is OperationDeadline.Expired { }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.5, "Deadline waited for uncooperative work")
                let task = Task {
                    try await OperationDeadline.run(seconds: 10, name: "cancel check") {
                        try await probe.translate("cancel", context: false)
                    }
                }
                try await waitUntil("Cancellation fixture never started") { probe.calls.count == 2 }
                let canceledAt = ProcessInfo.processInfo.systemUptime
                task.cancel()
                do {
                    _ = try await task.value
                    throw ModelCheckFailure(description: "Canceled deadline returned success")
                } catch is CancellationError { }
                try expect(ProcessInfo.processInfo.systemUptime - canceledAt < 0.5, "Cancellation waited for uncooperative work")
            })
        ]
        do {
            for (name, check) in checks {
                try await check()
                print("PASS: \(name)")
            }
            print("\(checks.count) production model checks passed; no microphone or live engine accuracy was tested.")
        } catch {
            if let savedContextPreference {
                UserDefaults.standard.set(savedContextPreference, forKey: "contextCorrectionEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled")
            }
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
