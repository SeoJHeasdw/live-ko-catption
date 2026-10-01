import Foundation

/// The wrapper each model's official chat_template.jinja produces for one user
/// message. The instruction text inside is the same for both sizes.
public enum LocalPromptTemplate: String, Sendable {
    case hyMT2Small, hyMT2Dense

    /// A model file is identified by its pinned name; the 7B files use the
    /// dense template, every other supported file the 1.8B one.
    public static func matching(modelFileName name: String) -> LocalPromptTemplate {
        name.range(of: "-7B-", options: .caseInsensitive) != nil ? .hyMT2Dense : .hyMT2Small
    }

    func wrap(_ instructions: String) -> String {
        switch self {
        // These are the tokenizer's own Unicode special tokens.
        case .hyMT2Small: return "<｜hy_begin▁of▁sentence｜><｜hy_User｜>" + instructions + "<｜hy_Assistant｜>"
        case .hyMT2Dense: return "<|startoftext|>" + instructions + "<|extra_0|>"
        }
    }
}

/// Small, explicit inputs: no session-history prompt, no network lookup, and no
/// replacement of ambiguous words in a completed caption.
public struct LocalTranslationRequest: Sendable, Equatable {
    public var source: String
    public var baseline: String
    public var direction: CaptionDirection
    public var domain: TranslationDomain
    public var previousSentence: String

    public init(source: String, baseline: String = "", direction: CaptionDirection,
                domain: TranslationDomain = .general, previousSentence: String = "") {
        self.source = source
        self.baseline = baseline
        self.direction = direction
        self.domain = domain
        self.previousSentence = String(previousSentence.suffix(300))
    }

    public var isWithinBudget: Bool { !source.isEmpty && source.count <= 1_000 }

    public var prompt: String { prompt(template: .hyMT2Small) }

    public func prompt(template: LocalPromptTemplate) -> String {
        let target = direction == .englishToKorean ? "Korean" : "English"
        var instructions = ""
        if !previousSentence.isEmpty {
            instructions += "[Background Information]\n" + previousSentence + "\n\n"
        }
        if domain == .it {
            let terms = relevantTerms
            if !terms.isEmpty {
                instructions += "Reference the following translations:\n" + terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n") + "\n\n"
            }
        }
        instructions += "Translate the following segment into \(target), without additional explanation. Use natural subtitle phrasing and preserve all meaning."
        if domain == .it { instructions += " This is an IT discussion." }
        instructions += previousSentence.isEmpty ? "\n\n" + source : " Translate only [Source Text], using the background for context.\n[Source Text]\n" + source
        return template.wrap(instructions)
    }

    public var relevantTerms: [(String, String)] {
        let pairs: [(String, String)] = [
            ("deployment", "배포"), ("rollback", "롤백"), ("latency", "지연 시간"),
            ("throughput", "처리량"), ("memory leak", "메모리 누수"),
            ("authentication", "인증"), ("authorization", "권한 부여"),
            ("load balancer", "로드 밸런서"), ("container", "컨테이너"),
            ("namespace", "네임스페이스"), ("cache", "캐시"),
            ("API", "API"), ("Kubernetes", "Kubernetes")
        ]
        let mlTerms: [(String, String)] = [("precision", "정밀도"), ("recall", "재현율")]
        let context = (source + " " + previousSentence).lowercased()
        let mlContext = ["classifier", "classification", "machine learning", "f1", "prediction", "flagged requests",
                         "정밀도", "재현율", "분류기", "분류 모델", "머신러닝"].contains { context.contains($0) }
        return (pairs + (mlContext ? mlTerms : [])).compactMap { pair in
            let term = direction == .englishToKorean ? pair.0 : pair.1
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])"
            let matched: Bool
            if direction == .koreanToEnglish {
                // Korean particles may follow a technical noun without a space.
                matched = source.contains(term)
            } else { matched = source.range(of: pattern, options: .regularExpression) != nil }
            guard matched else { return nil }
            return direction == .englishToKorean ? pair : (pair.1, pair.0)
        }.prefix(6).map { $0 }
    }

    /// This rejects obvious output/number corruption; it is not a semantic
    /// correctness test. A failed optional refinement retains the Apple result.
    public func accepts(_ candidate: String) -> Bool {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= max(120, source.count * 4),
              !text.contains("<｜hy_"), !text.contains("<|"), !text.contains("<think>"), !text.contains("</think>") else { return false }
        let labels = ["source text:", "[source text]", "background information:", "[background information]",
                      "원문:", "배경 정보:", "번역:", "translation:"]
        guard !labels.contains(where: { text.lowercased().hasPrefix($0) }),
              !(text.contains("\n\n") && !source.contains("\n\n")) else { return false }
        if direction == .englishToKorean, source.split(separator: " ").count > 5,
           text.range(of: "[가-힣]", options: .regularExpression) == nil { return false }
        if direction == .koreanToEnglish,
           text.range(of: "[가-힣]", options: .regularExpression) != nil { return false }
        let numbers = Self.numbers(in: baseline)
        return numbers == Self.numbers(in: text)
    }

    private static func numbers(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "[-+]?[0-9]+(?:[,][0-9]{3})*(?:[.][0-9]+)?") else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            let raw = ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
            return NSDecimalNumber(string: raw, locale: Locale(identifier: "en_US_POSIX")).stringValue
        }.sorted()
    }
}
