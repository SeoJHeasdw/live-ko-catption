@preconcurrency import AVFoundation
import CaptionCore
import CoreMedia
import Foundation
import Speech
@preconcurrency import Translation

private final class PumpProblems: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { values.append(value) } }
    var messages: [String] { lock.withLock { values } }
}

/// Reproduces the production tap's foreign-queue invocation with an explicitly
/// supplied audio file. This executable never opens an audio device.
private final class FileTapInvocation: @unchecked Sendable {
    private let block: AVAudioNodeTapBlock
    private let buffer: AVAudioPCMBuffer
    init(pump: AudioPump, buffer: AVAudioPCMBuffer) {
        self.block = pump.makeTapBlock()
        self.buffer = buffer
    }
    func invoke() {
        block(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate))
    }
}

/// TranslationSession.cancel() is synchronous and has no actor annotation in
/// the SDK. The holder crosses only the cancellation handler's Sendable boundary.
private final class SessionCancellation: @unchecked Sendable {
    let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }
    func cancel() { session.cancel() }
}

@MainActor private final class ActualTranslator {
    private(set) var calls: [[String: Any]] = []
    private var active: [UUID: SessionCancellation] = [:]
    var activeCount: Int { active.count }
    var streamBegan: Double = 0

    func translate(_ source: String, isContext: Bool) async throws -> String {
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "ko"), preferredStrategy: isContext ? .highFidelity : .lowLatency)
        let cancellation = SessionCancellation(session)
        let id = UUID()
        let index = calls.count
        let began = ProcessInfo.processInfo.systemUptime
        calls.append(["id": id.uuidString, "english": source, "is_context": isContext,
                      "requested_strategy": isContext ? "highFidelity" : "lowLatency",
                      "started_after_stream_seconds": began - streamBegan, "status": "in_flight"])
        active[id] = cancellation
        defer {
            cancellation.cancel()
            active.removeValue(forKey: id)
            calls[index]["text_translation_seconds"] = ProcessInfo.processInfo.systemUptime - began
        }
        do {
            let target = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let result = try await session.translate(source)
                try Task.checkCancellation()
                return result.targetText
            } onCancel: { cancellation.cancel() }
            calls[index]["status"] = "completed"
            calls[index]["korean"] = target
            return target
        } catch {
            calls[index]["status"] = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            calls[index]["error"] = error.localizedDescription
            throw error
        }
    }

    func hasResponse(source: String, target: String) -> Bool {
        calls.contains { $0["status"] as? String == "completed" &&
            $0["english"] as? String == source && $0["korean"] as? String == target }
    }

    func cancelAll() { for session in active.values { session.cancel() } }
}

@MainActor private final class ObservationRecorder {
    let began: Double
    let translator: ActualTranslator
    private var previousRaw: [CaptionSegment] = []
    private var previousDisplay: [CaptionSegment] = []
    private var previousQueued = -1
    private var previousPending = false
    private var previouslyObservedText: [UUID: String] = [:]
    private var previouslyFinalTargets: [UUID: Set<String>] = [:]
    private var pendingSinceText: Set<UUID> = []
    private(set) var snapshots: [[String: Any]] = []
    private(set) var koreanUpdates: [[String: Any]] = []
    private(set) var finalTextChanges: [[String: Any]] = []
    private(set) var failures: [String] = []
    private(set) var droppedSnapshots = 0
    private(set) var maximumQueue = 0
    private(set) var grayKoreanObservations = 0
    private(set) var contextPendingObservations = 0
    private(set) var finalToGrayTransitions = 0
    private(set) var firstKorean: [String: Any]?
    private(set) var firstCurrentKorean: [String: Any]?

    init(began: Double, translator: ActualTranslator) { self.began = began; self.translator = translator }

