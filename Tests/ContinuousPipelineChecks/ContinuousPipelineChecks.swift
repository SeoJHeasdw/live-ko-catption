@preconcurrency import AVFoundation
import CaptionCore
import CoreMedia
import Darwin
import Foundation
import Speech
@preconcurrency import Translation

private final class InputProblems: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.withLock { if values.count < 64 { values.append(value) } } }
    var messages: [String] { lock.withLock { values } }
}
private final class ForeignTap: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    init(pump: AudioPump, buffer: AVAudioPCMBuffer) { block = pump.makeTapBlock(); self.buffer = buffer }
    func invoke() { block(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)) }
}
private final class SessionCancellation: @unchecked Sendable {
    let session: TranslationSessionLease
    private let lock = NSLock()
    private var invalidated = false
    init(_ session: TranslationSessionLease) { self.session = session }
    var isCanceled: Bool { lock.withLock { invalidated } }
    func cancel() {
        let first = lock.withLock { if invalidated { return false }; invalidated = true; return true }
        // Invalidate reuse synchronously across the cancellation boundary;
        // physical SDK cleanup is delegated to the production lease on its actor.
        if first { Task { @MainActor in session.retire() } }
    }
}

/// A canceled framework session is discarded; completed live requests reuse the
/// same installed-language session, matching the app's normal low-latency path.
@MainActor private final class LocalTranslator {
    private var live: SessionCancellation?
    private var context: SessionCancellation?
    private var completed: Set<String> = []
    private struct ActiveCall {
        let source: String
        let context: Bool
        let began: Double
        let holder: SessionCancellation
    }
    private var activeCalls: [UUID: ActiveCall] = [:]
    private(set) var calls = 0
    private(set) var contextCalls = 0
    private(set) var completedCalls = 0
    private(set) var canceledCalls = 0
    private(set) var failedCalls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var maximumSeconds = 0.0
    private(set) var examples: [[String: Any]] = []
    private(set) var errors: [[String: Any]] = []

    func translate(_ source: String, isContext: Bool) async throws -> String {
        let cancellation: SessionCancellation
        if isContext {
            // Production creates and retires a high-fidelity lease for each
            // passage. Successful live-caption calls continue to reuse low latency.
            cancellation = makeSession(context: true)
            context = cancellation
        } else {
            if live == nil || live!.isCanceled { live = makeSession(context: false) }
            cancellation = live!
        }
        let session = cancellation.session
        calls += 1
        if isContext { contextCalls += 1 }
        active += 1; maximumActive = max(maximumActive, active)
        let began = ProcessInfo.processInfo.systemUptime
        let callID = UUID()
        activeCalls[callID] = ActiveCall(source: source, context: isContext, began: began, holder: cancellation)
        defer {
            if isContext {
                cancellation.session.retire()
                if context === cancellation { context = nil }
            }
            activeCalls.removeValue(forKey: callID)
            active -= 1
            maximumSeconds = max(maximumSeconds, ProcessInfo.processInfo.systemUptime - began)
        }
        do {
            let text = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let response = try await session.translate(source)
                try Task.checkCancellation()
                return response
            } onCancel: { cancellation.cancel() }
            completedCalls += 1
            completed.insert(key(source, text))
            if examples.count < 24 { examples.append(["english": source, "korean": text, "context": isContext]) }
            return text
        } catch {
            cancellation.cancel()
            // The previous request may finish cancellation after a new request
            // has installed a replacement. Never clear the new session here.
            if isContext { if context === cancellation { context = nil } }
            else { if live === cancellation { live = nil } }
            if Task.isCancelled || error is CancellationError { canceledCalls += 1 } else {
                failedCalls += 1
                if errors.count < 16 { errors.append(["english": source, "context": isContext, "error": error.localizedDescription]) }
            }
            throw error
        }
    }
    func matches(_ source: String, _ target: String) -> Bool { completed.contains(key(source, target)) }
    func cancel() { live?.cancel(); context?.cancel(); live = nil; context = nil }
    private func key(_ source: String, _ target: String) -> String { source + "\u{0}" + target }
    private func makeSession(context: Bool) -> SessionCancellation {
        SessionCancellation(TranslationSessionLease(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ko"),
                           preferredStrategy: context ? .highFidelity : .lowLatency))
    }
    var metrics: [String: Any] {
        ["calls": calls, "context_calls": contextCalls, "completed_calls": completedCalls,
         "canceled_calls": canceledCalls, "failed_calls": failedCalls,
         "errors": errors, "active_calls": active,
         "physical_live_awaits": TranslationSessionLease.activeLiveCount,
         "physical_context_awaits": TranslationSessionLease.activeContextCount,
         "active_call_details": activeCalls.map { id, call in
            ["id": id.uuidString, "english": call.source, "context": call.context,
             "age_seconds": ProcessInfo.processInfo.systemUptime - call.began,
             "reuse_invalidated": call.holder.isCanceled,
             "lease_is_retired": call.holder.session.isRetired,
             "physical_native_awaits": call.holder.session.activeNativeCount] as [String: Any]
         },
         "maximum_active_calls": maximumActive, "maximum_call_seconds": maximumSeconds]
    }
}

