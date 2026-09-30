@preconcurrency import AVFoundation
import Foundation
import Speech
import CoreMedia
@preconcurrency import Translation

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var problems: [String] = []
    func report(_ problem: String) { lock.withLock { problems.append(problem) } }
    var errors: [String] { lock.withLock { problems } }
}

// The AVAudioEngine contract calls a nonsendable Objective-C block from its
// own audio queue. This wrapper reproduces that exact boundary for the check.
private final class TapInvocation: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    init(block: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer) {
        self.block = block; self.buffer = buffer
    }
    func invoke() { block(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)) }
}

@main @MainActor
struct AudioCallbackChecks {
    static func main() async {
        do {
            for (rate, channels) in [(48000.0, AVAudioChannelCount(1)), (44100.0, AVAudioChannelCount(2))] {
                try await checkTap(rate: rate, channels: channels)
            }
            try await checkNotification()
            print("3 audio callback checks passed.")
            if CommandLine.arguments.count == 2 {
                try await checkLiveStream(filePath: CommandLine.arguments[1])
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func checkTap(rate: Double, channels: AVAudioChannelCount) async throws {
        guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800) else {
            throw Failure("Could not make fixture formats")
        }
        buffer.frameLength = 4800
        for channel in 0..<Int(channels) {
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = sin(Float(index) * 0.04) * 0.25
            }
        }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<Speech.AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) })
        // Deliberately create the production tap from the main actor, just as
        // the app does, and then invoke it on a foreign queue.
        let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
        await withCheckedContinuation { finished in
            DispatchQueue.global(qos: .userInitiated).async {
                invocation.invoke()
                finished.resume()
            }
        }
        await pump.finish()
        var frames: UInt64 = 0
        for await input in stream { frames += UInt64(input.buffer.frameLength) }
        guard frames > 0, pump.bufferCount > 0, state.errors.isEmpty else {
            throw Failure("Foreign-queue tap failed: frames=\(frames), errors=\(state.errors)")
        }
        print("PASS: foreign audio queue, \(Int(rate)) Hz / \(channels) ch → mono Int16; \(frames) frames")
    }

    private static func checkNotification() async throws {
        var handledOnMain = false
        let callback = AudioCallbackBridge.configurationBlock {
            handledOnMain = Thread.isMainThread
        }
        await withCheckedContinuation { finished in
            DispatchQueue.global().async {
                callback(Notification(name: .AVAudioEngineConfigurationChange))
                finished.resume()
            }
        }
        for _ in 0..<40 where !handledOnMain { try await Task.sleep(for: .milliseconds(25)) }
        guard handledOnMain else { throw Failure("Configuration notification did not hop to the main actor") }
        print("PASS: foreign configuration notification safely reaches main actor")
    }

    private static func checkLiveStream(filePath: String) async throws {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults, .fastResults],
                                           attributeOptions: [.audioTimeRange])
        let ownsReservation = try await AssetInventory.reserve(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw Failure("Prepare local English models in the app before checking the live stream")
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: filePath))
            let state = CallbackState()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(128))
            let pump = try AudioPump(source: file.processingFormat, target: target, continuation: continuation,
                                     onLevel: { _ in }, onProblem: { state.report($0) })
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: target)
            let began = ProcessInfo.processInfo.systemUptime
            let results = Task {
                var source: [String] = []
                var timeline = CaptionTimeline()
                var partials = 0
                var firstPartial: Double?
                for try await result in transcriber.results {
                    timeline.accept(source: String(result.text.characters),
                                    audioStart: CMTimeGetSeconds(result.range.start),
                                    audioEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                                    isFinal: result.isFinal)
                    if result.isFinal { source.append(String(result.text.characters)) }
                    else {
                        partials += 1
                        if firstPartial == nil { firstPartial = ProcessInfo.processInfo.systemUptime - began }
                    }
                }
                return (source.joined(separator: " "), timeline.segments.map(\.source), partials, firstPartial)
            }
            // This is the production lifecycle: live analysis in its own task,
            // then close the producer, finalize, and drain results.
            let analysis = Task {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
            }
            let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                    throw Failure("Could not allocate streaming fixture buffer")
                }
                try file.read(into: buffer, frameCount: chunkFrames)
                let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
                await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async {
                        invocation.invoke()
                        done.resume()
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            await pump.finish()
            try await analysis.value
            let (source, retained, partials, firstPartial) = try await results.value
            let normalize: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            guard !source.isEmpty, partials > 0, state.errors.isEmpty,
                  normalize(source) == normalize(retained.joined(separator: " ")) else {
                throw Failure("Live stream check failed: source=\(source), retained=\(retained), errors=\(state.errors)")
            }
            let translator = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                                target: Locale.Language(identifier: "ko"), preferredStrategy: .lowLatency)
            let translated = try await translator.translate(source)
            guard !translated.targetText.isEmpty else { throw Failure("Live stream translation was empty") }
            print("PASS: paced audio stream → actual local recognition → caption timeline → Korean translation")
            print("EN: \(source)")
            print("KO: \(translated.targetText)")
            print("Partial events: \(partials); first English partial after \(firstPartial ?? -1)s of fixture streaming")
            print("This fixture check does not measure hardware microphone latency.")
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
