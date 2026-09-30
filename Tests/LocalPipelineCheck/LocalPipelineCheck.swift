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
        if CommandLine.arguments.dropFirst().first == "--translation-quality" {
            do { try await checkTranslationQuality(compareStrategies: CommandLine.arguments.contains("--compare-strategies")) }
            catch {
                FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        guard CommandLine.arguments.count == 2 else {
            print("Usage: LocalPipelineCheck /absolute/path/to/english-audio.aiff")
            print("       LocalPipelineCheck --translation-quality [--compare-strategies]")
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
                "recorded_at": ISO8601DateFormatter().string(from: Date()),
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "audio_fixture_filename": audioFile.url.lastPathComponent,
                "translation_mode": "all final recognized text joined into one request after recognition; not the app's concurrent scheduler",
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

    /// This is an adversarial corpus, not a semantic pass/fail oracle. A nonempty
    /// response can still be wrong; the Korean review guide remains in the JSON.
    private static func checkTranslationQuality(compareStrategies: Bool) async throws {
        let allowedArguments = Set(["--translation-quality", "--compare-strategies"])
        guard CommandLine.arguments.dropFirst().allSatisfy(allowedArguments.contains) else {
            throw CheckError.message("Unknown translation-quality option.")
        }
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ko")
        let corpus: [(id: String, category: String, english: String, review: String)] = [
            ("duck_alone", "ambiguous word", "I saw her duck.", "문맥 없이는 그녀의 오리와 몸을 숙이는 동작 모두 가능하다."),
            ("duck_animal_context", "following context", "I saw her duck. It was swimming in the pond.", "연못에서 헤엄치는 오리다."),
            ("duck_action_context", "following context", "I saw her duck. She bent down to avoid the ball.", "앞 문장의 duck도 공을 피하려고 몸을 숙인 동작이어야 한다."),
            ("negation", "negation", "We cannot approve this plan yet, but we don't rule out approving it next month.", "지금은 승인 불가지만 다음 달 승인 가능성은 열려 있다."),
            ("double_negation", "negation", "I don't think he didn't know about it.", "그가 몰랐다는 주장에 동의하지 않는다. 부정을 반대로 바꾸면 안 된다."),
            ("numbers", "numbers and units", "The budget is thirteen million dollars, not thirty million. We need a 0.5 percent increase, not five percent.", "1,300만 달러와 3,000만 달러, 0.5%와 5%를 구별해야 한다."),
            ("idiom", "idiom", "We need to break the ice before getting the ball rolling. Let's not throw anyone under the bus.", "어색함을 풀고 일을 시작하자는 뜻이다. 다른 사람에게 책임을 떠넘기거나 희생시키지 말자는 뜻이다."),
            ("meaning_reversal_fragment", "unfinished source", "The proposal is not", "미완성 원문이므로 단정적인 부정 번역을 확정해서는 안 된다."),
            ("meaning_reversal_complete", "unfinished source continuation", "The proposal is not only cheaper but also safer.", "제안은 더 저렴하고 더 안전하다. 앞부분의 부정 해석이 수정되어야 한다."),
            ("continuation_first", "speech context", "I used to think this was a good idea.", "예전에는 좋은 생각이라고 여겼다는 뜻이다. 지금도 그렇다고 단정하지 않는다."),
            ("continuation_both", "speech context", "I used to think this was a good idea. But after seeing the results, I changed my mind.", "결과를 본 뒤 생각을 바꿨다. 현재도 좋은 생각이라고 여긴다는 뜻이 아니다."),
            ("self_correction", "speaker correction", "The meeting is on Thursday, sorry, I mean Tuesday, at three fifteen.", "화자가 목요일을 화요일로 정정했다. 최종 요일은 화요일이며 오전·오후는 원문에 없다."),
            ("table_discussion", "idiom", "We should table this discussion until next week.", "다음 주까지 논의를 보류하자는 뜻이다."),
            ("pronouns_alone", "pronoun and idiom", "She said she couldn't make it.", "make it은 물건을 만들 수 없다는 뜻이 아니라 참석할 수 없다는 뜻이다."),
            ("pronouns_context", "pronoun and idiom", "Maya has a scheduling conflict. She said she couldn't make it.", "마야는 일정이 겹쳐 참석할 수 없다."),
            ("cake_idiom", "ambiguous idiom", "It is a piece of cake.", "이 문장만 있으면 쉽다는 관용 표현으로 읽힐 수 있다."),
            ("cake_food", "following context", "It is a piece of cake. Put it in the fridge before the frosting melts.", "다음 문맥으로 실제 케이크 조각임이 드러난다. 식은 죽 먹기라고 확정하면 오역이다."),
            ("technical", "terminology and relation", "The model's recall improved, but its precision dropped. The p-value is below 0.05; that doesn't prove causation.", "재현율 증가와 정밀도 감소를 구별한다. below는 미만이다. 유의성만으로 인과를 증명하지 않는다."),
            ("currency_names", "names and currency", "Ask Dr. Lee whether we owe Acme twelve hundred euros or twelve thousand euros.", "Lee와 Acme 고유명사, 1,200유로와 12,000유로를 보존해야 한다."),
            ("conditional", "condition and uncertainty", "If demand falls, we may cut production; we have not decided to close the factory.", "수요 감소를 조건으로 생산 감축 가능성이 있으며 공장 폐쇄를 결정한 것은 아니다.")
        ]
        var reports: [[String: Any]] = []
        let strategies: [(String, TranslationSession.Strategy)] = compareStrategies
            ? [("lowLatency", .lowLatency), ("highFidelity", .highFidelity)] : [("lowLatency", .lowLatency)]
        var unavailable: [String] = []
        for (name, strategy) in strategies {
            let status = await LanguageAvailability(preferredStrategy: strategy).status(from: source, to: target)
            guard status == .installed else {
                unavailable.append("\(name): \(status)")
                continue
            }
            let session = TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
            for item in corpus {
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    let response = try await session.translate(item.english)
                    let elapsed = ProcessInfo.processInfo.systemUptime - began
                    guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CheckError.message("Empty translation for \(item.id)")
                    }
                    reports.append(["id": item.id, "category": item.category, "requested_strategy": name,
                                    "english": item.english, "korean": response.targetText,
                                    "text_translation_seconds": elapsed,
                                    "manual_review_guide": item.review, "status": "manual_review_required"])
                } catch {
                    reports.append(["id": item.id, "requested_strategy": name, "english": item.english,
                                    "error": error.localizedDescription, "status": "engine_error"])
                }
            }
        }
        guard !reports.isEmpty else {
            throw CheckError.message("SETUP_REQUIRED: \(unavailable.joined(separator: "; ")). Prepare languages in the app first; this check never downloads assets.")
        }
        let report: [String: Any] = [
            "mode": "local adversarial text translation corpus; semantic quality requires human review",
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["No microphone, ASR, live latency, or offline-network isolation was tested.",
                            "Requested highFidelity can fall back to traditional models; this report does not identify the actual engine.",
                            "Split and joined text pairs deliberately expose missing context; nonempty output is not proof of accuracy."],
            "unavailable_strategies": unavailable,
            "cases": reports
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        if reports.contains(where: { $0["status"] as? String == "engine_error" }) { exit(1) }
    }

    enum CheckError: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let value): return value } }
    }
}
