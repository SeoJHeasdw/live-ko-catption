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

/// A rejected expansion preserves the original ASR source and can be reported
/// by the app without silently trimming or partially correcting the sentence.
public struct GlossaryCorrectionResult: Equatable, Sendable {
    public let text: String
    public let exceededByteLimit: Bool
}

/// Explicit term pairs and listed ASR aliases. Personal files stay on this Mac;
/// public translation dictionaries use the same parser without ASR aliases.
/// Only the spellings the owner listed are eligible for source correction.
///
///     # english = 한국어 | heard as, heard as
///     recall = 재현율
///     OpenShift | open shift
public struct CaptionGlossary: Equatable, Sendable {
    public static let entryLimit = 300
    public static let termLengthLimit = 80
    public static let termScalarLimit = 1_024
    public static let termByteLimit = 4_096
    public static let heardAsLimit = 8
    public static let correctedSourceByteLimit = 65_536
    public static let empty = CaptionGlossary(text: "")

    public let entries: [GlossaryEntry]
    // Longest spellings first, so a longer listed phrase wins over a shorter one.
    private let corrections: [(heardAs: String, key: String, entry: Int)]
    /// Each edge keeps its shared substring compressed. The flat value array
    /// grows with aliases and branches, not with every character of every alias.
    private struct CorrectionNode: Sendable {
        var label: String
        var children: [Character: Int] = [:]
        var terminal: Int?
    }
    private let correctionNodes: [CorrectionNode]

