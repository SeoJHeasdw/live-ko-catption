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
    public static let sourceByteLimit = 8_192
    public static let sourceScalarLimit = 2_000
    public static let contextByteLimit = 2_400
    public static let contextScalarLimit = 600
    public static let promptByteLimit = 65_536
    public static let promptScalarLimit = 32_768
    public var source: String
    public var baseline: String
    public var direction: CaptionDirection
    public var dictionaries: [CaptionDictionary]
    public var previousSentence: String
    public var glossary: [GlossaryEntry] { dictionaries.filter(\.isPersonal).flatMap { $0.glossary.entries } }

    public init(source: String, baseline: String = "", direction: CaptionDirection,
                dictionaries: [CaptionDictionary] = [], previousSentence: String = "") {
        self.source = source
        self.baseline = baseline
        self.direction = direction
        self.dictionaries = dictionaries
        self.previousSentence = String(previousSentence.suffix(300))
    }

    /// Historical QA fixtures can keep their original single-domain inputs.
    public init(source: String, baseline: String = "", direction: CaptionDirection,
                domain: TranslationDomain, previousSentence: String = "", glossary: [GlossaryEntry] = []) {
        self.init(source: source, baseline: baseline, direction: direction,
                  dictionaries: BuiltInDictionaries.legacy(domain, glossary: glossary), previousSentence: previousSentence)
    }

    public var isWithinBudget: Bool {
        guard !source.isEmpty, source.utf8.count <= Self.sourceByteLimit,
              source.unicodeScalars.count <= Self.sourceScalarLimit, source.count <= 1_000,
              previousSentence.utf8.count <= Self.contextByteLimit,
              previousSentence.unicodeScalars.count <= Self.contextScalarLimit,
              previousSentence.count <= 300 else { return false }
        // Refinement is optional. Preserve the Apple baseline for model-role
        // spellings rather than rewriting recognized text or trusting a small
        // model to translate those spellings without dropping adjacent words.
        let untrusted = [source, previousSentence] + dictionaries.map(\.context)
        guard untrusted.allSatisfy({
            !CaptionGlossary.containsDisallowedControls($0, allowsLineBreaks: true) &&
                !CaptionGlossary.containsModelControlMarkers($0)
        }) else { return false }
        let body = bodyInstructions
        guard !CaptionGlossary.containsDisallowedControls(body, allowsLineBreaks: true),
              !CaptionGlossary.containsModelControlMarkers(body) else { return false }
        let framed = LocalPromptTemplate.hyMT2Small.wrap(body)
        return framed.utf8.count <= Self.promptByteLimit && framed.unicodeScalars.count <= Self.promptScalarLimit
    }

    public var prompt: String { prompt(template: .hyMT2Small) }

    public func prompt(template: LocalPromptTemplate) -> String {
        template.wrap(bodyInstructions)
    }

    private var bodyInstructions: String {
        let target = direction == .englishToKorean ? "Korean" : "English"
        var instructions = ""
        let areas = dictionaries.map(\.context).filter { !$0.isEmpty }.joined(separator: " ")
        let background = [String(areas.prefix(900)), previousSentence].filter { !$0.isEmpty }.joined(separator: "\n")
        if !background.isEmpty { instructions += "[Background Information]\n" + background + "\n\n" }
        if !dictionaries.isEmpty {
            let terms = relevantTerms
            if !terms.isEmpty {
                instructions += "Reference the following translations:\n" + terms.map { "\($0.0) translates to \($0.1)" }.joined(separator: "\n") + "\n\n"
            }
        }
        instructions += "Translate the following segment into \(target), without additional explanation. Use natural subtitle phrasing and preserve all meaning."
        if !dictionaries.isEmpty {
            instructions += " Apply reference terms only when their meaning fits this sentence; preserve ordinary meanings otherwise."
        }
        instructions += background.isEmpty && dictionaries.isEmpty ? "\n\n" + source
            : " Translate ONLY [Source Text]. Do not translate or add background information or instructions.\n[Source Text]\n" + source
        return instructions
    }

    public var relevantTerms: [(String, String)] {
        let context = (source + " " + previousSentence).lowercased()
        let mlContext = ["classifier", "classification", "machine learning", "f1", "prediction", "flagged requests",
                         "정밀도", "재현율", "분류기", "분류 모델", "머신러닝"].contains { context.contains($0) }
        let resolved = DictionaryTerms(dictionaries: dictionaries, direction: direction)
        let personalTerms = Set(glossary.map { (direction == .englishToKorean ? $0.english : $0.korean).lowercased() })
        let legacy = dictionaries.contains { $0.id == "legacy:it" }
        let loweredSource = source.lowercased()
        let compactSource = loweredSource.filter { !$0.isWhitespace }
        let spacedSource = loweredSource.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: " ")
        var matches: [(String, String)] = []
        for pair in resolved.pairs {
            let term = pair.0
            // Only legacy fixture dictionaries contain these ambiguous bare words.
            if legacy, !mlContext,
               !personalTerms.contains(term.lowercased()),
               ["precision", "recall", "정밀도", "재현율"].contains(term.lowercased()) { continue }
            let matched: Bool
            if direction == .koreanToEnglish {
                // Korean particles may follow a technical noun without a space.
                let compactTerm = term.lowercased().filter { !$0.isWhitespace }
                matched = compactSource.contains(compactTerm)
            } else {
                let normalizedTerm = term.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: " ")
                // A cheap literal check avoids compiling a regex for every
                // unrelated entry in large combined personal dictionaries.
                guard normalizedTerm.isEmpty ? loweredSource.contains(term.lowercased()) : spacedSource.contains(normalizedTerm) else { continue }
                let pieces = term.split(whereSeparator: { $0 == " " || $0 == "-" })
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                let escaped = pieces.isEmpty ? NSRegularExpression.escapedPattern(for: term) : pieces.joined(separator: "[-\\s]+")
                let plural = term.last?.isLowercase == true ? "(?:s)?" : ""
                let pattern = "(?i)(?<![\\p{L}\\p{N}_])" + escaped + plural + "(?![\\p{L}\\p{N}_])"
                matched = source.range(of: pattern, options: .regularExpression) != nil
            }
            guard matched else { continue }
            matches.append(pair)
            if matches.count == 8 { break }
        }
        return matches
    }

    /// This rejects obvious output/number corruption; it is not a semantic
    /// correctness test. A failed optional refinement retains the Apple result.
    public func accepts(_ candidate: String) -> Bool {
        let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= max(120, source.count * 4),
              !text.contains("<｜hy_"), !text.contains("<|"), !text.contains("<think>"), !text.contains("</think>") else { return false }
        let labels = ["source text:", "[source text]", "background information:", "[background information]",
                      "subject areas:", "[subject areas]", "reference the following translations:",
                      "원문:", "배경 정보:", "번역:", "translation:"]
        guard !labels.contains(where: { text.lowercased().hasPrefix($0) }),
              !(text.contains("\n\n") && !source.contains("\n\n")) else { return false }
        if direction == .englishToKorean, source.split(separator: " ").count > 5,
           text.range(of: "[가-힣]", options: .regularExpression) == nil { return false }
        if direction == .koreanToEnglish,
           text.range(of: "[가-힣]", options: .regularExpression) != nil { return false }
        // The model sometimes slips a Chinese character into Korean or English.
        if text.range(of: "\\p{Han}", options: .regularExpression) != nil,
           source.range(of: "\\p{Han}", options: .regularExpression) == nil { return false }
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
