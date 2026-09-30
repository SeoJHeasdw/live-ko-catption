@preconcurrency import AVFoundation
import Foundation
import CaptionCore
import CoreMedia
import Speech
@preconcurrency import Translation

/// Exercises the real on-device engines with an explicit audio fixture. It never
/// opens a microphone or downloads assets. File throughput is not live latency.
@main @MainActor
struct LocalPipelineCheck {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: LocalPipelineCheck /absolute/path/to/english-audio.aiff")
            exit(2)
        }
        let locale = Locale(identifier: "en-US")
        var ownsReservation = false
        do {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                               reportingOptions: [.volatileResults, .fastResults],
                                               attributeOptions: [.audioTimeRange])
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }) {
                ownsReservation = try await AssetInventory.reserve(locale: locale)
            }
            let speechStatus = await AssetInventory.status(forModules: [transcriber])
            let translationStatus = await LanguageAvailability(preferredStrategy: .lowLatency)
                .status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko"))
            guard speechStatus == .installed, translationStatus == .installed else {
                print("SETUP_REQUIRED: speech=\(speechStatus), translation=\(translationStatus). Prepare languages in the app first.")
                if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
                exit(2)
            }
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            let resultTask = Task {
                var finalized: [String] = []
                var provisionalCount = 0
                var timeline = CaptionTimeline()
                for try await result in transcriber.results {
                    timeline.accept(source: String(result.text.characters),
                                    audioStart: CMTimeGetSeconds(result.range.start),
                                    audioEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                                    isFinal: result.isFinal)
                    if result.isFinal { finalized.append(String(result.text.characters)) }
                    else { provisionalCount += 1 }
                }
                return (finalized.joined(separator: " "), provisionalCount, timeline.segments.map(\.source))
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let begin = ProcessInfo.processInfo.systemUptime
            if let end = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: end)
            } else { await analyzer.cancelAndFinishNow() }
            let (source, partialCount, retainedSources) = try await resultTask.value
            let recognitionTime = ProcessInfo.processInfo.systemUptime - begin
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CheckError.message("The speech engine produced no final text.")
            }
            let normalize: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            guard normalize(source) == normalize(retainedSources.joined(separator: " ")) else {
                throw CheckError.message("Caption timeline lost recognized text: expected=\(source), retained=\(retainedSources)")
            }
            let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                             target: Locale.Language(identifier: "ko"), preferredStrategy: .lowLatency)
            let translationBegin = ProcessInfo.processInfo.systemUptime
            let response = try await session.translate(source)
            let translationTime = ProcessInfo.processInfo.systemUptime - translationBegin
            guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CheckError.message("The translation engine produced empty text.")
            }
            let report: [String: Any] = [
                "mode": "local audio-file integration check; not live microphone latency",
                "fixture_seconds": duration,
                "recognition_seconds": recognitionTime,
                "translation_seconds": translationTime,
                "provisional_events": partialCount,
                "retained_sources": retainedSources,
                "english": source,
                "korean": response.targetText
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    enum CheckError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let value): return value } }
    }
}
