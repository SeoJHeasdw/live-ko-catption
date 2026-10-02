import CaptionCore
import CryptoKit
import Darwin
import Foundation
@preconcurrency import Translation

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Options {
    var model: String?
    var runtime = ".build/local-runtime/libcaption_local_translation.dylib"
    var output = "docs/qa/raw/dictionary-realtime-20261002.json"
    var rounds = 2

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw Failure("Expected an option value.") }
            let key = arguments[index], value = arguments[index + 1]
            switch key {
            case "--model": model = value
            case "--runtime": runtime = value
            case "--output": output = value
            case "--rounds":
                guard let number = Int(value), (1...4).contains(number) else { throw Failure("Rounds must be 1...4.") }
                rounds = number
            default: throw Failure("Unknown option: \(key)")
            }
            index += 2
        }
    }
}

private struct InputEvent: Codable, Sendable {
    let index: Int
    let source: String
    let plannedSeconds: Double
    let audioStart: Double
    let audioEnd: Double
    let isFinal: Bool
}

private struct Condition {
    let id: String
    let polish: Bool
    let dictionaries: Bool
    static let all = [
        Condition(id: "polishOff-none", polish: false, dictionaries: false),
        Condition(id: "polishOff-all3", polish: false, dictionaries: true),
        Condition(id: "polishOn-none", polish: true, dictionaries: false),
        Condition(id: "polishOn-all3", polish: true, dictionaries: true)
    ]
}

// These observers call the actual native engines. They do not add latency or
// fabricate results. The same warmed low-latency Apple lease is reused for all
// conditions of a direction, and one local engine is shared strictly serially.
@MainActor private final class ActualCalls {
    let direction: CaptionDirection
    let lease: TranslationSessionLease
    let engine: LocalTranslationEngine
    var began: TimeInterval = 0
    private(set) var apple: [[String: Any]] = []
    private(set) var local: [[String: Any]] = []
    private(set) var maximumActiveApple = 0
    private(set) var maximumActiveLocal = 0
    private var requests: [(index: Int, request: LocalTranslationRequest)] = []
    var activeAppleCount: Int { apple.filter { $0["status"] as? String == "in_flight" }.count }
    var activeLocalCount: Int { local.filter { $0["status"] as? String == "in_flight" }.count }

    init(direction: CaptionDirection, lease: TranslationSessionLease, engine: LocalTranslationEngine) {
        self.direction = direction; self.lease = lease; self.engine = engine
    }

