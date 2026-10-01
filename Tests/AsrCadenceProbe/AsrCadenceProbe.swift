@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

// Diagnostic only: paced audio file → local ASR module, logging when each
// result arrives relative to the audio it covers. No microphone, no downloads.
@main
struct AsrCadenceProbe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 4, let chunkMs = Double(args[3]) else {
            print("usage: probe file.aiff speech-fast|speech|dictation chunkMs"); exit(2)
        }
        do { try await run(path: args[1], mode: args[2], chunkMs: chunkMs) }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run(path: String, mode: String, chunkMs: Double) async throws {
        let locale = Locale(identifier: "en-US")
        let module: any SpeechModule
        var speech: SpeechTranscriber?
        var dictation: DictationTranscriber?
        switch mode {
        case "speech-fast":
            speech = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
            module = speech!
        case "speech":
            speech = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            module = speech!
        default:
            dictation = DictationTranscriber(locale: locale, contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange])
            module = dictation!
        }
        // Same as the repo's LocalPipelineCheck: a reservation is per process and
        // downloads nothing. Assets are used only if already installed.
        var owns = false
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }) {
            owns = try await AssetInventory.reserve(locale: locale)
        }
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else {
            if owns { await AssetInventory.release(reservedLocale: locale) }
            print("SETUP_REQUIRED mode=\(mode) status=\(status)"); exit(3)
        }
        defer { if owns { Task { await AssetInventory.release(reservedLocale: locale) } } }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            print("no format"); exit(3)
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let capacity = AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 4096
        let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: whole, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        if let error { throw error }
        let total = Int(whole.frameLength)
        let chunkFrames = max(1, Int(format.sampleRate * chunkMs / 1000))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let duration = Double(total) / format.sampleRate

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let clock = ProcessInfo.processInfo
        nonisolated(unsafe) var t0 = clock.systemUptime

        struct Event { let arrived: Double; let end: Double; let final: Bool; let text: String }
        let collector = Task { () -> [Event] in
            var events: [Event] = []
            if let speech {
                for try await r in speech.results {
                    events.append(Event(arrived: clock.systemUptime - t0, end: CMTimeGetSeconds(CMTimeRangeGetEnd(r.range)),
                                        final: r.isFinal, text: String(r.text.characters)))
                }
            } else if let dictation {
                for try await r in dictation.results {
                    events.append(Event(arrived: clock.systemUptime - t0, end: CMTimeGetSeconds(CMTimeRangeGetEnd(r.range)),
                                        final: r.isFinal, text: String(r.text.characters)))
                }
            }
            return events
        }
        let analysis = Task {
            if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
        }
        t0 = clock.systemUptime
        var offset = 0
        while offset < total {
            let frames = min(chunkFrames, total - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            chunk.frameLength = AVAudioFrameCount(frames)
            let src = UnsafeMutableAudioBufferListPointer(whole.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for i in src.indices {
                memcpy(dst[i].mData!, src[i].mData!.advanced(by: offset * bytesPerFrame), frames * bytesPerFrame)
            }
            // A chunk exists only after its last sample was "spoken".
            let due = t0 + Double(offset + frames) / format.sampleRate
            let wait = due - clock.systemUptime
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            continuation.yield(AnalyzerInput(buffer: chunk, bufferStartTime: CMTime(value: Int64(offset), timescale: CMTimeScale(format.sampleRate))))
            offset += frames
        }
        continuation.finish()
        try await analysis.value
        let events = try await collector.value

        // Group results that arrive together (<50 ms apart).
        var bursts: [[Event]] = []
        for e in events {
            if let last = bursts.last?.last, e.arrived - last.arrived < 0.05 { bursts[bursts.count - 1].append(e) }
            else { bursts.append([e]) }
        }
        print("mode=\(mode) chunkMs=\(chunkMs) format=\(format.sampleRate)Hz fixture=\(String(format: "%.2f", duration))s events=\(events.count) bursts=\(bursts.count) finals=\(events.filter(\.final).count)")
        for b in bursts {
            let e = b.last!
            print(String(format: "  t=%6.2f n=%d final=%@ audioEnd=%6.2f lag=%5.2f | %@", b.first!.arrived, b.count,
                         e.final ? "Y" : "n", e.end, e.arrived - e.end, String(e.text.suffix(48))))
        }
        let starts = bursts.map { $0.first!.arrived }
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }.sorted()
        if !gaps.isEmpty {
            print(String(format: "  burst gap median=%.2fs max=%.2fs  first result at %.2fs", gaps[gaps.count / 2], gaps.last!, starts[0]))
        }
        print("  FINAL: " + events.filter(\.final).map(\.text).joined(separator: " | "))
    }
}
