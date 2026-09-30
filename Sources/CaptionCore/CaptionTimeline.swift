import Foundation

public struct CaptionSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var revision: Int
    public var source: String
    public var translation: String?
    public var sourceIsFinal: Bool
    public var translatedRevision: Int?
    public var translationError: String?
    public var audioStart: Double
    public var audioEnd: Double

    /// An ASR-final result stays provisional until its exact revision is translated.
    public var isFinal: Bool {
        sourceIsFinal && translatedRevision == revision && translation != nil
    }

    public init(id: UUID = UUID(), revision: Int = 1, source: String,
                translation: String? = nil, sourceIsFinal: Bool = false,
                translatedRevision: Int? = nil, translationError: String? = nil,
                audioStart: Double, audioEnd: Double) {
        self.id = id
        self.revision = revision
        self.source = source
        self.translation = translation
        self.sourceIsFinal = sourceIsFinal
        self.translatedRevision = translatedRevision
        self.translationError = translationError
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }
}

public struct TranslationJob: Equatable, Sendable {
    public let segmentID: UUID
    public let revision: Int
    public let source: String
    public let isSourceFinal: Bool

    public init(segmentID: UUID, revision: Int, source: String, isSourceFinal: Bool) {
        self.segmentID = segmentID
        self.revision = revision
        self.source = source
        self.isSourceFinal = isSourceFinal
    }
}

public struct CaptionTimeline: Sendable {
    public private(set) var segments: [CaptionSegment] = []
    public init() {}

    @discardableResult
    public mutating func accept(source: String, audioStart: Double,
                                audioEnd: Double, isFinal: Bool) -> TranslationJob? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, audioStart.isFinite, audioEnd.isFinite,
              audioEnd >= audioStart else { return nil }

        // A finalized prefix must never be reopened by a late provisional event.
        if segments.contains(where: {
            $0.sourceIsFinal && abs($0.audioStart - audioStart) < 0.015
        }) { return nil }

        let matching = segments.indices.filter { index in
            let segment = segments[index]
            return !segment.sourceIsFinal && (
                abs(segment.audioStart - audioStart) < 0.015 ||
                min(segment.audioEnd, audioEnd) > max(segment.audioStart, audioStart) + 0.005
            )
        }

        let id: UUID
        if let index = matching.first {
            // Range boundaries can change as the recognizer revises its hypothesis.
            id = segments[index].id
            if segments[index].source != text {
                segments[index].revision += 1
                segments[index].source = text
                segments[index].translationError = nil
            }
            segments[index].sourceIsFinal = isFinal
            segments[index].audioStart = audioStart
            segments[index].audioEnd = audioEnd
            for duplicate in matching.dropFirst().reversed() {
                segments.remove(at: duplicate)
            }
        } else {
            let segment = CaptionSegment(source: text, sourceIsFinal: isFinal,
                                         audioStart: audioStart, audioEnd: audioEnd)
            id = segment.id
            segments.append(segment)
        }
        segments.sort { $0.audioStart < $1.audioStart }
        guard let segment = segments.first(where: { $0.id == id }) else { return nil }
        // A provisional translation can become final without another translation
        // if the recognizer confirms the exact same text.
        guard segment.translatedRevision != segment.revision else { return nil }
        return TranslationJob(segmentID: segment.id, revision: segment.revision,
                              source: segment.source, isSourceFinal: segment.sourceIsFinal)
    }

    public func isCurrent(_ job: TranslationJob) -> Bool {
        segments.contains { $0.id == job.segmentID && $0.revision == job.revision }
    }

    public func needsTranslation(_ job: TranslationJob) -> Bool {
        segments.contains {
            $0.id == job.segmentID && $0.revision == job.revision && $0.translatedRevision != job.revision
        }
    }

    @discardableResult
    public mutating func apply(translation: String, for job: TranslationJob) -> Bool {
        guard let index = segments.firstIndex(where: {
            $0.id == job.segmentID && $0.revision == job.revision
        }) else { return false }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        segments[index].translation = text
        segments[index].translatedRevision = job.revision
        segments[index].translationError = nil
        return true
    }

    public mutating func fail(_ job: TranslationJob, message: String) {
        guard let index = segments.firstIndex(where: {
            $0.id == job.segmentID && $0.revision == job.revision
        }) else { return }
        segments[index].translationError = message
    }

    public var endTime: Double { segments.map(\.audioEnd).max() ?? 0 }

    public func exportText(createdAt: Date = Date()) -> String {
        let date = ISO8601DateFormatter().string(from: createdAt)
        let rows = segments.map { segment in
            let stamp = String(format: "%02d:%02d", Int(segment.audioStart) / 60,
                               Int(segment.audioStart) % 60)
            let state = segment.isFinal ? "확정" : "미확정"
            return "[\(stamp) · \(state)]\nEN: \(segment.source)\nKO: \(segment.translation ?? "번역 없음")"
        }
        return "Live Korean Captions\n\(date)\n\n" + rows.joined(separator: "\n\n") + "\n"
    }
}