    public init(text: String) {
        var parsed: [GlossaryEntry] = []
        for line in text.split(whereSeparator: Self.isFileLineBreak) {
            guard parsed.count < Self.entryLimit else { break }
            // A control token can contain the file's own `|` delimiter. Reject
            // the whole malformed row before parsing it into misleading fields.
            guard !Self.containsDisallowedControls(String(line)),
                  !Self.containsModelControlMarkers(String(line)) else { continue }
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
        self.init(entries: parsed)
    }

    public init(entries: [GlossaryEntry]) {
        let parsed = entries.filter { Self.isTerm($0.english) && Self.isTerm($0.korean) }.map {
            GlossaryEntry(english: $0.english, korean: $0.korean,
                heardAs: Array($0.heardAs.filter(Self.isTerm).prefix(Self.heardAsLimit)))
        }
        self.entries = parsed
        corrections = parsed.enumerated()
            .flatMap { index, entry in entry.heardAs.map { (heardAs: $0, key: $0.lowercased(), entry: index) } }
            .sorted { $0.heardAs.count > $1.heardAs.count }
        correctionNodes = Self.indexAliases(corrections.map(\.key))
    }

    public static func == (a: CaptionGlossary, b: CaptionGlossary) -> Bool { a.entries == b.entries }

    static func isFileLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    /// Grapheme limits alone permit one character to contain thousands of
    /// combining scalars. Keep ordinary accents and joined emoji, but bound the
    /// bytes and scalars that actually reach the recognizer and model APIs.
    private static func isTerm(_ text: String) -> Bool {
        isSafeField(text, characterLimit: termLengthLimit, scalarLimit: termScalarLimit,
                    byteLimit: termByteLimit)
    }

    static func isSafeField(_ text: String, characterLimit: Int, scalarLimit: Int,
                            byteLimit: Int, allowsEmpty: Bool = false) -> Bool {
        guard allowsEmpty || !text.isEmpty,
              text.utf8.count <= byteLimit, text.unicodeScalars.count <= scalarLimit,
              text.count <= characterLimit, !containsDisallowedControls(text) else { return false }
        return !containsModelControlMarkers(text)
    }

    static func containsModelControlMarkers(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("<｜hy_") || lowered.contains("<|")
    }

    /// C0/C1 controls include NUL, which terminates the native C prompt early.
    /// Do not use CharacterSet.controlCharacters: it also includes the ZWJ
    /// needed by ordinary joined emoji. Prompt callers may permit whitespace.
    public static func containsDisallowedControls(_ text: String, allowsLineBreaks: Bool = false) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if allowsLineBreaks && (value == 9 || value == 10 || value == 13) { return false }
            return value < 0x20 || (0x7F...0x9F).contains(value) ||
                (!allowsLineBreaks && (value == 0x2028 || value == 0x2029))
        }
    }

    private static func indexAliases(_ keys: [String]) -> [CorrectionNode] {
        var nodes = [CorrectionNode(label: "")]
        nodes.reserveCapacity(keys.count * 2 + 1)
        for (correctionIndex, key) in keys.enumerated() {
            var remaining = key[...]
            var parent = 0
            while let first = remaining.first {
                guard let child = nodes[parent].children[first] else {
                    let leaf = nodes.count
                    nodes.append(CorrectionNode(label: String(remaining), terminal: correctionIndex))
                    nodes[parent].children[first] = leaf
                    break
                }
                let label = nodes[child].label
                var labelEnd = label.startIndex
                var inputEnd = remaining.startIndex
                while labelEnd < label.endIndex, inputEnd < remaining.endIndex,
                      label[labelEnd] == remaining[inputEnd] {
                    labelEnd = label.index(after: labelEnd)
                    inputEnd = remaining.index(after: inputEnd)
                }
                if labelEnd == label.endIndex {
                    remaining = remaining[inputEnd...]
                    if remaining.isEmpty {
                        // Duplicate normalized aliases use the first correction,
                        // matching the existing longest-first replacement order.
                        if nodes[child].terminal == nil { nodes[child].terminal = correctionIndex }
                        break
                    }
                    parent = child
                    continue
                }
                // Split only at a real branch or the end of a shorter alias.
                // Both suffix edges remain compressed rather than becoming
                // one node per character.
                let shared = String(label[..<labelEnd])
                let oldSuffix = String(label[labelEnd...])
                let newSuffix = remaining[inputEnd...]
                nodes[child].label = oldSuffix
                let branch = nodes.count
                nodes.append(CorrectionNode(label: shared,
                    children: [oldSuffix.first!: child], terminal: newSuffix.isEmpty ? correctionIndex : nil))
                nodes[parent].children[first] = branch
                if let newFirst = newSuffix.first {
                    let leaf = nodes.count
                    nodes.append(CorrectionNode(label: String(newSuffix), terminal: correctionIndex))
                    nodes[branch].children[newFirst] = leaf
                }
                break
            }
        }
        return nodes
    }

    /// Replaces the listed misrecognitions with the term in the spoken
    /// language. Text the owner did not list is returned unchanged.
    public func correcting(_ source: String, direction: CaptionDirection) -> String {
        correctionResult(source, direction: direction).text
    }

    public func correctionResult(_ source: String, direction: CaptionDirection) -> GlossaryCorrectionResult {
        func unchanged(limited: Bool = false) -> GlossaryCorrectionResult {
            GlossaryCorrectionResult(text: source, exceededByteLimit: limited)
        }
        guard !corrections.isEmpty else { return unchanged() }
        let originalByteCount = source.utf8.count
        guard originalByteCount <= Self.correctedSourceByteLimit else { return unchanged(limited: true) }
        // Follow actual source text through compressed edges. Sharing a common
        // prefix with thousands of aliases never admits those aliases unless
        // their complete spelling is present in this partial.
        let lowered = source.lowercased()
        var candidates = Set<Int>()
        for start in lowered.indices {
            var position = start
            var parent = 0
            while position < lowered.endIndex,
                  let child = correctionNodes[parent].children[lowered[position]] {
                let label = correctionNodes[child].label
                var labelPosition = label.startIndex
                var next = position
                while labelPosition < label.endIndex, next < lowered.endIndex,
                      label[labelPosition] == lowered[next] {
                    labelPosition = label.index(after: labelPosition)
                    next = lowered.index(after: next)
                }
                guard labelPosition == label.endIndex else { break }
                position = next
                if let terminal = correctionNodes[child].terminal { candidates.insert(terminal) }
                parent = child
            }
        }
        var replacements: [String: String] = [:]
        var patterns: [String] = []
        for index in candidates.sorted() {
            let correction = corrections[index]
            guard replacements[correction.key] == nil else { continue }
            let entry = entries[correction.entry]
            replacements[correction.key] = direction == .englishToKorean ? entry.english : entry.korean
            // Latin spellings must end at a word boundary. A Korean spelling
            // can be followed directly by a particle.
            let endsInLatin = correction.heardAs.unicodeScalars.last.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) } ?? false
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: correction.heardAs)
                + (endsInLatin ? "(?![\\p{L}\\p{N}])" : "")
            patterns.append(pattern)
        }
        guard !patterns.isEmpty,
              let expression = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive) else { return unchanged() }
        // Match the original once. Inserted canonical spellings cannot cascade
        // into a second dictionary's alias. Longest alternatives take priority.
        let original = source as NSString
        let changes = expression.matches(in: source, range: NSRange(location: 0, length: original.length)).compactMap { match -> (NSRange, String)? in
            let matched = original.substring(with: match.range)
            guard let term = replacements[matched.lowercased()] else { return nil }
            return (match.range, term)
        }
        guard !changes.isEmpty else { return unchanged() }
        let finalByteCount = changes.reduce(originalByteCount) { count, change in
            count + change.1.utf8.count - original.substring(with: change.0).utf8.count
        }
        guard finalByteCount <= Self.correctedSourceByteLimit else { return unchanged(limited: true) }
        // Preflight before allocating expanded text, then construct it once in
        // source order. No intermediate expansion or cascaded substitution.
        var text = ""
        text.reserveCapacity(finalByteCount)
        var position = 0
        for (range, term) in changes {
            text += original.substring(with: NSRange(location: position, length: range.location - position))
            text += term
            position = NSMaxRange(range)
        }
        text += original.substring(from: position)
        return GlossaryCorrectionResult(text: text, exceededByteLimit: false)
    }
}
