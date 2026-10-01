import Foundation

/// One term the user maintains. `heardAs` lists what the recognizer writes
/// when it mishears the term, so the source can be corrected before translation.
public struct GlossaryEntry: Equatable, Sendable {
    public let english: String
    public let korean: String
    public let heardAs: [String]

    public init(english: String, korean: String, heardAs: [String] = []) {
        self.english = english
        self.korean = korean
        self.heardAs = heardAs
    }
}

/// A plain-text glossary kept on this Mac. It is never inferred, downloaded or
/// bundled, and only the spellings its owner listed are ever replaced.
///
///     # english = 한국어 | heard as, heard as
///     recall = 재현율
///     OpenShift | open shift
public struct CaptionGlossary: Equatable, Sendable {
    public static let entryLimit = 300
    public static let termLengthLimit = 80
    public static let heardAsLimit = 8
    public static let empty = CaptionGlossary(text: "")

    public let entries: [GlossaryEntry]
    // Longest spellings first, so a longer listed phrase wins over a shorter one.
    private let corrections: [(heardAs: String, entry: Int)]

    public init(text: String) {
        var parsed: [GlossaryEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard parsed.count < Self.entryLimit else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let halves = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let pair = halves[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let english = pair[0].trimmingCharacters(in: .whitespaces)
            // A name without a translation is kept as it is in both languages.
            let korean = pair.count > 1 ? pair[1].trimmingCharacters(in: .whitespaces) : english
            guard Self.isTerm(english), Self.isTerm(korean) else { continue }
            let heardAs = halves.count > 1 ? halves[1].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { Self.isTerm($0) && $0.caseInsensitiveCompare(english) != .orderedSame && $0 != korean } : []
            parsed.append(GlossaryEntry(english: english, korean: korean, heardAs: Array(heardAs.prefix(Self.heardAsLimit))))
        }
        entries = parsed
        corrections = parsed.enumerated()
            .flatMap { index, entry in entry.heardAs.map { (heardAs: $0, entry: index) } }
            .sorted { $0.heardAs.count > $1.heardAs.count }
    }

    public static func == (a: CaptionGlossary, b: CaptionGlossary) -> Bool { a.entries == b.entries }

    private static func isTerm(_ text: String) -> Bool { !text.isEmpty && text.count <= termLengthLimit }

    /// Replaces the listed misrecognitions with the term in the spoken
    /// language. Text the owner did not list is returned unchanged.
    public func correcting(_ source: String, direction: CaptionDirection) -> String {
        guard !corrections.isEmpty else { return source }
        var text = source
        for correction in corrections {
            let entry = entries[correction.entry]
            let term = direction == .englishToKorean ? entry.english : entry.korean
            // Latin spellings must end at a word boundary. A Korean spelling
            // can be followed directly by a particle.
            let endsInLatin = correction.heardAs.unicodeScalars.last.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) } ?? false
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: correction.heardAs)
                + (endsInLatin ? "(?![\\p{L}\\p{N}])" : "")
            text = text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: term),
                                             options: .regularExpression)
        }
        return text
    }
}
