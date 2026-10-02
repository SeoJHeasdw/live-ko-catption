@preconcurrency import AVFoundation
import CaptionCore
import CoreMedia
import CryptoKit
import Foundation
import Speech
@preconcurrency import Translation

private struct Fixture: Decodable {
    let id: String
    let direction: String
    let domain: String
    let voice: String
    let text: String
    let meaning: String
}

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class PumpProblems: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func record(_ message: String) { lock.withLock { messages.append(message) } }
    var all: [String] { lock.withLock { messages } }
}

// Construct the tap outside MainActor and exercise the same foreign-thread
// callback bridge as production, using file input rather than any audio device.
private final class FileTapInvocation: @unchecked Sendable {
    private let block: AVAudioNodeTapBlock
    private let buffer: AVAudioPCMBuffer
    init(pump: AudioPump, buffer: AVAudioPCMBuffer) {
        block = pump.makeTapBlock()
        self.buffer = buffer
    }
    func invoke() { block(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)) }
}

private final class SessionCancellation: @unchecked Sendable {
    let lease: TranslationSessionLease
    init(_ lease: TranslationSessionLease) { self.lease = lease }
    func cancel() { Task { @MainActor in lease.retire() } }
}

@MainActor private final class ActualCalls {
    let direction: CaptionDirection
    let engine: LocalTranslationEngine
    var began: TimeInterval = 0
    private(set) var apple: [[String: Any]] = []
    private(set) var local: [[String: Any]] = []
    private var active: [UUID: SessionCancellation] = [:]
    var activeAppleCount: Int { active.count }
    var activeLocalCount: Int { local.filter { $0["status"] as? String == "in_flight" }.count }

    init(direction: CaptionDirection, engine: LocalTranslationEngine) {
        self.direction = direction
        self.engine = engine
    }

    func baseline(_ source: String, context: Bool) async throws -> String {
        let lease = TranslationSessionLease(installedSource: Locale.Language(identifier: direction.sourceLanguageCode),
            target: Locale.Language(identifier: direction.targetLanguageCode),
            preferredStrategy: context ? .highFidelity : .lowLatency)
        let cancellation = SessionCancellation(lease)
        let id = UUID()
        let index = apple.count
        let start = ProcessInfo.processInfo.systemUptime
        apple.append(["id": id.uuidString, "source": source, "is_context": context,
            "direction": direction.rawValue, "started_after_stream_seconds": start - began, "status": "in_flight"])
        active[id] = cancellation
        defer {
            lease.retire(); active.removeValue(forKey: id)
            apple[index]["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        do {
            let text = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let text = try await lease.translate(source)
                try Task.checkCancellation()
                return text
            } onCancel: { cancellation.cancel() }
            apple[index]["status"] = "completed"
            apple[index]["target"] = text
            return text
        } catch {
            apple[index]["status"] = error is CancellationError || Task.isCancelled ? "cancelled" : "failed"
            apple[index]["error"] = error.localizedDescription
            throw error
        }
    }