    func capture(_ model: CaptionModel, reason: String) {
        let raw = model.segments
        let display = model.displaySegments
        maximumQueue = max(maximumQueue, model.queuedTranslations)
        guard raw != previousRaw || display != previousDisplay || previousQueued != model.queuedTranslations ||
              previousPending != model.hasPendingTranslations else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        for segment in raw {
            if segment.isFinal && (!segment.sourceIsFinal || segment.translatedRevision != segment.revision ||
                segment.translationError != nil || segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
                fail("Raw caption marked final without an exact translated final source: \(segment.id)")
            }
            if segment.translatedRevision == segment.revision, let target = segment.translation,
               !translator.hasResponse(source: segment.source, target: target) {
                fail("Raw translation does not match a completed actual call for its exact source: \(segment.id)")
            }
        }
        var rows: [[String: Any]] = []
        for segment in display {
            if let previous = previousDisplay.first(where: { $0.id == segment.id }),
               previous.isFinal && !segment.isFinal { finalToGrayTransitions += 1 }
            if segment.isFinal && (segment.contextIsPending || !segment.sourceIsFinal ||
                segment.translatedRevision != segment.revision || segment.translationError != nil) {
                fail("Displayed final caption violates its revision/pending invariant: \(segment.id)")
            }
            if segment.contextSegmentCount > 1 {
                if let first = raw.firstIndex(where: { $0.id == segment.id }) {
                    let members = Array(raw.dropFirst(first).prefix(segment.contextSegmentCount))
                    if members.count != segment.contextSegmentCount || !members.allSatisfy(\.sourceIsFinal) ||
                        normalize(members.map(\.source).joined(separator: " ")) != normalize(segment.source) {
                        fail("Aggregate caption changed or lost its underlying ASR sources: \(segment.id)")
                    }
                } else { fail("Aggregate caption has no underlying ASR row") }
            }
            if segment.isFinal, let target = segment.translation,
               !translator.hasResponse(source: segment.source, target: target) {
                fail("Displayed final translation has no completed actual call for its exact aggregate source: \(segment.id)")
            }
            if segment.contextIsPending {
                contextPendingObservations += 1
                pendingSinceText.insert(segment.id)
            }
            if let target = segment.translation, !target.isEmpty {
                if !segment.isFinal { grayKoreanObservations += 1 }
                let observation: [String: Any] = [
                    "observed_after_stream_seconds": elapsed,
                    "after_corresponding_audio_end_seconds": elapsed - segment.audioEnd,
                    "audio_end_seconds": segment.audioEnd, "english": segment.source, "korean": target,
                    "source_revision": segment.revision,
                    "translated_revision": segment.translatedRevision.map { $0 as Any } ?? NSNull(),
                    "is_visual_final": segment.isFinal, "context_is_pending": segment.contextIsPending,
                    "context_segment_count": segment.contextSegmentCount
                ]
                if firstKorean == nil { firstKorean = observation }
                if firstCurrentKorean == nil, segment.translatedRevision == segment.revision,
                   !segment.contextIsPending, translator.hasResponse(source: segment.source, target: target) {
                    firstCurrentKorean = observation
                }
                let key = "\(segment.revision)|\(segment.contextSegmentCount)|\(segment.source)|\(target)"
                if previouslyObservedText[segment.id] != key {
                    koreanUpdates.append(observation)
                    if let previous = previousDisplay.first(where: { $0.id == segment.id }),
                       previous.translation != target, previous.sourceIsFinal {
                        finalTextChanges.append([
                            "observed_after_stream_seconds": elapsed, "previous_korean": previous.translation ?? "",
                            "current_korean": target, "english": segment.source,
                            "pending_gray_observed_before_change": pendingSinceText.contains(segment.id),
                            "previous_translation_previously_visual_final": previouslyFinalTargets[segment.id]?.contains(previous.translation ?? "") ?? false
                        ])
                    }
                    previouslyObservedText[segment.id] = key
                    pendingSinceText.remove(segment.id)
                }
                if segment.isFinal { previouslyFinalTargets[segment.id, default: []].insert(target) }
            }
            rows.append(row(segment))
        }
        if snapshots.count < 10_000 {
            snapshots.append(["observed_after_stream_seconds": elapsed, "trigger": reason,
                              "queued_translations": model.queuedTranslations,
                              "has_pending_translations": model.hasPendingTranslations, "rows": rows])
        } else { droppedSnapshots += 1 }
        previousRaw = raw; previousDisplay = display
        previousQueued = model.queuedTranslations; previousPending = model.hasPendingTranslations
    }