private func memoryMB() -> Double {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}
private func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
private func percentile(_ values: [Double], _ fraction: Double) -> Any {
    guard !values.isEmpty else { return NSNull() }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}
private func normalize(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

@MainActor private final class Recorder {
    let began = ProcessInfo.processInfo.systemUptime
    let translator: LocalTranslator
    let reportPath: String?
    private var lastTick: Double
    private var lastCPU: Double
    private var lastSeries = -5.0
    private var lastProgress = -30.0
    private var observed: [UUID: String] = [:]
    private var previousVisualFinal: [UUID: Bool] = [:]
    private(set) var finalSources: [String] = []
    private(set) var series: [[String: Any]] = []
    private(set) var lag: [Double] = []
    private(set) var asrLag: [Double] = []
    private(set) var failures: [String] = []
    private(set) var maximumQueue = 0
    private(set) var provisionalASR = 0
    private(set) var grayObservations = 0
    private(set) var finalToGray = 0
    private(set) var maximumTickGap = 0.0
    private(set) var maximumRSS = 0.0
    private(set) var lastASR = 0.0
    private(set) var maximumASRGap = 0.0
    private(set) var passes: [[String: Any]] = []
    var inputSeconds = 0.0
    var passIndex = 0

    init(translator: LocalTranslator, reportPath: String?) {
        self.translator = translator; self.reportPath = reportPath
        lastTick = began; lastCPU = cpuSeconds()
    }
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - began }
    func fail(_ value: String) { if failures.count < 100, !failures.contains(value) { failures.append(value) } }
    func receive(_ result: SpeechTranscriber.Result, offset: Double, model: CaptionModel) {
        let start = CMTimeGetSeconds(result.range.start) + offset
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)) + offset
        let source = String(result.text.characters)
        let now = elapsed
        if lastASR > 0 { maximumASRGap = max(maximumASRGap, now - lastASR) }
        lastASR = now
        if asrLag.count < 30_000 { asrLag.append(now - end) }
        if result.isFinal { finalSources.append(normalize(source)) } else { provisionalASR += 1 }
        model.receive(source: source, audioStart: start, audioEnd: end, isFinal: result.isFinal)
    }
    func tick(_ model: CaptionModel) {
        let now = ProcessInfo.processInfo.systemUptime
        maximumTickGap = max(maximumTickGap, now - lastTick); lastTick = now
        maximumQueue = max(maximumQueue, model.queuedTranslations)
        // Copy-on-write tail reads only. Full history is audited once at stop,
        // preventing the observer itself from causing quadratic memory growth.
        for segment in model.segments.suffix(24) {
            if segment.isFinal && (!segment.sourceIsFinal || segment.translatedRevision != segment.revision || segment.translationError != nil) {
                fail("Raw final caption violated exact source revision invariant")
            }
            if segment.translatedRevision == segment.revision, let target = segment.translation,
               !translator.matches(segment.source, target) { fail("Raw translation had no completed real exact-source response") }
            if let target = segment.translation {
                if !segment.isFinal { grayObservations += 1 }
                let key = "\(segment.revision)|\(segment.translatedRevision ?? -1)|\(target)"
                if observed[segment.id] != key {
                    observed[segment.id] = key
                    if segment.translatedRevision == segment.revision, translator.matches(segment.source, target), lag.count < 30_000 {
                        lag.append(elapsed - segment.audioEnd)
                    }
                }
            }
        }
        if elapsed - lastSeries >= 5 {
            let cpu = cpuSeconds()
            let rss = memoryMB()
            let interval = max(0.001, elapsed - lastSeries)
            maximumRSS = max(maximumRSS, rss)
            var finalTail = 0
            for segment in model.recentDisplaySegments(limit: 24) {
                if previousVisualFinal[segment.id] == true, !segment.isFinal { finalToGray += 1 }
                previousVisualFinal[segment.id] = segment.isFinal
                if segment.isFinal { finalTail += 1 }
                if segment.isFinal && (segment.contextIsPending || !segment.sourceIsFinal || segment.translatedRevision != segment.revision) {
                    fail("Displayed final caption violated revision/context invariant")
                }
                if segment.isFinal, let target = segment.translation, !translator.matches(segment.source, target) {
                    fail("Displayed final Korean had no completed actual exact aggregate response")
                }
            }
            if series.count < 800 {
                series.append(["elapsed_seconds": elapsed, "audio_input_seconds": inputSeconds, "pass": passIndex,
                    "rss_mb": rss, "cpu_percent_of_one_core": max(0, (cpu - lastCPU) / interval * 100),
                    "caption_count": model.segments.count, "queue_count": model.queuedTranslations,
                    "translation_calls": translator.calls, "last_asr_seconds_ago": lastASR > 0 ? elapsed - lastASR : elapsed,
                    "visual_final_tail_count": finalTail, "phase": String(describing: model.phase),
                    "message": model.message as Any? ?? NSNull()])
            }
            lastCPU = cpu; lastSeries = elapsed
            writeProgress(model)
        }
        if elapsed - lastProgress >= 30 {
            print("PROGRESS wall=\(Int(elapsed))s audio=\(Int(inputSeconds))s finals=\(finalSources.count) queue=\(model.queuedTranslations) rss=\(Int(memoryMB()))MB phase=\(model.phase)")
            fflush(stdout); lastProgress = elapsed
        }
    }
    func addPass(_ value: [String: Any]) { passes.append(value) }
    func audit(_ model: CaptionModel) {
        if finalSources.isEmpty { fail("No final local ASR text was recognized") }
        if provisionalASR == 0 { fail("No provisional local ASR events were observed") }
        if normalize(finalSources.joined(separator: " ")) != normalize(model.segments.map(\.source).joined(separator: " ")) {
            fail("Production timeline did not retain every actual final ASR source exactly")
        }
        for segment in model.segments {
            if !segment.isFinal { fail("Stop retained untranslated/nonfinal source revisions") }
            if let target = segment.translation, !translator.matches(segment.source, target) { fail("Stopped raw source has no actual matching translation response") }
        }
        // This one-time full display audit does not grow observation work with
        // every partial update, but catches invalid older aggregate rows.
        for segment in model.displaySegments {
            if !segment.isFinal { fail("Stopped display retained a provisional/context-pending row") }
            if let target = segment.translation, !translator.matches(segment.source, target) { fail("Stopped display has no matching exact aggregate translation") }
        }
        if model.phase != .idle || model.hasPendingTranslations || model.queuedTranslations != 0 { fail("Stop did not restore idle with an empty translation queue") }
        if translator.active != 0 { fail("Real translation engine still had active requests after stop") }
        if TranslationSessionLease.activeLiveCount != 0 || TranslationSessionLease.activeContextCount != 0 {
            fail("Production lease retained physical native awaits after stop")
        }
    }
    func report(_ model: CaptionModel, complete: Bool) -> [String: Any] {
        ["passed": complete && failures.isEmpty, "complete": complete, "failures": failures,
         "recorded_at": ISO8601DateFormatter().string(from: Date()), "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
         "mode": "100ms real-paced looping synthetic audio → real SpeechAnalyzer → production CaptionModel → reused local TranslationSession",
         "metrics": ["wall_seconds": elapsed, "input_seconds": inputSeconds, "final_asr_segments": finalSources.count,
                     "provisional_asr_events": provisionalASR, "maximum_queue_count": maximumQueue,
                     "maximum_observer_tick_gap_seconds": maximumTickGap, "maximum_asr_event_gap_seconds": maximumASRGap,
                     "maximum_rss_mb": maximumRSS, "current_rss_mb": memoryMB(), "gray_korean_observations": grayObservations,
                     "observed_final_to_gray_transitions": finalToGray, "raw_current_revision_korean_lag_p50_seconds": percentile(lag, 0.50),
                     "raw_current_revision_korean_lag_p95_seconds": percentile(lag, 0.95), "raw_current_revision_korean_lag_max_seconds": lag.max() as Any? ?? NSNull(),
                     "asr_lag_p50_seconds": percentile(asrLag, 0.50), "asr_lag_p95_seconds": percentile(asrLag, 0.95),
                     "lag_samples": lag.count, "translation": translator.metrics],
         "passes": passes, "resource_time_series": series, "translation_examples": translator.examples,
         "final_source_segments": complete ? model.segments.map { segment in
            ["source": segment.source, "korean": segment.translation as Any? ?? NSNull(), "revision": segment.revision,
             "translated_revision": segment.translatedRevision as Any? ?? NSNull(), "final": segment.isFinal,
             "audio_start": segment.audioStart, "audio_end": segment.audioEnd] as [String: Any]
         } : [],
         "limitations": ["No microphone or system-audio device was opened; synthetic file input does not establish real-speaker accuracy or microphone hardware stability.",
                         "The production microphone permission/start path and SwiftUI rendering are not exercised.",
                         "Timing observes state at 200ms and display state at 5 seconds; it excludes SwiftUI draw latency.",
                         "No language assets are downloaded. Network connectivity is not deliberately disabled by this test.",
                         "Exact source-revision matching does not establish semantic correctness.",
                         "CPU/RSS are this harness process; Apple's out-of-process language services are excluded.",
                         "Live sessions are reused and context sessions are created/retired per job, matching the production lease lifetime policy; microphone/start remains bypassed.",
                         "Restart source timestamps include a three-second artificial context boundary; pooled lag statistics include these restart observations."]]
    }
    func writeProgress(_ model: CaptionModel) {
        guard let reportPath else { return }
        do { try JSONSerialization.data(withJSONObject: report(model, complete: false), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: URL(fileURLWithPath: reportPath + ".progress.json"), options: .atomic) }
        catch { fail("Could not write progress report: \(error.localizedDescription)") }
    }
}