    func baseline(_ source: String, context: Bool) async throws -> String {
        guard !context else { throw Failure("Context correction must remain disabled.") }
        let index = apple.count, start = ProcessInfo.processInfo.systemUptime
        apple.append(["source": source, "started_s": start - began, "status": "in_flight"])
        maximumActiveApple = max(maximumActiveApple, activeAppleCount)
        defer { apple[index]["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
        do {
            let text = try await lease.translate(source)
            try Task.checkCancellation()
            apple[index]["target"] = text; apple[index]["status"] = "completed"
            apple[index]["finished_s"] = ProcessInfo.processInfo.systemUptime - began
            return text
        } catch {
            apple[index]["status"] = error is CancellationError || Task.isCancelled ? "cancelled" : "failed"
            apple[index]["error"] = String(describing: error)
            throw error
        }
    }

    func refine(_ request: LocalTranslationRequest) async throws -> String {
        let index = local.count, start = ProcessInfo.processInfo.systemUptime
        local.append(["source": request.source, "baseline": request.baseline,
            "started_s": start - began, "status": "in_flight",
            "dictionary_ids": request.dictionaries.map(\.id).sorted()])
        requests.append((index, request))
        maximumActiveLocal = max(maximumActiveLocal, activeLocalCount)
        defer {
            local[index]["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            local[index]["finished_s"] = ProcessInfo.processInfo.systemUptime - began
        }
        do {
            // Production defaults: 1500 ms native generation and output guard.
            let result = try await engine.translate(request)
            try Task.checkCancellation()
            local[index]["status"] = "completed"; local[index]["target"] = result.text
            local[index]["guard_accepted"] = request.accepts(result.text)
            local[index]["statistics"] = statistics(result.statistics)
            return result.text
        } catch {
            local[index]["status"] = error is CancellationError || Task.isCancelled ? "cancelled" : "failed"
            local[index]["error"] = String(describing: error)
            if let native = error as? LocalTranslationError {
                switch native {
                case .native(let status, let json):
                    local[index]["native_status"] = status
                    if let data = json.data(using: .utf8),
                       let value = try? JSONDecoder().decode(LocalTranslationStatistics.self, from: data) {
                        local[index]["statistics"] = statistics(value)
                    }
                case .unsafeOutput: local[index]["guard_rejected"] = true
                case .busy: local[index]["busy_rejected"] = true
                default: break
                }
            }
            throw error
        }
    }

    func baselineMatches(source: String, target: String) -> Bool {
        apple.contains { $0["status"] as? String == "completed" &&
            $0["source"] as? String == source && $0["target"] as? String == target }
    }
    func localMatches(source: String, target: String) -> Bool {
        local.contains { $0["status"] as? String == "completed" &&
            $0["source"] as? String == source && $0["target"] as? String == target }
    }
    func otherSourceIsRefining(_ source: String) -> Bool {
        local.contains { $0["status"] as? String == "in_flight" && $0["source"] as? String != source }
    }
    // Prompt matching is comparatively expensive. Evidence must be assembled
    // after the timed observer stops, rather than blocking MainActor while a
    // real fast caption is waiting to be observed or the next input arrives.
    func appendPromptEvidenceAfterMeasurement() {
        for (index, request) in requests {
            local[index]["prompt"] = request.prompt
            local[index]["reference_pairs"] = request.relevantTerms.map { ["source": $0.0, "target": $0.1] }
        }
    }
    private func statistics(_ value: LocalTranslationStatistics) -> [String: Any] {
        ["ttft_ms": value.ttft_ms.map { $0 as Any } ?? NSNull(), "total_ms": value.total_ms,
            "prefill_ms": value.prefill_ms, "decode_ms": value.decode_ms,
            "prompt_tokens": value.prompt_tokens, "output_tokens": value.output_tokens,
            "cancelled": value.cancelled, "timed_out": value.timed_out, "truncated": value.truncated]
    }
}

@MainActor private final class Recorder {
    let calls: ActualCalls
    private(set) var eventRows: [[String: Any]] = []
    private(set) var snapshots: [[String: Any]] = []
    private(set) var failures: [String] = []
    private(set) var maximumFastQueue = 0
    private(set) var maximumPendingFinalBaselines = 0
    private(set) var maximumPendingNoDisplayChangeMs: Double = 0
    private(set) var messages: [[String: Any]] = []
    private(set) var observationSamples = 0
    private var previousDisplay: [CaptionSegment] = []
    private var previousCounts = [-1, -1, -1, -1]
    private var lastDisplayChange: Double = 0
    private var stableFinals: [UUID: CaptionSegment] = [:]
    private var previousMessage = ""

    init(calls: ActualCalls) { self.calls = calls }

    func deliver(_ event: InputEvent, to model: CaptionModel) {
        let arrived = now
        model.receive(source: event.source, audioStart: event.audioStart, audioEnd: event.audioEnd, isFinal: event.isFinal)
        guard let segment = model.segments.first(where: { $0.source == event.source && $0.audioStart == event.audioStart }) else {
            fail("Accepted input event has no exact source segment: \(event.index)")
            return
        }
        eventRows.append(["event_index": event.index, "source": event.source, "source_is_final": event.isFinal,
            "planned_s": event.plannedSeconds, "arrived_s": arrived,
            "scheduling_lateness_ms": max(0, arrived - event.plannedSeconds) * 1_000,
            "synthetic_audio_start_s": event.audioStart, "synthetic_audio_end_s": event.audioEnd,
            "segment_id": segment.id.uuidString, "revision": segment.revision,
            "prior_polish_active_at_input": calls.otherSourceIsRefining(event.source),
            "prior_polish_overlap_before_readable": calls.otherSourceIsRefining(event.source)])
        capture(model, reason: "input event")
    }

    func capture(_ model: CaptionModel, reason: String) {
        let elapsed = now
        let raw = model.segments, display = model.displaySegments
        observationSamples += 1
        maximumFastQueue = max(maximumFastQueue, model.queuedTranslations)
        let pendingBaselines = raw.filter { $0.sourceIsFinal && !$0.isFinal && $0.translation != nil && $0.translationError == nil }.count
        maximumPendingFinalBaselines = max(maximumPendingFinalBaselines, pendingBaselines)
        if model.queuedTranslations > 20 { fail("The visible fast queue exceeded the production final/draft bounds.") }
        if pendingBaselines > CaptionModel.polishWaitingLimit + 1 { fail("The visible pending final baselines exceeded one active plus the waiting limit.") }
        let displayChanged = display != previousDisplay
        if displayChanged { lastDisplayChange = elapsed; previousDisplay = display }
        if model.hasPendingTranslations {
            maximumPendingNoDisplayChangeMs = max(maximumPendingNoDisplayChangeMs, (elapsed - lastDisplayChange) * 1_000)
        }
        let message = model.localPolishMessage + " | " + (model.message ?? "")
        let messageChanged = message != previousMessage
        if messageChanged { messages.append(["observed_s": elapsed, "message": message]); previousMessage = message }
        for segment in raw {
            if let stable = stableFinals[segment.id], stable != segment { fail("An already finalized caption was rewritten after later input.") }
            if segment.isFinal {
                if !segment.sourceIsFinal || segment.translatedRevision != segment.revision || segment.translationError != nil {
                    fail("A final caption violates its exact-source revision invariant.")
                }
                stableFinals[segment.id] = segment
            }
            guard let target = segment.translation, !target.isEmpty else { continue }
            let apple = calls.baselineMatches(source: segment.source, target: target)
            let local = calls.localMatches(source: segment.source, target: target)
            // A readable old translation during a source revision remains a
            // permitted gray fallback, but is never counted as matching input.
            if segment.translatedRevision == segment.revision && !apple && !local {
                fail("An applied translation lacks an actual completed call for the exact source.")
            }
            for index in eventRows.indices where eventRows[index]["segment_id"] as? String == segment.id.uuidString &&
                eventRows[index]["revision"] as? Int == segment.revision && eventRows[index]["source"] as? String == segment.source {
                let arrived = eventRows[index]["arrived_s"] as! Double
                if eventRows[index]["first_readable_s"] == nil {
                    if calls.otherSourceIsRefining(segment.source) { eventRows[index]["prior_polish_overlap_before_readable"] = true }
                    if apple || local {
                        eventRows[index]["first_readable_s"] = elapsed
                        eventRows[index]["input_to_first_readable_ms"] = max(0, elapsed - arrived) * 1_000
                        eventRows[index]["first_readable_origin"] = apple ? "Apple" : "HY-MT2"
                        eventRows[index]["prior_polish_active_at_first_readable"] = calls.otherSourceIsRefining(segment.source)
                    }
                }
                if apple && eventRows[index]["first_matching_fast_baseline_s"] == nil {
                    eventRows[index]["first_matching_fast_baseline_s"] = elapsed
                    eventRows[index]["input_to_matching_fast_baseline_ms"] = max(0, elapsed - arrived) * 1_000
                }
                if segment.isFinal && eventRows[index]["first_final_s"] == nil {
                    eventRows[index]["first_final_s"] = elapsed
                    eventRows[index]["input_to_final_ms"] = max(0, elapsed - arrived) * 1_000
                    eventRows[index]["final_origin"] = local && !apple ? "HY-MT2" : "Apple_or_identical_HY"
                }
            }
        }
        let counts = [model.queuedTranslations, pendingBaselines, calls.activeAppleCount, calls.activeLocalCount]
        if displayChanged || messageChanged || counts != previousCounts || reason != "20ms observer" {
            snapshots.append(["observed_s": elapsed, "reason": reason, "queued_fast_translations": model.queuedTranslations,
                "visible_pending_final_baselines": pendingBaselines, "has_pending": model.hasPendingTranslations,
                "active_apple_calls": calls.activeAppleCount, "active_local_calls": calls.activeLocalCount,
                "rows": display.map(row)])
        }
        previousCounts = counts
    }

    func row(_ segment: CaptionSegment) -> [String: Any] {
        ["id": segment.id.uuidString, "source": segment.source,
            "target": segment.translation.map { $0 as Any } ?? NSNull(), "revision": segment.revision,
            "translated_revision": segment.translatedRevision.map { $0 as Any } ?? NSNull(),
            "source_is_final": segment.sourceIsFinal, "is_visual_final": segment.isFinal,
            "context_pending": segment.contextIsPending,
            "translation_error": segment.translationError.map { $0 as Any } ?? NSNull()]
    }
    func fail(_ message: String) { if !failures.contains(message) { failures.append(message) } }
    private var now: Double { ProcessInfo.processInfo.systemUptime - calls.began }
}

@main @MainActor
private struct DictionaryRealtimeChecks {
    static func main() async {
        do { try await run(Options(Array(CommandLine.arguments.dropFirst()))) }
        catch { FileHandle.standardError.write(Data("Dictionary realtime comparison failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }

    private static func run(_ options: Options) async throws {
        let manifest = LocalModelManifest.hyMT2
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let fallback = URL(fileURLWithPath: ".build/local-model/" + manifest.filename)
        let modelURL = options.model.map { URL(fileURLWithPath: $0) } ??
            (FileManager.default.fileExists(atPath: fallback.path) ? fallback :
                support.appendingPathComponent("Live Korean Captions/Models/" + manifest.filename))
        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              modelURL.lastPathComponent == manifest.filename, bytes == manifest.byteCount else {
            throw Failure("Installed model is not the pinned regular 1.8B Q6_K file.")
        }
        print("Verifying installed pinned model size and streaming SHA-256 before loading.")
        let hash = try await Task.detached { try digest(modelURL) }.value
        guard hash == manifest.sha256 else { throw Failure("Installed model SHA-256 differs from the pinned digest.") }
        let runtime = URL(fileURLWithPath: options.runtime)
        guard FileManager.default.fileExists(atPath: runtime.path) else { throw Failure("Installed local runtime is unavailable; no download/build requested.") }
        let output = URL(fileURLWithPath: options.output)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure("Refusing to overwrite an existing realtime report.") }
        var report: [String: Any] = ["schema_version": 1, "generated_at": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "mode": "clocked synthetic ASR-text replay through production CaptionModel, actual Apple/HY translation",
            "model": ["filename": manifest.filename, "actual_byte_count": bytes, "expected_byte_count": manifest.byteCount,
                "actual_sha256": hash, "expected_sha256": manifest.sha256,
                "pinned_download_url": manifest.downloadURL.absoluteString],
            "runtime_path": runtime.path, "rounds": options.rounds,
            "native_polish_timeout_ms": 1_500, "app_polish_timeout_ms": 1_800, "observer_interval_ms": 20,
            "latency_failure_guard_ms": 2_500, "stop_drain_failure_guard_ms": 12_000,
            "context_correction": false,
            "limitations": [
                "The input is authored public synthetic text, not recognized speech. No ASR, audio capture, microphone or speech permission is exercised.",
                "The synthetic audio ranges identify separate/revised segments only; all reported delay is measured from actual text-event delivery.",
                "The fixture contains six final sentences over 10 seconds and 100/200ms following-draft bursts; this is a targeted scheduler overlap test, not a continuous speech benchmark.",
                "20ms observations add sampling uncertainty and do not measure actual UI drawing or microphone-to-caption delay. Unchanged observations are counted but only state changes and input/stop snapshots are retained. Prompt/reference evidence is formatted after each run's timed observer stops.",
                "Installed Apple low-latency translation is prepared/warmed/reused per explicit direction; one verified local engine is prepared/warmed and all runs execute serially.",
                "Context correction is disabled to isolate the sentence-refinement lane. Start/permissions/device setup are bypassed.",
                "Latency guards detect severe stalls only; passing them is not evidence of acceptable realtime latency. Actual distributions and condition deltas must be reviewed.",
                "Model/output guards and invariants do not establish semantic translation accuracy or real-speaker recognition quality.",
                "No assets are downloaded, no private glossary is read, no saved preferences are left changed; network is not deliberately disabled."
            ]]
        let engine = LocalTranslationEngine(runtimeURL: runtime)
        var runs: [[String: Any]] = [], warmups: [[String: Any]] = []
        do {
            let loaded = ProcessInfo.processInfo.systemUptime
            try await engine.prepare(modelURL: modelURL)
            report["local_model_load_ms"] = (ProcessInfo.processInfo.systemUptime - loaded) * 1_000
            for direction in CaptionDirection.allCases {
                let availability = await LanguageAvailability(preferredStrategy: .lowLatency).status(
                    from: Locale.Language(identifier: direction.sourceLanguageCode), to: Locale.Language(identifier: direction.targetLanguageCode))
                guard availability == .installed else { throw Failure("Apple \(direction.rawValue) assets are not installed; no download requested.") }
                let lease = TranslationSessionLease(installedSource: Locale.Language(identifier: direction.sourceLanguageCode),
                    target: Locale.Language(identifier: direction.targetLanguageCode), preferredStrategy: .lowLatency)
                defer { lease.retire() }
                let warmStart = ProcessInfo.processInfo.systemUptime
                try await OperationDeadline.run(seconds: 12, name: "Apple warmup", onTimeout: { lease.retire() }) {
                    try await lease.prepareTranslation()
                    _ = try await lease.translate(direction == .englishToKorean ? "Hello." : "안녕하세요.")
                }
                let appleWarmMs = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
                let warm = try await engine.translate(LocalTranslationRequest(
                    source: direction == .englishToKorean ? "Hello." : "안녕하세요.", direction: direction))
                warmups.append(["direction": direction.rawValue, "apple_prepare_and_warm_ms": appleWarmMs,
                    "local_native_total_ms": warm.statistics.total_ms, "local_target": warm.text])
                for round in 1...options.rounds {
                    let ordered = round % 2 == 1 ? Condition.all : Array(Condition.all.reversed())
                    for condition in ordered {
                        print("Running \(direction.rawValue) round\(round) \(condition.id).")
                        let result = try await replay(direction: direction, round: round,
                            condition: condition, lease: lease, engine: engine)
                        runs.append(result)
                        report["runs"] = runs; report["warmups"] = warmups
                        report["passed_guardrails"] = runs.allSatisfy { $0["passed_guardrails"] as? Bool == true }
                        try save(report, to: output)
                    }
                }
            }
            report["summary"] = aggregate(runs)
            report["paired_condition_deltas"] = pairedComparisons(runs)
            report["passed_guardrails"] = runs.allSatisfy { $0["passed_guardrails"] as? Bool == true }
            report["runs"] = runs; report["warmups"] = warmups
            try save(report, to: output)
            print("Saved \(runs.count) sequential timing runs: \(output.path). Guardrails=\(report["passed_guardrails"]!)")
            if report["passed_guardrails"] as? Bool != true { throw Failure("One or more timing/lifecycle guardrails failed; inspect raw results.") }
        } catch {
            report["infrastructure_error"] = String(describing: error)
            report["runs"] = runs; report["warmups"] = warmups; report["passed_guardrails"] = false
            try? save(report, to: output)
            // The scoped engine frees its native handle synchronously when
            // ownership ends. Do not enqueue asynchronous unload before exit.
            engine.cancelActive()
            throw error
        }
    }

    private static func replay(direction: CaptionDirection, round: Int, condition: Condition,
                               lease: TranslationSessionLease, engine: LocalTranslationEngine) async throws -> [String: Any] {
        guard lease.activeNativeCount == 0, TranslationSessionLease.activeLiveCount == 0 else {
            throw Failure("A previous Apple await is still active; refusing to overlap timing fixtures.")
        }
        let suite = "io.javis.caption.dictionary-realtime.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("Could not create isolated preference suite.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("caption-dictionary-realtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let glossary = folder.appendingPathComponent("glossary.txt")
        try Data().write(to: glossary)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let selected = condition.dictionaries ? Set(BuiltInDictionaries.all.map(\.id)) : Set<String>()
        defaults.set(direction.rawValue, forKey: CaptionDirection.preferenceKey)
        defaults.set(selected.sorted(), forKey: CaptionDictionary.preferenceKey)
        defaults.set(false, forKey: "localPolishEnabled")
        let calls = ActualCalls(direction: direction, lease: lease, engine: engine)
        let model = CaptionModel(translationOverride: { try await calls.baseline($0, context: $1) },
            readinessOverride: { _ in true }, preferencesDefaults: defaults,
            polishOverride: { try await calls.refine($0) }, localEngine: engine, glossaryURL: glossary)
        let savedContext = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        model.contextCorrectionEnabled = false
        if let savedContext { UserDefaults.standard.set(savedContext, forKey: "contextCorrectionEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled") }
        model.isChecking = false; model.assetsReady = true
        model.polishEnabled = condition.polish
        if condition.polish { await model.prepareLocalModel() }
        model.phase = .listening
        calls.began = ProcessInfo.processInfo.systemUptime
        let recorder = Recorder(calls: calls)
        let events = fixture(direction)
        let observer = Task {
            while !Task.isCancelled {
                recorder.capture(model, reason: "20ms observer")
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
        }
        for event in events {
            let delay = event.plannedSeconds - (ProcessInfo.processInfo.systemUptime - calls.began)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            if model.phase != .listening { recorder.fail("Production model stopped before all input events were delivered."); break }
            recorder.deliver(event, to: model)
        }
        let stopBegan = ProcessInfo.processInfo.systemUptime
        await model.stop()
        // A logical stop can settle baseline display before native cancellation
        // physically returns. Do not start any following fixture until it does.
        for _ in 0..<200 where calls.activeAppleCount > 0 || calls.activeLocalCount > 0 || lease.activeNativeCount > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let drainMs = (ProcessInfo.processInfo.systemUptime - stopBegan) * 1_000
        let drained = calls.activeAppleCount == 0 && calls.activeLocalCount == 0 && lease.activeNativeCount == 0
        recorder.capture(model, reason: "stop and physical drain")
        let settled = model.segments
        try await Task.sleep(for: .milliseconds(200))
        recorder.capture(model, reason: "late-result stability check")
        if settled != model.segments { recorder.fail("A late result rewrote captions after stop drained.") }
        observer.cancel(); await observer.value
        calls.appendPromptEvidenceAfterMeasurement()
        if !drained { throw Failure("Native calls remained active after the stop/drain guard; refusing the next fixture.") }
        if drainMs > 12_000 { recorder.fail("Production stop/physical drain exceeded its failure guard.") }
        if model.hasPendingTranslations || model.queuedTranslations != 0 || model.phase != .idle {
            recorder.fail("Production stop left pending scheduling/lifecycle work.")
        }
        if model.segments.map(\.source) != events.filter(\.isFinal).map(\.source) || !model.segments.allSatisfy(\.isFinal) {
            recorder.fail("Final source text was changed/lost or not finalized.")
        }
        if calls.maximumActiveLocal > 1 { recorder.fail("The local engine lane overlapped physical calls.") }
        if model.selectedDirection != direction || model.selectedDictionaryIDs != selected { recorder.fail("Explicit direction/dictionary selection changed.") }
        if calls.local.contains(where: { ($0["dictionary_ids"] as? [String] ?? []) != selected.sorted() }) {
            recorder.fail("A final-refinement request used the wrong selected dictionaries.")
        }
        let finals = recorder.eventRows.filter { $0["source_is_final"] as? Bool == true }
        if finals.count != 6 || finals.contains(where: { $0["input_to_first_readable_ms"] == nil || $0["input_to_final_ms"] == nil }) {
            recorder.fail("A delivered final source never acquired an observed exact matching readable/final translation.")
        }
        let measured = recorder.eventRows.compactMap { $0["input_to_first_readable_ms"] as? Double }
        if measured.contains(where: { $0 > 2_500 }) { recorder.fail("An observed input-to-readable result exceeded the severe-stall failure guard.") }
        if recorder.eventRows.contains(where: { ($0["scheduling_lateness_ms"] as? Double ?? 0) > 1_000 }) {
            recorder.fail("Input scheduling was more than one second late; cadence comparison is invalid.")
        }
        let localSuccess = calls.local.filter { $0["status"] as? String == "completed" }.count
        let attemptedSources = Set(calls.local.compactMap { $0["source"] as? String })
        let baselineWithoutLocal = condition.polish ? model.segments.filter { !attemptedSources.contains($0.source) }.count : 0
        let nextDrafts = recorder.eventRows.filter { $0["source_is_final"] as? Bool == false &&
            $0["prior_polish_overlap_before_readable"] as? Bool == true }
        let finalRows = model.segments.map(recorder.row)
        let summary: [String: Any] = [
                "all_input_readable_ms": distribution(measured),
                "final_input_fast_baseline_ms": distribution(finals.compactMap { $0["input_to_matching_fast_baseline_ms"] as? Double }),
                "final_input_to_visual_final_ms": distribution(finals.compactMap { $0["input_to_final_ms"] as? Double }),
                "next_draft_during_prior_polish_ms": distribution(nextDrafts.compactMap { $0["input_to_first_readable_ms"] as? Double }),
                "next_draft_overlap_events": nextDrafts.count,
                "superseded_or_unobserved_drafts": recorder.eventRows.filter { $0["source_is_final"] as? Bool == false && $0["first_readable_s"] == nil }.count,
                "apple_call_wall_ms": distribution(calls.apple.compactMap { $0["wall_ms"] as? Double }),
                "local_call_wall_ms": distribution(calls.local.compactMap { $0["wall_ms"] as? Double }),
                "local_completed": localSuccess,
                "local_native_timeouts": calls.local.filter { $0["native_status"] as? Int32 == 2 }.count,
                "local_guard_rejections": calls.local.filter { $0["guard_rejected"] as? Bool == true }.count,
                "local_cancelled": calls.local.filter { $0["status"] as? String == "cancelled" }.count,
                "local_busy_rejections": calls.local.filter { $0["busy_rejected"] as? Bool == true }.count,
                "visual_finals_matching_local": model.segments.filter { calls.localMatches(source: $0.source, target: $0.translation ?? "") }.count,
                "baseline_finals_without_local_attempt": baselineWithoutLocal,
                "backlog_skip_message_observed": recorder.messages.contains { ($0["message"] as? String ?? "").contains("새 문장을 우선") },
                "maximum_fast_queue": recorder.maximumFastQueue,
                "maximum_visible_pending_final_baselines": recorder.maximumPendingFinalBaselines,
                "maximum_active_apple_calls": calls.maximumActiveApple,
                "maximum_active_local_calls": calls.maximumActiveLocal,
                "maximum_pending_without_display_change_ms": recorder.maximumPendingNoDisplayChangeMs,
                "stop_and_physical_drain_ms": drainMs,
                "drained": drained, "late_rewrite_absent": settled == model.segments
            ]
        let result: [String: Any] = ["direction": direction.rawValue, "round": round, "condition": condition.id,
            "polish_enabled": condition.polish, "dictionary_ids": selected.sorted(),
            "passed_guardrails": recorder.failures.isEmpty, "failures": recorder.failures,
            "events": recorder.eventRows, "snapshots": recorder.snapshots, "observation_samples": recorder.observationSamples,
            "messages": recorder.messages, "apple_calls": calls.apple, "local_calls": calls.local,
            "final_rows": finalRows, "summary": summary]
        return result
    }

    private static func fixture(_ direction: CaptionDirection) -> [InputEvent] {
        let english = ["IBM watsonx.ai supports generative AI.", "Assess credit risk before enabling open banking.",
            "A large language model uses retrieval-augmented generation.", "IBM Db2 stores the audit trail.",
            "Do not change the transaction limit of 3.", "I cannot recall our planning meeting."]
        let korean = ["IBM watsonx.ai는 생성형 AI를 지원합니다.", "오픈 뱅킹을 도입하기 전에 신용 리스크를 평가하세요.",
            "대규모 언어 모델은 검색 증강 생성을 사용합니다.", "IBM Db2는 감사 추적을 저장합니다.",
            "거래 한도 3을 변경하지 마세요.", "지난 계획 회의가 기억나지 않습니다."]
        let text = direction == .englishToKorean ? english : korean
        let drafts = direction == .englishToKorean ? ["Assess credit risk", "A large language model", "IBM Db2", "Do not change", "I cannot recall"] :
            ["신용 리스크를 평가", "대규모 언어 모델", "IBM Db2", "변경하지", "기억나지"]
        let finals = [0.0, 1.9, 4.0, 6.0, 8.1, 10.0]
        var result = [InputEvent(index: 0, source: text[0], plannedSeconds: 0,
            audioStart: 0, audioEnd: 1, isFinal: true)]
        for index in 1..<text.count {
            let start = Double(index) * 2
            result.append(InputEvent(index: result.count, source: drafts[index - 1], plannedSeconds: finals[index - 1] + 0.1,
                audioStart: start, audioEnd: start + 0.5, isFinal: false))
            result.append(InputEvent(index: result.count, source: text[index], plannedSeconds: finals[index - 1] + 0.2,
                audioStart: start, audioEnd: start + 1.5, isFinal: false))
            result.append(InputEvent(index: result.count, source: text[index], plannedSeconds: finals[index],
                audioStart: start, audioEnd: start + 1.5, isFinal: true))
        }
        return result
    }

    private static func distribution(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        return ["count": sorted.count, "min_ms": sorted[0], "median_ms": median,
            "p95_ms": sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "max_ms": sorted.last!]
    }

    private static func aggregate(_ runs: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for direction in CaptionDirection.allCases {
            for condition in Condition.all {
                let selected = runs.filter { $0["direction"] as? String == direction.rawValue && $0["condition"] as? String == condition.id }
                let events = selected.flatMap { $0["events"] as? [[String: Any]] ?? [] }
                let finals = events.filter { $0["source_is_final"] as? Bool == true }
                let drafts = events.filter { $0["source_is_final"] as? Bool == false }
                let overlap = drafts.filter { $0["prior_polish_overlap_before_readable"] as? Bool == true }
                let summaries = selected.compactMap { $0["summary"] as? [String: Any] }
                result.append(["direction": direction.rawValue, "condition": condition.id, "runs": selected.count,
                    "final_input_fast_baseline_ms": distribution(finals.compactMap { $0["input_to_matching_fast_baseline_ms"] as? Double }),
                    "draft_input_readable_ms": distribution(drafts.compactMap { $0["input_to_first_readable_ms"] as? Double }),
                    "final_input_to_visual_final_ms": distribution(finals.compactMap { $0["input_to_final_ms"] as? Double }),
                    "next_draft_during_prior_polish_ms": distribution(overlap.compactMap { $0["input_to_first_readable_ms"] as? Double }),
                    "local_completed": summaries.reduce(0) { $0 + ($1["local_completed"] as? Int ?? 0) },
                    "local_native_timeouts": summaries.reduce(0) { $0 + ($1["local_native_timeouts"] as? Int ?? 0) },
                    "local_guard_rejections": summaries.reduce(0) { $0 + ($1["local_guard_rejections"] as? Int ?? 0) },
                    "baseline_finals_without_local_attempt": summaries.reduce(0) { $0 + ($1["baseline_finals_without_local_attempt"] as? Int ?? 0) },
                    "maximum_fast_queue": summaries.compactMap { $0["maximum_fast_queue"] as? Int }.max() ?? 0,
                    "maximum_visible_pending_final_baselines": summaries.compactMap { $0["maximum_visible_pending_final_baselines"] as? Int }.max() ?? 0])
            }
        }
        return result
    }

    private static func pairedComparisons(_ runs: [[String: Any]]) -> [[String: Any]] {
        let contrasts = [("polishOff-none", "polishOff-all3"), ("polishOn-none", "polishOn-all3"),
            ("polishOff-none", "polishOn-none"), ("polishOff-all3", "polishOn-all3")]
        var result: [[String: Any]] = []
        for direction in CaptionDirection.allCases {
            for (from, to) in contrasts {
                func indexed(_ condition: String) -> [String: [String: Any]] {
                    var rows: [String: [String: Any]] = [:]
                    for run in runs where run["direction"] as? String == direction.rawValue && run["condition"] as? String == condition {
                        let round = run["round"] as! Int
                        for event in run["events"] as? [[String: Any]] ?? [] where event["source_is_final"] as? Bool == false {
                            let index = event["event_index"] as! Int
                            rows["\(round):\(index)"] = event
                        }
                    }
                    return rows
                }
                let left = indexed(from), right = indexed(to)
                var differences: [Double] = []
                for (key, event) in left {
                    if let earlier = event["input_to_first_readable_ms"] as? Double,
                       let later = right[key]?["input_to_first_readable_ms"] as? Double {
                        differences.append(later - earlier)
                    }
                }
                result.append(["direction": direction.rawValue, "from_condition": from, "to_condition": to,
                    "definition": "to minus from for the same direction, round and draft-event index; missing readable events excluded; positive means observed slower",
                    "draft_readable_delta_ms": distribution(differences),
                    "paired_draft_events": differences.count, "possible_draft_events": left.count,
                    "unpaired_draft_events": left.count - differences.count])
            }
        }
        return result
    }

    private nonisolated static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func save(_ report: [String: Any], to output: URL) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output, options: .atomic)
    }
}
