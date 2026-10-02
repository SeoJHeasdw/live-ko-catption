import Foundation

/// Public dictionaries only advise translation. Only a local dictionary can
/// correct the explicitly listed spellings in recognized text.
public struct CaptionDictionary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let context: String
    public let glossary: CaptionGlossary
    public let isPersonal: Bool

    public init(id: String, name: String, context: String = "", glossary: CaptionGlossary,
                isPersonal: Bool = false) {
        self.id = id
        self.name = String(name.prefix(60))
        self.context = String(context.prefix(240))
        self.glossary = glossary
        self.isPersonal = isPersonal
    }

    public static let preferenceKey = "selectedGlossaryDictionaries"
    public static let legacyPersonalID = "local:glossary.txt"
    public static func localID(fileName: String) -> String { "local:" + fileName }

    public static func local(fileName: String, text: String) -> Self {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        func header(_ prefix: String) -> String? {
            lines.first(where: { $0.hasPrefix(prefix) })
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        let fallback = fileName == "glossary.txt" ? "개인 용어" : (fileName as NSString).deletingPathExtension
        return Self(id: localID(fileName: fileName), name: header("# 이름:") ?? fallback,
                    context: header("# 문맥:") ?? "", glossary: CaptionGlossary(text: text), isPersonal: true)
    }
}

public struct DictionaryTermConflict: Equatable, Sendable {
    public let source: String
    public let dictionaries: [String]
}

/// A personal translation wins over a public suggestion. Conflicting entries
/// at the same priority are omitted rather than resolved by checkbox order.
public struct DictionaryTerms: Sendable {
    public let pairs: [(String, String)]
    public let conflicts: [DictionaryTermConflict]

    public init(dictionaries: [CaptionDictionary], direction: CaptionDirection) {
        struct Candidate {
            let source: String
            let target: String
            let dictionary: CaptionDictionary
        }
        var groups: [String: [Candidate]] = [:]
        var order: [String] = []
        // Personal entries are first, regardless of the order of selection.
        for dictionary in dictionaries.filter(\.isPersonal) + dictionaries.filter({ !$0.isPersonal }) {
            for entry in dictionary.glossary.entries {
                let source = direction == .englishToKorean ? entry.english : entry.korean
                let target = direction == .englishToKorean ? entry.korean : entry.english
                let normalized = direction == .koreanToEnglish ? source.lowercased().filter { !$0.isWhitespace }
                    : source.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).joined(separator: " ")
                let key = normalized.isEmpty ? source.lowercased() : normalized
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(Candidate(source: source, target: target, dictionary: dictionary))
            }
        }
        var pairs: [(String, String)] = []
        var conflicts: [DictionaryTermConflict] = []
        for key in order {
            guard let candidates = groups[key], let first = candidates.first else { continue }
            let preferred = first.dictionary.isPersonal ? candidates.filter { $0.dictionary.isPersonal } : candidates
            if Set(preferred.map(\.target)).count > 1 {
                conflicts.append(DictionaryTermConflict(source: first.source,
                    dictionaries: Array(Set(preferred.map { $0.dictionary.name })).sorted()))
            } else { pairs.append((first.source, first.target)) }
        }
        self.pairs = pairs
        self.conflicts = conflicts
    }

    /// Ambiguous local ASR aliases are excluded independently of translations.
    /// Never use public dictionary entries to rewrite recognized text.
    public static func corrections(dictionaries: [CaptionDictionary], direction: CaptionDirection) -> CaptionGlossary {
        let entries = dictionaries.filter(\.isPersonal).flatMap { $0.glossary.entries }
        var targets: [String: Set<String>] = [:]
        for entry in entries {
            let target = direction == .englishToKorean ? entry.english : entry.korean
            for alias in entry.heardAs { targets[alias.lowercased(), default: []].insert(target) }
        }
        return CaptionGlossary(entries: entries.map { entry in
            GlossaryEntry(english: entry.english, korean: entry.korean,
                heardAs: entry.heardAs.filter { targets[$0.lowercased()]?.count == 1 })
        })
    }
}