@main @MainActor struct ContinuousPipelineChecks {
    static func main() async {
        var options: [String: String] = [:]
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count % 2 == 0 else { print("Usage: --fixture PATH --duration-seconds 1800 --restart-seconds 30 --output PATH"); exit(2) }
        for index in stride(from: 0, to: args.count, by: 2) { options[args[index]] = args[index + 1] }
        guard let file = options["--fixture"],
              let seconds = Double(options["--duration-seconds"] ?? "1800"), seconds.isFinite, seconds > 0,
              let restart = Double(options["--restart-seconds"] ?? "30"), restart.isFinite, restart >= 0 else {
            print("Fixture path and finite positive duration / nonnegative restart duration are required")
            exit(2)
        }
        let translator = LocalTranslator()
        let recorder = Recorder(translator: translator, reportPath: options["--output"])
        let model = CaptionModel(translationOverride: { source, context in try await translator.translate(source, isContext: context) })
        model.isChecking = false; model.assetsReady = true
        let saved = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        model.contextCorrectionEnabled = true
        if let saved { UserDefaults.standard.set(saved, forKey: "contextCorrectionEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled") }
        let observer = Task {
            while !Task.isCancelled { recorder.tick(model); do { try await Task.sleep(for: .milliseconds(200)) } catch { break } }
        }
        do {
            try await pass(file: file, seconds: seconds, offset: 0, model: model, recorder: recorder, translator: translator)
            recorder.audit(model)
            if restart > 0 {
                // Preserve the previous conversation. A three-second source gap
                // prevents context grouping across this injected restart boundary.
                try await pass(file: file, seconds: restart, offset: recorder.inputSeconds + 3, model: model, recorder: recorder, translator: translator)
                recorder.audit(model)
            }
        } catch { recorder.fail("Pipeline error: \(error.localizedDescription)"); translator.cancel(); await model.stop(aborting: true) }
        observer.cancel(); await observer.value
        let report = recorder.report(model, complete: true)
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let output = options["--output"] { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
            print("RESULT passed=\(recorder.failures.isEmpty) wall=\(Int(recorder.elapsed))s finals=\(recorder.finalSources.count) failures=\(recorder.failures)")
        } catch { print("Report write failure: \(error)"); exit(1) }
        if !recorder.failures.isEmpty { exit(1) }
    }

