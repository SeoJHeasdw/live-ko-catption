import CaptionCore
import Foundation

/// Runs the installed pinned model over invented talk sentences with subject
/// areas selected, and fails when an output is a translated prompt rather than
/// a caption. No audio, Apple translation, network or user dictionary is used.
@main struct PromptLeakChecks {
    private struct Row: Codable {
        let condition: String
        let direction: String
        let source: String
        let prompt: String
        let text: String
        let leakLike: Bool
        let guardAccepted: Bool
        let total_ms: Double
    }

    private struct Summary: Codable {
        let condition: String
        let direction: String
        let outputs: Int
        let leakLike: Int
        let leakLikeAccepted: Int
        let median_ms: Double
        let max_ms: Double
    }

    private struct Report: Codable {
        let generatedAt: String
        let platform: String
        let runtimePath: String
        let conditions: [String]
        let limitations: [String]
        var summaries: [Summary] = []
        var rows: [Row] = []
    }

    @MainActor static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Prompt leak check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// What an echoed prompt looks like, independent of the product guard:
    /// labelled lines, the instruction's own words, or far more text than a
    /// translation of this source can need.
    private static func looksLeaked(_ text: String, source: String, direction: CaptionDirection) -> Bool {
        let lowered = text.lowercased()
        let echoes = ["배경 정보", "원문]", "번역된 결과", "추가 설명", "추가적인 설명", "강연", "background information",
                      "source text", "translated result", "additional explanation", "talk about", "reference the following"]
        return text.contains(where: \.isNewline) || text.contains("[") || text.contains("【") ||
            echoes.contains { lowered.contains($0) && !source.lowercased().contains($0) } ||
            text.count > (direction == .englishToKorean ? source.count * 2 + 40 : source.count * 6 + 60)
    }

    private static func sources(_ file: String) throws -> [String] {
        let lines = try String(contentsOfFile: file, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var all = lines
        for size in 2...4 {
            for start in stride(from: 0, through: lines.count - size, by: size) {
                let joined = lines[start..<(start + size)].joined(separator: " ")
                if joined.count <= 500 { all.append(joined) }
            }
        }
        return all
    }

    @MainActor private static func run() async throws {
        var runtime = ".build/local-runtime/libcaption_local_translation.dylib"
        var output = ".build/prompt-leak-checks/report.json"
        var arguments = CommandLine.arguments.dropFirst()
        while let key = arguments.popFirst(), let value = arguments.popFirst() {
            switch key {
            case "--runtime": runtime = value
            case "--output": output = value
            default: throw CaptionCheckError.message("Unknown argument \(key)")
            }
        }
        // The product's own pinned size and SHA-256 verification; no download.
        await LocalModelStore.shared.refresh()
        guard let modelURL = LocalModelStore.shared.modelURL else {
            throw CaptionCheckError.message("The pinned model is not installed or failed verification: \(LocalModelStore.shared.message)")
        }
        guard FileManager.default.fileExists(atPath: runtime) else { throw CaptionCheckError.message("Runtime not built: \(runtime)") }
        let engine = LocalTranslationEngine(runtimeURL: URL(fileURLWithPath: runtime))
        try await engine.prepare(modelURL: modelURL)

        let local = CaptionDictionary.local(fileName: "check.txt", text: "# 이름: 검사용\n# 문맥: 데이터 플랫폼 도입 회의\n")
        let conditions: [(String, [CaptionDictionary])] = [
            ("AI+IBM", [BuiltInDictionaries.ai, BuiltInDictionaries.ibm]),
            ("AI+IBM+finance", BuiltInDictionaries.all),
            ("AI+IBM+finance+local Korean subject", BuiltInDictionaries.all + [local])
        ]
        var report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
            platform: ProcessInfo.processInfo.operatingSystemVersionString, runtimePath: runtime,
            conditions: ["Invented sentences from Tests/PromptLeakChecks, each alone and joined into groups of 2-4 up to 500 characters.",
                "One prepared engine, serial requests, greedy decoding, 6000 ms per request, validateResult=false.",
                "guardAccepted uses the candidate itself as the numeric baseline, so it reports the format, script and length checks only.",
                "leakLike is this check's own signature: a line break, bracket label, instruction wording or excess length."],
            limitations: ["Authored text, not recognized speech. It does not measure meaning, fluency or caption latency.",
                "A leak-free run covers these sentences and subject descriptions only.",
                "The 6000 ms limit is for observation and is not the product's 1500 ms budget."])
        var failures = 0
        for (file, direction) in [("Tests/PromptLeakChecks/english.txt", CaptionDirection.englishToKorean),
                                  ("Tests/PromptLeakChecks/korean.txt", .koreanToEnglish)] {
            let inputs = try sources(file)
            for (name, dictionaries) in conditions {
                var rows: [Row] = []
                for source in inputs {
                    var request = LocalTranslationRequest(source: source, direction: direction, dictionaries: dictionaries)
                    guard request.isWithinBudget else { throw CaptionCheckError.message("Fixture exceeds the prompt budget: \(source)") }
                    let row: Row
                    do {
                        let result = try await engine.translate(request, timeoutMilliseconds: 6_000, validateResult: false)
                        request.baseline = result.text
                        row = Row(condition: name, direction: direction.rawValue, source: source, prompt: request.prompt,
                            text: result.text, leakLike: looksLeaked(result.text, source: source, direction: direction),
                            guardAccepted: request.accepts(result.text), total_ms: result.statistics.total_ms)
                    } catch LocalTranslationError.native(3, _) {
                        // These sources fit the 192-token output budget. A
                        // truncated answer is an echoed prompt running on.
                        row = Row(condition: name, direction: direction.rawValue, source: source, prompt: request.prompt,
                            text: "(truncated at the output budget)", leakLike: true, guardAccepted: false, total_ms: 0)
                    }
                    if row.leakLike {
                        print("\(row.guardAccepted ? "ACCEPTED LEAK" : "rejected leak") [\(name)] \(source)\n    => \(row.text.replacingOccurrences(of: "\n", with: "\\n"))")
                    }
                    rows.append(row)
                }
                let times = rows.map(\.total_ms).sorted()
                let summary = Summary(condition: name, direction: direction.rawValue, outputs: rows.count,
                    leakLike: rows.filter(\.leakLike).count, leakLikeAccepted: rows.filter { $0.leakLike && $0.guardAccepted }.count,
                    median_ms: times[times.count / 2], max_ms: times.last ?? 0)
                print("\(direction.rawValue) · \(name): \(summary.outputs) outputs, \(summary.leakLike) leak-like, \(summary.leakLikeAccepted) accepted by the guard, median \(Int(summary.median_ms)) ms")
                // A rejected echo only wastes one optional refinement. More
                // than one in a hundred, or any shown as a caption, is a defect.
                if summary.leakLikeAccepted > 0 || summary.leakLike * 100 > summary.outputs { failures += 1 }
                report.summaries.append(summary)
                report.rows += rows
            }
        }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        print("Saved \(report.rows.count) outputs to \(output).")
        guard failures == 0 else { throw CaptionCheckError.message("\(failures) condition(s) echoed the prompt") }
        print("PASS: no selected subject area was returned as a caption.")
    }
}

private enum CaptionCheckError: Error { case message(String) }