    private func fail(_ value: String) { if !failures.contains(value) { failures.append(value) } }

    func row(_ segment: CaptionSegment) -> [String: Any] {
        ["id": segment.id.uuidString, "source_revision": segment.revision,
         "translated_revision": segment.translatedRevision.map { $0 as Any } ?? NSNull(),
         "english": segment.source, "korean": segment.translation.map { $0 as Any } ?? NSNull(),
         "source_is_final": segment.sourceIsFinal, "is_visual_final": segment.isFinal,
         "context_is_pending": segment.contextIsPending, "context_segment_count": segment.contextSegmentCount,
         "translation_error": segment.translationError.map { $0 as Any } ?? NSNull(),
         "audio_start_seconds": segment.audioStart, "audio_end_seconds": segment.audioEnd]
    }

    private func normalize(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

@main @MainActor
struct RealtimePipelineChecks {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard !arguments.isEmpty, arguments.count == 1 ||
                    (arguments.count == 3 && arguments[1] == "--output") else {
                throw Failure("Usage: RealtimePipelineChecks /absolute/path/to/english-audio.aiff [--output /path/to/report.json]")
            }
            let report = try await run(filePath: arguments[0])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if arguments.count == 3 { try data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic) }
            print(String(decoding: data, as: UTF8.self))
            guard report["passed"] as? Bool == true else { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(filePath: String) async throws -> [String: Any] {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let reserved = await AssetInventory.reservedLocales
        let wasReserved = reserved.contains { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }
        let ownsReservation = wasReserved ? false : try await AssetInventory.reserve(locale: locale)
        do {
            let speechStatus = await AssetInventory.status(forModules: [transcriber])
            let lowStatus = await LanguageAvailability(preferredStrategy: .lowLatency)
                .status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
            let highStatus = await LanguageAvailability(preferredStrategy: .highFidelity)
                .status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
            guard speechStatus == .installed, lowStatus == .installed, highStatus == .installed else {
                throw Failure("SETUP_REQUIRED: speech=\(speechStatus), lowLatency=\(lowStatus), highFidelity=\(highStatus). Prepare local languages in the app first; this check never downloads assets.")
            }
            guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw Failure("No local speech analyzer input format is available")
            }
            let report = try await stream(filePath: filePath, transcriber: transcriber, target: target)
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            return report
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private static func stream(filePath: String, transcriber: SpeechTranscriber, target: AVAudioFormat) async throws -> [String: Any] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: filePath))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw Failure("The fixture must contain audio") }
        let problems = PumpProblems()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let pump = try AudioPump(source: file.processingFormat, target: target, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { problems.record($0) })
        let analyzer = SpeechAnalyzer(modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        try await analyzer.prepareToAnalyze(in: target)
        let translator = ActualTranslator()
        let model = CaptionModel(translationOverride: { text, context in
            try await translator.translate(text, isContext: context)
        })
        // Do not alter the user's persisted preference during a test.
        let savedContextPreference = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        model.contextCorrectionEnabled = true
        if let savedContextPreference { UserDefaults.standard.set(savedContextPreference, forKey: "contextCorrectionEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled") }
        model.phase = .listening
        model.isChecking = false
        let began = ProcessInfo.processInfo.systemUptime
        translator.streamBegan = began
        let recorder = ObservationRecorder(began: began, translator: translator)
        var asrEvents: [[String: Any]] = []
        var finalizedSources: [String] = []
        var provisionalCount = 0
        var firstASR: Double?
        let observer = Task {
            while !Task.isCancelled {
                recorder.capture(model, reason: "20ms state observation")
                do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
            }
        }
        let results = Task {
            for try await result in transcriber.results {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                let source = String(result.text.characters)
                if firstASR == nil { firstASR = elapsed }
                asrEvents.append(["arrived_after_stream_seconds": elapsed, "audio_start_seconds": start,
                                  "audio_end_seconds": end, "english": source, "is_final": result.isFinal])
                if result.isFinal { finalizedSources.append(source.trimmingCharacters(in: .whitespacesAndNewlines)) }
                else { provisionalCount += 1 }
                model.receive(source: source, audioStart: start, audioEnd: end, isFinal: result.isFinal)
                recorder.capture(model, reason: "actual ASR event")
            }
        }
        let analysis = Task {
            if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
        }
        do {
            let chunkFrames = AVAudioFrameCount(max(1, file.processingFormat.sampleRate / 10))
            while file.framePosition < file.length {
                guard model.phase == .listening else { throw Failure("Production model stopped during fixture input: \(model.message ?? "unknown reason")") }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                    throw Failure("Could not allocate an audio fixture chunk")
                }
                try file.read(into: buffer, frameCount: chunkFrames)
                // Deliver each chunk at its audio end, avoiding artificial
                // negative latency caused by feeding future audio immediately.
                let due = Double(file.framePosition) / file.processingFormat.sampleRate
                let wait = due - (ProcessInfo.processInfo.systemUptime - began)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let invocation = FileTapInvocation(pump: pump, buffer: buffer)
                await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async { invocation.invoke(); done.resume() }
                }
            }
            await pump.finish()
            try await OperationDeadline.run(seconds: 15, name: "fixture ASR finish", onTimeout: {
                Task { await analyzer.cancelAndFinishNow() }
            }) { try await analysis.value; try await results.value }
            let inputFinished = ProcessInfo.processInfo.systemUptime - began
            await model.stop()
            for _ in 0..<100 where translator.activeCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
            observer.cancel(); await observer.value
            recorder.capture(model, reason: "production stop drained")
            let normalize: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let contextCalls = translator.calls.filter { $0["is_context"] as? Bool == true }
            let hasEligibleContext = zip(model.segments, model.segments.dropFirst()).contains { previous, next in
                previous.isFinal && next.isFinal && next.audioStart - previous.audioEnd <= 2 &&
                    next.audioEnd - previous.audioStart <= 12 &&
                    (previous.source + " " + next.source).count <= 500
            }
            var failures = recorder.failures
            if finalizedSources.isEmpty { failures.append("No final speech text was recognized") }
            if provisionalCount == 0 { failures.append("No provisional ASR events were observed") }
            if normalize(finalizedSources.joined(separator: " ")) != normalize(model.segments.map(\.source).joined(separator: " ")) {
                failures.append("Production timeline did not retain every actual final ASR source exactly")
            }
            if model.segments.contains(where: { !$0.isFinal }) { failures.append("At stop, some exact final source revisions were untranslated or had errors") }
            if model.hasPendingTranslations || model.queuedTranslations != 0 || model.phase != .idle {
                failures.append("Production stop left pending translations or a non-idle lifecycle")
            }
            if !problems.messages.isEmpty || pump.droppedBufferCount != 0 { failures.append("Fixture input dropped audio or reported an audio error") }
            if translator.activeCount != 0 { failures.append("Actual local translation calls remained active after production stop") }
            if recorder.firstKorean == nil { failures.append("No Korean translation was observed") }
            if hasEligibleContext && (!contextCalls.contains(where: { $0["status"] as? String == "completed" }) ||
                !model.displaySegments.contains(where: { $0.contextSegmentCount > 1 })) {
                failures.append("Eligible adjacent final sources did not produce an actual completed context translation and aggregate caption")
            }
            let delays = recorder.koreanUpdates.compactMap { row -> Double? in
                guard row["source_revision"] as? Int == row["translated_revision"] as? Int,
                      row["context_is_pending"] as? Bool == false,
                      let source = row["english"] as? String, let target = row["korean"] as? String,
                      translator.hasResponse(source: source, target: target) else { return nil }
                return row["after_corresponding_audio_end_seconds"] as? Double
            }.sorted()
            let delayMedian: Any = delays.isEmpty ? NSNull()
                : (delays[(delays.count - 1) / 2] + delays[delays.count / 2]) / 2
            return [
                "mode": "paced audio file → actual local ASR → production CaptionModel scheduler → actual local Korean translation",
                "passed": failures.isEmpty, "failures": failures,
                "recorded_at": ISO8601DateFormatter().string(from: Date()),
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "audio_fixture_filename": file.url.lastPathComponent, "fixture_seconds": duration,
                "audio_chunk_milliseconds": 100, "state_observation_resolution_milliseconds": 20,
                "limitations": ["No microphone was opened. Fixture-stream timing excludes microphone hardware and is not microphone latency.",
                                "Timing captures model state at 20ms intervals and does not include SwiftUI drawing.",
                                "A translation matching an exact source revision can still be semantically wrong.",
                                "Requested highFidelity may use Apple's documented traditional-model fallback.",
                                "Model start/permission/device selection was bypassed; production receive, queues, context correction and stop were exercised.",
                                "The injected real translator creates a cancellable installed-language session per call; the app normally reuses its lowLatency session.",
                                "This check does not verify network-disabled operation or real-speaker accuracy."],
                "metrics": [
                    "first_english_after_stream_seconds": firstASR.map { $0 as Any } ?? NSNull(),
                    "first_korean_observation": recorder.firstKorean ?? [:],
                    "first_exact_current_revision_korean_observation": recorder.firstCurrentKorean ?? [:],
                    "current_revision_korean_delay_median_seconds": delayMedian,
                    "current_revision_korean_delay_max_seconds": delays.last.map { $0 as Any } ?? NSNull(),
                    "current_revision_korean_delay_sample_count": delays.count,
                    "latency_sample_filter": "only translatedRevision == revision, contextIsPending == false, and a matching completed actual source/target call",
                    "stale_korean_updates": recorder.koreanUpdates.filter { $0["source_revision"] as? Int != $0["translated_revision"] as? Int }.count,
                    "pending_context_korean_updates": recorder.koreanUpdates.filter { $0["context_is_pending"] as? Bool == true }.count,
                    "input_and_asr_finished_after_stream_seconds": inputFinished,
                    "production_stop_drained_after_stream_seconds": ProcessInfo.processInfo.systemUptime - began,
                    "provisional_asr_events": provisionalCount, "final_asr_segments": finalizedSources.count,
                    "maximum_queued_translations_observed": recorder.maximumQueue,
                    "gray_korean_observations": recorder.grayKoreanObservations,
                    "context_pending_observations": recorder.contextPendingObservations,
                    "visual_final_to_gray_transitions": recorder.finalToGrayTransitions,
                    "context_translation_calls": contextCalls.count,
                    "fixture_has_eligible_adjacent_context": hasEligibleContext,
                    "completed_context_calls": contextCalls.filter { $0["status"] as? String == "completed" }.count,
                    "final_context_groups": model.displaySegments.filter { $0.contextSegmentCount > 1 }.count,
                    "dropped_audio_buffers": pump.droppedBufferCount,
                    "active_local_translation_calls_after_stop": translator.activeCount,
                    "has_pending_translations_after_stop": model.hasPendingTranslations,
                    "dropped_state_snapshots": recorder.droppedSnapshots
                ],
                "production_message": model.message.map { $0 as Any } ?? NSNull(),
                "final_asr_sources": finalizedSources,
                "final_source_segments": model.segments.map(recorder.row),
                "final_display_segments": model.displaySegments.map(recorder.row),
                "translation_calls": translator.calls, "korean_updates": recorder.koreanUpdates,
                "completed_source_korean_changes": recorder.finalTextChanges,
                "asr_events": asrEvents, "state_snapshots": recorder.snapshots
            ]
        } catch {
            results.cancel(); analysis.cancel(); observer.cancel()
            translator.cancelAll()
            await pump.finish()
            await analyzer.cancelAndFinishNow()
            await model.stop(aborting: true)
            throw error
        }
    }

    private struct Failure: LocalizedError {
        let value: String
        init(_ value: String) { self.value = value }
        var errorDescription: String? { value }
    }
}