    private static func pass(file path: String, seconds: Double, offset: Double, model: CaptionModel,
                             recorder: Recorder, translator: LocalTranslator) async throws {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let reserved = await AssetInventory.reservedLocales
        let owned = reserved.contains { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" } ? false : try await AssetInventory.reserve(locale: locale)
        do {
            let speechStatus = await AssetInventory.status(forModules: [transcriber])
            let lowStatus = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
            let highStatus = await LanguageAvailability(preferredStrategy: .highFidelity).status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
            guard speechStatus == .installed, lowStatus == .installed, highStatus == .installed else {
                throw Failure("SETUP_REQUIRED speech=\(speechStatus) low=\(lowStatus) high=\(highStatus); this test never downloads assets")
            }
            guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure("No analyzer format") }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            guard file.length > 0 else { throw Failure("Empty fixture") }
            let problems = InputProblems()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
            let pump = try AudioPump(source: file.processingFormat, target: target, continuation: continuation,
                                     onLevel: { _ in }, onProblem: { problems.record($0) })
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
            try await analyzer.prepareToAnalyze(in: target)
            model.phase = .listening
            recorder.passIndex += 1
            let began = ProcessInfo.processInfo.systemUptime
            let results = Task { for try await result in transcriber.results { recorder.receive(result, offset: offset, model: model) } }
            let analysis = Task {
                if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
            }
            do {
                let rate = file.processingFormat.sampleRate
                let chunkFrames = AVAudioFrameCount(max(1, rate / 10))
                let requestedFrames = seconds * rate
                guard requestedFrames.isFinite, requestedFrames >= 1,
                      requestedFrames < Double(AVAudioFramePosition.max) else { throw Failure("Fixture duration exceeds the supported frame range") }
                let totalFrames = AVAudioFramePosition(requestedFrames)
                var fed: AVAudioFramePosition = 0
                while fed < totalFrames {
                    guard model.phase == .listening else { throw Failure("Production model stopped during audio input: \(model.message ?? "unknown")") }
                    if file.framePosition == file.length { file.framePosition = 0 }
                    let remaining = min(totalFrames - fed, file.length - file.framePosition)
                    let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw Failure("No fixture buffer") }
                    try file.read(into: buffer, frameCount: frames)
                    fed += AVAudioFramePosition(buffer.frameLength)
                    let due = Double(fed) / rate
                    let wait = due - (ProcessInfo.processInfo.systemUptime - began)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    let invocation = ForeignTap(pump: pump, buffer: buffer)
                    await withCheckedContinuation { done in DispatchQueue.global(qos: .userInitiated).async { invocation.invoke(); done.resume() } }
                    recorder.inputSeconds += Double(buffer.frameLength) / rate
                }
                await pump.finish()
                try await OperationDeadline.run(seconds: 20, name: "Continuous fixture finish", onTimeout: { Task { await analyzer.cancelAndFinishNow() } }) {
                    try await analysis.value; try await results.value
                }
                await model.stop()
                translator.cancel()
                // Retain diagnostic evidence if a canceled Apple call ignores
                // cancellation; still exercise a new input pass after this one.
                for _ in 0..<500 where translator.active > 0 { try await Task.sleep(for: .milliseconds(20)) }
                if !problems.messages.isEmpty { recorder.fail("Audio converter errors: \(problems.messages)") }
                if pump.droppedBufferCount != 0 { recorder.fail("Audio queue dropped \(pump.droppedBufferCount) buffers") }
                recorder.addPass(["duration_seconds": seconds, "completed_wall_seconds": ProcessInfo.processInfo.systemUptime - began,
                    "dropped_audio_buffers": pump.droppedBufferCount, "input_problems": problems.messages,
                    "idle_after_stop": model.phase == .idle, "can_start_after_stop": model.canStart,
                    "physical_live_awaits_after_stop": TranslationSessionLease.activeLiveCount,
                    "physical_context_awaits_after_stop": TranslationSessionLease.activeContextCount,
                    "last_message": model.message as Any? ?? NSNull()])
                if !model.canStart { recorder.fail("Production Start remained unavailable after stop") }
            } catch {
                results.cancel(); analysis.cancel(); await pump.finish(); await analyzer.cancelAndFinishNow()
                throw error
            }
            if owned { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if owned { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }
    private struct Failure: LocalizedError {
        let value: String
        init(_ value: String) { self.value = value }
        var errorDescription: String? { value }
    }
}