    func refine(_ request: LocalTranslationRequest) async throws -> String {
        let index = local.count
        let start = ProcessInfo.processInfo.systemUptime
        local.append(["source": request.source, "baseline": request.baseline,
            "previous_sentence": request.previousSentence, "direction": request.direction.rawValue,
            "dictionary_ids": request.dictionaries.map(\.id).sorted(), "started_after_stream_seconds": start - began, "status": "in_flight"])
        defer { local[index]["wall_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1_000 }
        do {
            let result = try await engine.translate(request, timeoutMilliseconds: 1_500)
            try Task.checkCancellation()
            let measured = result.statistics
            local[index]["status"] = "completed"
            local[index]["target"] = result.text
            local[index]["guard_accepted"] = request.accepts(result.text)
            local[index]["statistics"] = ["ttft_ms": measured.ttft_ms.map { $0 as Any } ?? NSNull(),
                "total_ms": measured.total_ms, "prefill_ms": measured.prefill_ms, "decode_ms": measured.decode_ms,
                "prompt_tokens": measured.prompt_tokens, "output_tokens": measured.output_tokens,
                "cancelled": measured.cancelled, "timed_out": measured.timed_out, "truncated": measured.truncated]
            return result.text
        } catch {
            local[index]["status"] = error is CancellationError || Task.isCancelled ? "cancelled" : "failed"
            local[index]["error"] = error.localizedDescription
            throw error
        }
    }

    func matchingEngines(source: String, target: String) -> [String] {
        var engines: [String] = []
        if apple.contains(where: { $0["status"] as? String == "completed" &&
            $0["source"] as? String == source && $0["target"] as? String == target }) { engines.append("Apple") }
        if local.contains(where: { $0["status"] as? String == "completed" && $0["guard_accepted"] as? Bool == true &&
            $0["source"] as? String == source && $0["target"] as? String == target }) { engines.append("HY-MT2") }
        return engines
    }
    func origin(source: String, target: String) -> String? {
        let engines = matchingEngines(source: source, target: target)
        return engines.contains("HY-MT2") ? "HY-MT2" : engines.first
    }
    func cancelAll() { for cancellation in active.values { cancellation.cancel() }; engine.cancelActive() }
}

@MainActor private final class Recorder {
    let began: TimeInterval
    let calls: ActualCalls
    private var previousRaw: [CaptionSegment] = []
    private var previousDisplay: [CaptionSegment] = []
    private(set) var snapshots: [[String: Any]] = []
    private(set) var observations: [[String: Any]] = []
    private(set) var failures: [String] = []
    private(set) var maximumQueue = 0
    private(set) var grayObservations = 0
    private(set) var contextObservations = 0
    private(set) var localFinalObservations = 0

    init(began: TimeInterval, calls: ActualCalls) { self.began = began; self.calls = calls }

    func capture(_ model: CaptionModel, reason: String) {
        maximumQueue = max(maximumQueue, model.queuedTranslations)
        let raw = model.segments, display = model.displaySegments
        guard raw != previousRaw || display != previousDisplay else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        for segment in raw {
            if segment.isFinal && (!segment.sourceIsFinal || segment.translatedRevision != segment.revision || segment.translationError != nil) {
                fail("Final raw segment violates the exact-current-source invariant.")
            }
            if segment.translatedRevision == segment.revision, let target = segment.translation,
               calls.origin(source: segment.source, target: target) == nil {
                fail("Raw translation lacks a completed Apple/HY call for its exact source.")
            }
        }
        for segment in display {
            if segment.isFinal && (segment.contextIsPending || !segment.sourceIsFinal ||
                segment.translatedRevision != segment.revision || segment.translationError != nil) {
                fail("Displayed final segment violates the revision/pending invariant.")
            }
            if segment.contextSegmentCount > 1 {
                let first = raw.firstIndex { $0.id == segment.id }
                let members = first.map { Array(raw.dropFirst($0).prefix(segment.contextSegmentCount)) } ?? []
                if members.count != segment.contextSegmentCount || !members.allSatisfy(\.sourceIsFinal) ||
                    normalized(members.map(\.source).joined(separator: " ")) != normalized(segment.source) {
                    fail("Context display does not preserve its actual ASR members.")
                }
            }
            guard let target = segment.translation, !target.isEmpty else { continue }
            let origin = calls.origin(source: segment.source, target: target)
            if segment.isFinal && origin == nil { fail("Displayed final translation has no matching actual source/target call.") }
            if !segment.isFinal { grayObservations += 1 }
            if segment.contextIsPending { contextObservations += 1 }
            if segment.isFinal && origin == "HY-MT2" { localFinalObservations += 1 }
            var observation = row(segment)
            observation["observed_after_stream_seconds"] = elapsed
            observation["after_corresponding_file_audio_end_seconds"] = elapsed - segment.audioEnd
            observation["matching_completed_engine"] = origin.map { $0 as Any } ?? NSNull()
            observation["matching_completed_engines"] = calls.matchingEngines(source: segment.source, target: target)
            observations.append(observation)
        }
        if snapshots.count < 3_000 {
            snapshots.append(["observed_after_stream_seconds": elapsed, "reason": reason,
                "queued_translations": model.queuedTranslations, "has_pending_translations": model.hasPendingTranslations,
                "rows": display.map(row)])
        } else { fail("Bounded state recorder exceeded its snapshot capacity.") }
        previousRaw = raw; previousDisplay = display
    }

    func row(_ segment: CaptionSegment) -> [String: Any] {
        ["id": segment.id.uuidString, "source": segment.source,
            "target": segment.translation.map { $0 as Any } ?? NSNull(), "source_revision": segment.revision,
            "translated_revision": segment.translatedRevision.map { $0 as Any } ?? NSNull(),
            "source_is_final": segment.sourceIsFinal, "is_visual_final": segment.isFinal,
            "context_is_pending": segment.contextIsPending, "context_segment_count": segment.contextSegmentCount,
            "translation_error": segment.translationError.map { $0 as Any } ?? NSNull(),
            "audio_start_seconds": segment.audioStart, "audio_end_seconds": segment.audioEnd]
    }
    private func fail(_ message: String) { if !failures.contains(message) { failures.append(message) } }
}

private func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

@main @MainActor
struct BidirectionalPolishPipelineChecks {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let comparison = arguments.last == "--dictionary-comparison"
            if comparison { arguments.removeLast() }
            guard arguments.count == 5 else {
                throw Failure("Usage: BidirectionalPolishPipelineChecks FIXTURES_JSON AUDIO_DIRECTORY MODEL_GGUF RUNTIME_DYLIB REPORT_JSON [--dictionary-comparison]")
            }
            let fixtures = try JSONDecoder().decode([Fixture].self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
            guard !fixtures.isEmpty else { throw Failure("No audio fixtures were supplied.") }
            let modelDigest = try await verifyPinnedModel(URL(fileURLWithPath: arguments[2]))
            let engine = LocalTranslationEngine(runtimeURL: URL(fileURLWithPath: arguments[3]))
            let loadStart = ProcessInfo.processInfo.systemUptime
            try await engine.prepare(modelURL: URL(fileURLWithPath: arguments[2]))
            let loadMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1_000
            var warmups: [[String: Any]] = []
            for direction in CaptionDirection.allCases {
                let result = try await engine.translate(LocalTranslationRequest(
                    source: direction == .englishToKorean ? "Hello." : "안녕하세요.", direction: direction),
                    timeoutMilliseconds: 3_000)
                warmups.append(["direction": direction.rawValue, "target": result.text,
                    "native_total_ms": result.statistics.total_ms, "native_ttft_ms": result.statistics.ttft_ms.map { $0 as Any } ?? NSNull()])
            }
            var reports: [[String: Any]] = []
            let allIDs = Set(BuiltInDictionaries.all.map(\.id))
            let plans: [(round: Int, condition: String, ids: Set<String>?)] = comparison ? [
                (1, "none", []), (1, "all_three", allIDs),
                (2, "all_three", allIDs), (2, "none", [])
            ] : [(0, "fixture_default", nil)]
            for plan in plans {
                for fixture in fixtures {
                    let suffix = comparison ? " round=\(plan.round) dictionaries=\(plan.condition)" : ""
                    FileHandle.standardOutput.write(Data("Running paced file pipeline: \(fixture.id)\(suffix)\n".utf8))
                    var result: [String: Any]
                    do { result = try await run(fixture: fixture,
                        fileURL: URL(fileURLWithPath: arguments[1]).appendingPathComponent(fixture.id + ".aiff"),
                        engine: engine, dictionaryIDs: plan.ids, comparison: comparison) }
                    catch { result = ["fixture": fixture.id, "passed": false, "setup_or_pipeline_error": error.localizedDescription] }
                    if comparison {
                        result["comparison_round"] = plan.round
                        result["dictionary_condition"] = plan.condition
                        result["comparison_run_index"] = reports.count
                    }
                    reports.append(result)
                }
            }
            let report: [String: Any] = ["schema_version": comparison ? 2 : 1, "passed": reports.allSatisfy { $0["passed"] as? Bool == true },
                "recorded_at": ISO8601DateFormatter().string(from: Date()), "mode": "paced synthetic audio file → actual Apple ASR → production scheduler → Apple baseline + optional HY final/context translation",
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "local_model_load_ms": loadMs, "verified_model_sha256": modelDigest,
                "native_polish_timeout_ms": 1_500, "production_polish_deadline_seconds": 1.8,
                "dictionary_comparison": comparison,
                "warmups_before_streaming": warmups, "fixtures": reports,
                "limitations": ["No microphone, audio device, or UI window was opened; these are public synthetic say voice fixtures.",
                    "Each 100ms file chunk is delivered at its corresponding audio end; observation polls every20ms and excludes UI drawing and microphone hardware latency.",
                    "App start/permissions/device selection are bypassed. Production receive, exact-revision state, queues, final-only polish, context and stop are exercised.",
                    "Local runtime is prepared/warmed before file streaming. Real Apple baseline calls use production leases created per call; the app normally reuses its lowLatency lease.",
                    "Passing invariants and syntax/numeric guards does not establish real-speaker recognition or semantic translation accuracy.",
                    "Direction is selected explicitly per fixture. No automatic language detection, cloud request, system audio, sibling engine, or new model download is used.",
                    "Dictionary comparison reuses identical audio files sequentially in none→all and all→none order; it does not control OS load, thermals, ASR variation or real microphone/UI latency.",
                    "Matching engine lists preserve ambiguity when Apple and HY return identical text. Separate Apple, any-final and HY-final metrics are first observed exact-current captions, not UI-render timings."]]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: URL(fileURLWithPath: arguments[4]), options: .atomic)
            print("Report saved: \(arguments[4]); passed=\(report["passed"]!)")
            if report["passed"] as? Bool != true { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("File pipeline check failed: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }

    private static func verifyPinnedModel(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let manifest = LocalModelManifest.hyMT2
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard size?.uint64Value == manifest.byteCount else { throw Failure("Model size differs from the pinned Hy-MT2-1.8B Q6_K manifest.") }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hasher = SHA256()
            var bytes: UInt64 = 0
            while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                bytes += UInt64(chunk.count)
                guard bytes <= manifest.byteCount else { throw Failure("Model grew beyond its pinned size during verification.") }
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == manifest.byteCount, digest == manifest.sha256 else { throw Failure("Model SHA256 differs from the pinned Hy-MT2-1.8B Q6_K manifest.") }
            return digest
        }.value
    }

    private static func run(fixture: Fixture, fileURL: URL, engine: LocalTranslationEngine,
        dictionaryIDs: Set<String>? = nil, comparison: Bool = false) async throws -> [String: Any] {
        guard let direction = CaptionDirection(rawValue: fixture.direction), let domain = TranslationDomain(rawValue: fixture.domain),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: direction.speechLocaleIdentifier)) else {
            throw Failure("Unsupported explicit fixture direction/domain or speech locale.")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let reserved = await AssetInventory.reservedLocales
        let alreadyReserved = reserved.contains { $0.identifier.replacingOccurrences(of: "_", with: "-") == locale.identifier.replacingOccurrences(of: "_", with: "-") }
        let ownsReservation = alreadyReserved ? false : try await AssetInventory.reserve(locale: locale)
        do {
            let speech = await AssetInventory.status(forModules: [transcriber])
            let translation = await LanguageAvailability(preferredStrategy: .lowLatency).status(
                from: Locale.Language(identifier: direction.sourceLanguageCode), to: Locale.Language(identifier: direction.targetLanguageCode))
            guard speech == .installed, translation == .installed else {
                throw Failure("SETUP_REQUIRED: \(direction.rawValue), speech=\(speech), Appletranslation=\(translation); this check never downloads language assets.")
            }
            guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure("No analyzer input format.") }
            let result = try await stream(fixture: fixture, direction: direction, domain: domain,
                fileURL: fileURL, transcriber: transcriber, target: target, engine: engine,
                dictionaryIDs: dictionaryIDs, comparison: comparison)
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            return result
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private static func stream(fixture: Fixture, direction: CaptionDirection, domain: TranslationDomain,
        fileURL: URL, transcriber: SpeechTranscriber, target: AVAudioFormat, engine: LocalTranslationEngine,
        dictionaryIDs: Set<String>?, comparison: Bool) async throws -> [String: Any] {
        let file = try AVAudioFile(forReading: fileURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw Failure("Empty audio fixture.") }
        let problems = PumpProblems()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let pump = try AudioPump(source: file.processingFormat, target: target, continuation: continuation,
            onLevel: { _ in }, onProblem: { problems.record($0) })
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: target)
        let calls = ActualCalls(direction: direction, engine: engine)
        let suite = "LiveKoCaption.BidirectionalFileCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dictionaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-dictionaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dictionaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dictionaryDirectory) }
        let glossaryURL = dictionaryDirectory.appendingPathComponent("glossary.txt")
        let selectedDictionaryIDs: Set<String>
        if let dictionaryIDs { selectedDictionaryIDs = dictionaryIDs }
        else {
            switch domain {
            case .general: selectedDictionaryIDs = []
            case .it: selectedDictionaryIDs = [BuiltInDictionaries.aiID]
            case .custom: selectedDictionaryIDs = [BuiltInDictionaries.aiID, CaptionDictionary.legacyPersonalID]
            }
        }
        // Historical fixtures carry no private glossary terms. Keep this empty
        // local file isolated from the user's actual dictionaries.
        if selectedDictionaryIDs.contains(CaptionDictionary.legacyPersonalID) { try Data().write(to: glossaryURL) }
        defaults.set(direction.rawValue, forKey: CaptionDirection.preferenceKey)
        defaults.set(selectedDictionaryIDs.sorted(), forKey: CaptionDictionary.preferenceKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CaptionModel(translationOverride: { text, context in try await calls.baseline(text, context: context) },
            preferencesDefaults: defaults, polishOverride: { try await calls.refine($0) },
            polishTimeoutSeconds: 1.8, localEngine: engine, glossaryURL: glossaryURL)
        let savedContext = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        model.contextCorrectionEnabled = true
        if let savedContext { UserDefaults.standard.set(savedContext, forKey: "contextCorrectionEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled") }
        model.isChecking = false; model.assetsReady = true; model.polishEnabled = true
        await model.prepareLocalModel()
        model.phase = .listening
        let began = ProcessInfo.processInfo.systemUptime
        calls.began = began
        let recorder = Recorder(began: began, calls: calls)
        var events: [[String: Any]] = [], finalized: [String] = []
        var provisional = 0
        let observer = Task {
            while !Task.isCancelled {
                recorder.capture(model, reason: "20ms polling")
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
        }
        let results = Task {
            for try await result in transcriber.results {
                let start = CMTimeGetSeconds(result.range.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                let source = String(result.text.characters)
                events.append(["source": source, "is_final": result.isFinal, "audio_start_seconds": start, "audio_end_seconds": end,
                    "arrived_after_stream_seconds": ProcessInfo.processInfo.systemUptime - began])
                if result.isFinal { finalized.append(source.trimmingCharacters(in: .whitespacesAndNewlines)) } else { provisional += 1 }
                model.receive(source: source, audioStart: start, audioEnd: end, isFinal: result.isFinal)
                recorder.capture(model, reason: "actual ASR event")
            }
        }
        let analysis = Task {
            if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
        }
        do {
            let chunk = AVAudioFrameCount(max(1, file.processingFormat.sampleRate / 10))
            while file.framePosition < file.length {
                guard model.phase == .listening else { throw Failure("Model stopped during file input: \(model.message ?? "unknown")") }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw Failure("Audio buffer allocation failed.") }
                try file.read(into: buffer, frameCount: chunk)
                let wait = Double(file.framePosition) / file.processingFormat.sampleRate - (ProcessInfo.processInfo.systemUptime - began)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let invocation = FileTapInvocation(pump: pump, buffer: buffer)
                await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async { invocation.invoke(); done.resume() }
                }
            }
            await pump.finish()
            try await OperationDeadline.run(seconds: 20, name: "file ASR finalization", onTimeout: {
                Task { await analyzer.cancelAndFinishNow() }
            }) { try await analysis.value; try await results.value }
            let asrFinished = ProcessInfo.processInfo.systemUptime - began
            await model.stop()
            for _ in 0..<100 where calls.activeAppleCount > 0 || calls.activeLocalCount > 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            observer.cancel(); await observer.value
            recorder.capture(model, reason: "production stop drained")
            var failures = recorder.failures
            if finalized.isEmpty || provisional == 0 { failures.append("No final or provisional actual ASR results.") }
            if normalized(finalized.joined(separator: " ")) != normalized(model.segments.map(\.source).joined(separator: " ")) {
                failures.append("Production timeline did not retain actual final ASR text exactly.")
            }
            if model.selectedDirection != direction || model.selectedDictionaryIDs != selectedDictionaryIDs {
                failures.append("Explicit direction/dictionary selection changed.")
            }
            if model.segments.contains(where: { !$0.isFinal }) { failures.append("A final source remains untranslated/incomplete.") }
            if model.hasPendingTranslations || model.queuedTranslations != 0 || model.phase != .idle { failures.append("Stop left pending lifecycle work.") }
            if pump.droppedBufferCount != 0 || !problems.all.isEmpty { failures.append("Audio input was dropped or reported errors.") }
            if calls.activeAppleCount != 0 || TranslationSessionLease.activeLiveCount != 0 || TranslationSessionLease.activeContextCount != 0 {
                failures.append("Actual Apple native awaits remained after stop.")
            }
            if calls.activeLocalCount != 0 { failures.append("Actual local inference calls remained after stop.") }
            if !comparison && (calls.local.filter({ $0["status"] as? String == "completed" }).isEmpty || recorder.localFinalObservations == 0) {
                failures.append("No completed HY translation was applied to an exact-current final source.")
            }
            if calls.local.contains(where: { ($0["previous_sentence"] as? String ?? "").isEmpty == false }) {
                failures.append("Production passed a separate previous-sentence background prompt.")
            }
            if calls.local.contains(where: { $0["direction"] as? String != direction.rawValue ||
                Set($0["dictionary_ids"] as? [String] ?? []) != selectedDictionaryIDs }) {
                failures.append("Actual local request did not use the explicitly selected direction/dictionaries.")
            }
            var observedKeys: Set<String> = []
            let exact = recorder.observations.filter {
                guard $0["source_revision"] as? Int == $0["translated_revision"] as? Int,
                    $0["context_is_pending"] as? Bool == false, $0["matching_completed_engine"] as? String != nil else { return false }
                let key = [String(describing: $0["id"]!), String(describing: $0["source_revision"]!),
                    String(describing: $0["context_segment_count"]!), String(describing: $0["source"]!),
                    String(describing: $0["target"]!)].joined(separator: "|")
                // An old caption re-observed when another row changes is not a
                // new latency sample. Keep its first exact-current observation.
                return observedKeys.insert(key).inserted
            }
            var observedLocalKeys: Set<String> = []
            let finalLocal = recorder.observations.filter {
                guard $0["source_revision"] as? Int == $0["translated_revision"] as? Int,
                    $0["context_is_pending"] as? Bool == false, $0["is_visual_final"] as? Bool == true,
                    $0["matching_completed_engine"] as? String == "HY-MT2" else { return false }
                let key = [String(describing: $0["id"]!), String(describing: $0["source_revision"]!),
                    String(describing: $0["context_segment_count"]!), String(describing: $0["source"]!),
                    String(describing: $0["target"]!)].joined(separator: "|")
                // Finalization has its own first-observation clock even when
                // HY produces exactly the same readable text as an Apple draft.
                return observedLocalKeys.insert(key).inserted
            }
            let delays = exact.compactMap { $0["after_corresponding_file_audio_end_seconds"] as? Double }.sorted()
            let median: Any = delays.isEmpty ? NSNull() : (delays[(delays.count - 1) / 2] + delays[delays.count / 2]) / 2
            let localDelays = finalLocal.compactMap { $0["after_corresponding_file_audio_end_seconds"] as? Double }.sorted()
            let localMedian: Any = localDelays.isEmpty ? NSNull() : (localDelays[(localDelays.count - 1) / 2] + localDelays[localDelays.count / 2]) / 2
            func firstExactObservations(where predicate: ([String: Any]) -> Bool) -> [[String: Any]] {
                var keys: Set<String> = []
                return recorder.observations.filter {
                    guard $0["source_revision"] as? Int == $0["translated_revision"] as? Int,
                        $0["context_is_pending"] as? Bool == false,
                        $0["matching_completed_engine"] as? String != nil, predicate($0) else { return false }
                    let key = [String(describing: $0["id"]!), String(describing: $0["source_revision"]!),
                        String(describing: $0["context_segment_count"]!), String(describing: $0["source"]!),
                        String(describing: $0["target"]!)].joined(separator: "|")
                    return keys.insert(key).inserted
                }
            }
            let appleCaptions = firstExactObservations {
                $0["context_segment_count"] as? Int == 1 &&
                    ($0["matching_completed_engines"] as? [String] ?? []).contains("Apple")
            }
            let allFinalCaptions = firstExactObservations { $0["is_visual_final"] as? Bool == true }
            let appleDelays = appleCaptions.compactMap { $0["after_corresponding_file_audio_end_seconds"] as? Double }.sorted()
            let appleMedian: Any = appleDelays.isEmpty ? NSNull() : (appleDelays[(appleDelays.count - 1) / 2] + appleDelays[appleDelays.count / 2]) / 2
            let finalDelays = allFinalCaptions.compactMap { $0["after_corresponding_file_audio_end_seconds"] as? Double }.sorted()
            let finalMedian: Any = finalDelays.isEmpty ? NSNull() : (finalDelays[(finalDelays.count - 1) / 2] + finalDelays[finalDelays.count / 2]) / 2
            let metrics: [String: Any] = ["provisional_asr_events": provisional, "final_asr_events": finalized.count,
                    "maximum_queue": recorder.maximumQueue, "gray_observations": recorder.grayObservations,
                    "context_pending_observations": recorder.contextObservations, "exact_current_hy_final_observations": recorder.localFinalObservations,
                    "first_caption": recorder.observations.first ?? [:], "first_exact_current_caption": exact.first ?? [:],
                    "first_exact_current_hy_final_caption": finalLocal.first ?? [:],
                    "exact_current_caption_after_file_audio_end_median_seconds": median,
                    "exact_current_caption_after_file_audio_end_max_seconds": delays.last.map { $0 as Any } ?? NSNull(),
                    "delay_sample_count": delays.count, "state_polling_ms": 20, "input_chunk_ms": 100,
                    "latency_sample_filter": "First observation per segment ID/source revision/source/target/context membership; exact translated revision, no pending context, matching completed Apple or HY call. Includes provisional source results; final HY samples are separate.",
                    "exact_current_hy_final_after_file_audio_end_median_seconds": localMedian,
                    "exact_current_hy_final_after_file_audio_end_max_seconds": localDelays.last.map { $0 as Any } ?? NSNull(),
                    "hy_final_delay_sample_count": localDelays.count,
                    "first_exact_current_apple_caption": appleCaptions.first ?? [:],
                    "exact_current_apple_caption_after_file_audio_end_median_seconds": appleMedian,
                    "exact_current_apple_caption_after_file_audio_end_max_seconds": appleDelays.last.map { $0 as Any } ?? NSNull(),
                    "apple_caption_delay_sample_count": appleDelays.count,
                    "exact_current_any_final_after_file_audio_end_median_seconds": finalMedian,
                    "exact_current_any_final_after_file_audio_end_max_seconds": finalDelays.last.map { $0 as Any } ?? NSNull(),
                    "any_final_delay_sample_count": finalDelays.count,
                    "hy_attempt_count": calls.local.count,
                    "hy_completed_count": calls.local.filter { $0["status"] as? String == "completed" }.count,
                    "hy_failed_count": calls.local.filter { $0["status"] as? String == "failed" }.count,
                    "hy_cancelled_count": calls.local.filter { $0["status"] as? String == "cancelled" }.count,
                    "hy_guard_rejected_count": calls.local.filter { $0["guard_accepted"] as? Bool == false }.count,
                    "separate_delay_filter": "First exact-current Apple-matching single caption, any final caption, and HY final caption per segment/revision/text/context membership. Identical Apple/HY text may match both engines; polling excludes UI rendering.",
                    "asr_finished_after_stream_seconds": asrFinished, "stop_drained_after_stream_seconds": ProcessInfo.processInfo.systemUptime - began,
                    "dropped_audio_buffers": pump.droppedBufferCount, "active_apple_after_stop": calls.activeAppleCount,
                    "active_local_inference_calls_after_stop": calls.activeLocalCount,
                    "physical_live_awaits_after_stop": TranslationSessionLease.activeLiveCount,
                    "physical_context_awaits_after_stop": TranslationSessionLease.activeContextCount]
            return ["fixture": fixture.id, "passed": failures.isEmpty, "failures": failures,
                "direction": direction.rawValue, "source_language": direction.sourceLanguageCode, "target_language": direction.targetLanguageCode,
                "domain": domain.rawValue, "dictionary_ids": selectedDictionaryIDs.sorted(),
                "voice": fixture.voice, "authored_public_text": fixture.text, "semantic_review_hint": fixture.meaning,
                "audio_fixture_seconds": duration, "asr_events": events, "final_asr_sources": finalized,
                "final_source_segments": model.segments.map(recorder.row), "final_display_segments": model.displaySegments.map(recorder.row),
                "apple_calls": calls.apple, "hy_calls": calls.local, "observations": recorder.observations, "state_snapshots": recorder.snapshots,
                "production_message": model.message.map { $0 as Any } ?? NSNull(), "metrics": metrics]
        } catch {
            observer.cancel(); results.cancel(); analysis.cancel(); calls.cancelAll()
            await pump.finish(); await analyzer.cancelAndFinishNow(); await model.stop(aborting: true)
            throw error
        }
    }
}
