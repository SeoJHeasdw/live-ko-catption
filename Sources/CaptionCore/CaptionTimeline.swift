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
    /// Display groups preserve their individual ASR records in `segments`.
    public var contextSegmentCount: Int
    /// Display-only state while a recent final passage is being reconsidered.
    public var contextIsPending: Bool

    /// An ASR-final result stays provisional until its exact revision is translated.
    public var isFinal: Bool {
        sourceIsFinal && translatedRevision == revision && translationError == nil && !contextIsPending &&
            !(translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public init(id: UUID = UUID(), revision: Int = 1, source: String,
                translation: String? = nil, sourceIsFinal: Bool = false,
                translatedRevision: Int? = nil, translationError: String? = nil,
                audioStart: Double, audioEnd: Double, contextSegmentCount: Int = 1,
                contextIsPending: Bool = false) {
        self.id = id
        self.revision = revision
        self.source = source
        self.translation = translation
        self.sourceIsFinal = sourceIsFinal
        self.translatedRevision = translatedRevision
        self.translationError = translationError
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.contextSegmentCount = contextSegmentCount
        self.contextIsPending = contextIsPending
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

/// Apple Translation accepts text, not a separate context prompt. Translating a
/// small complete passage lets it reconsider earlier Korean without attempting
/// to split reordered Korean clauses back into arbitrary ASR chunks.
public struct ContextTranslationJob: Equatable, Sendable {
    public let members: [TranslationJob]
    public let contextRevision: Int
    public var source: String { members.map(\.source).joined(separator: " ") }
    public var endingSegmentID: UUID? { members.last?.segmentID }

    public init(members: [TranslationJob], contextRevision: Int) {
        self.members = members
        self.contextRevision = contextRevision
    }
}

public struct CaptionTimeline: Sendable {
    private struct ContextGroup: Sendable {
        let members: [TranslationJob]
        let translation: String
    }

    public private(set) var segments: [CaptionSegment] = []
    private var contextGroups: [ContextGroup] = []
    private var contextRevision = 0
    private var contextBoundary: Set<UUID> = []
    public init() {}

    @discardableResult
    public mutating func accept(source: String, audioStart: Double,
                                audioEnd: Double, isFinal: Bool,
                                requireFinalTranslation: Bool = false) -> TranslationJob? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, audioStart.isFinite, audioEnd.isFinite,
              audioStart >= 0, audioEnd >= audioStart else { return nil }

        // ASR-final audio cannot be reopened by a delayed result with a shifted
        // start time. Without word-level ranges, trimming its overlapping text
        // would invent an alignment, so retain the already accepted final source.
        if segments.contains(where: {
            $0.sourceIsFinal && (
                abs($0.audioStart - audioStart) < 0.015 ||
                min($0.audioEnd, audioEnd) > max($0.audioStart, audioStart) + 0.015
            )
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
            if isFinal, requireFinalTranslation,
               segments[index].translatedRevision == segments[index].revision {
                // Keep the readable draft, but wait for the final-only stage.
                segments[index].translatedRevision = nil
            }
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
        if isFinal { contextRevision += 1 }
        guard let currentIndex = segments.firstIndex(where: { $0.id == id }) else { return nil }
        // The common live update stays at the tail. Sorting session history on
        // every volatile result becomes unnecessary work as a talk gets longer.
        if (currentIndex > 0 && segments[currentIndex - 1].audioStart > segments[currentIndex].audioStart) ||
            (currentIndex + 1 < segments.count && segments[currentIndex + 1].audioStart < segments[currentIndex].audioStart) {
            segments.sort { $0.audioStart < $1.audioStart }
            // A late disjoint result can fill the gap inside an accepted passage.
            // Its aggregate Korean no longer describes consecutive sources; use
            // their valid individual translations and keep unrelated groups.
            let indicesByID = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($0.element.id, $0.offset) })
            contextGroups.removeAll { group in
                let positions = group.members.compactMap { indicesByID[$0.segmentID] }
                return positions.count != group.members.count ||
                    zip(positions, positions.dropFirst()).contains { previous, next in next != previous + 1 }
            }
        }
        guard let segment = segments.first(where: { $0.id == id }) else { return nil }
        // A provisional translation can become final without another translation
        // if the recognizer confirms the exact same text.
        guard segment.translatedRevision != segment.revision else { return nil }
        return job(for: segment)
    }

    public func isCurrent(_ job: TranslationJob) -> Bool {
        segments.contains {
            $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source
        }
    }

    public func needsTranslation(_ job: TranslationJob) -> Bool {
        segments.contains {
            $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source &&
                $0.translatedRevision != job.revision
        }
    }

    /// A fast result can be read while an optional final-only refinement runs.
    /// It never finalizes or reopens an already finalized revision.
    @discardableResult
    public mutating func preview(translation: String, for job: TranslationJob) -> Bool {
        guard job.isSourceFinal, needsTranslation(job), let index = segments.firstIndex(where: {
            $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source
        }), segments[index].sourceIsFinal else { return false }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        segments[index].translation = text
        segments[index].translatedRevision = nil
        segments[index].translationError = nil
        return true
    }

    @discardableResult
    public mutating func apply(translation: String, for job: TranslationJob) -> Bool {
        guard let index = segments.firstIndex(where: {
            $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source
        }) else { return false }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        segments[index].translation = text
        segments[index].translatedRevision = job.revision
        segments[index].translationError = nil
        return true
    }

    public mutating func fail(_ job: TranslationJob, message: String) {
        guard needsTranslation(job), let index = segments.firstIndex(where: {
            $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source
        }) else { return }
        segments[index].translationError = message
    }

    /// A pause/new run must not silently join two separate conversations.
    public mutating func resetContext() {
        contextBoundary.formUnion(segments.map(\.id))
        contextRevision += 1
    }

    /// Only a recent, fully translated final passage can be reconsidered. Extend
    /// a pair up to four ASR chunks, then freeze it so older captions do not keep changing.
    public func contextJob(endingAt segmentID: UUID) -> ContextTranslationJob? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }),
              index > 0, segments[index].isFinal,
              !contextBoundary.contains(segmentID),
              !segments.dropFirst(index + 1).contains(where: \.sourceIsFinal) else { return nil }
        if contextGroups.contains(where: { $0.members.last?.segmentID == segmentID }) { return nil }

        let preceding = segments[index - 1]
        guard preceding.isFinal, !contextBoundary.contains(preceding.id) else { return nil }
        var members: [CaptionSegment]
        if let group = contextGroups.first(where: { $0.members.last?.segmentID == preceding.id }) {
            guard group.members.count < 4 else { return nil }
            let ids = Set(group.members.map(\.segmentID))
            members = segments.filter { ids.contains($0.id) }
        } else {
            // A segment already inside an older group must never be detached
            // from that group's aggregate Korean translation.
            guard !contextGroups.contains(where: { $0.members.contains(where: { $0.segmentID == preceding.id }) }) else {
                return nil
            }
            members = [preceding]
        }
        members.append(segments[index])
        guard members.count >= 2, members.count <= 4, members.allSatisfy(\.isFinal),
              let first = members.first, let last = members.last,
              last.audioEnd - first.audioStart <= 12,
              members.map(\.source).joined(separator: " ").count <= 500,
              zip(members, members.dropFirst()).allSatisfy({ previous, next in
                  next.audioStart - previous.audioEnd <= 2
              }) else { return nil }
        return ContextTranslationJob(members: members.map { job(for: $0) }, contextRevision: contextRevision)
    }

    public func needsContextTranslation(_ job: ContextTranslationJob) -> Bool {
        guard job.members.count >= 2, job.members.count <= 4,
              job.contextRevision == contextRevision,
              let last = job.members.last,
              let current = contextJob(endingAt: last.segmentID) else { return false }
        return current == job
    }

    @discardableResult
    public mutating func applyContext(translation: String, for job: ContextTranslationJob) -> Bool {
        guard needsContextTranslation(job) else { return false }
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let ids = Set(job.members.map(\.segmentID))
        contextGroups.removeAll { group in group.members.contains { ids.contains($0.segmentID) } }
        contextGroups.append(ContextGroup(members: job.members, translation: text))
        return true
    }

    /// Caption rows may combine a small passage; ASR sources and timestamps in
    /// `segments` stay unchanged and can still be inspected or validated.
    public var displaySegments: [CaptionSegment] {
        makeDisplaySegments(from: segments[...])
    }

    public var displaySegmentCount: Int {
        segments.count - contextGroups.reduce(0) { $0 + $1.members.count - 1 }
    }

    /// Live rendering only needs a bounded suffix. Align the first raw member
    /// with its context group so a window boundary cannot expose old isolated
    /// Korean in place of the accepted aggregate translation.
    public func recentDisplaySegments(limit: Int = 100) -> [CaptionSegment] {
        guard limit > 0, !segments.isEmpty else { return [] }
        var start = max(0, segments.count - min(segments.count, limit > Int.max / 4 ? segments.count : limit * 4))
        let firstID = segments[start].id
        if let group = contextGroups.first(where: { $0.members.contains { $0.segmentID == firstID } }),
           let leadingID = group.members.first?.segmentID,
           let leadingIndex = segments.firstIndex(where: { $0.id == leadingID }) { start = leadingIndex }
        return Array(makeDisplaySegments(from: segments[start...]).suffix(limit))
    }

    private func makeDisplaySegments(from visible: ArraySlice<CaptionSegment>) -> [CaptionSegment] {
        let segmentsByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let groups: [UUID: ContextGroup] = Dictionary(uniqueKeysWithValues: contextGroups.compactMap { group in
            guard let first = group.members.first, segmentsByID[first.segmentID] != nil else { return nil }
            return (first.segmentID, group)
        })
        let groupedIDs = Set(groups.values.flatMap { $0.members.dropFirst().map(\.segmentID) })
        return visible.compactMap { segment in
            guard !groupedIDs.contains(segment.id) else { return nil }
            guard let group = groups[segment.id],
                  let lastID = group.members.last?.segmentID,
                  let last = segmentsByID[lastID] else { return segment }
            var display = segment
            display.source = group.members.map(\.source).joined(separator: " ")
            display.translation = group.translation
            display.audioEnd = last.audioEnd
            display.contextSegmentCount = group.members.count
            return display
        }
    }

    public var endTime: Double { segments.map(\.audioEnd).max() ?? 0 }

    public func exportText(createdAt: Date = Date(), sourceLabel: String = "EN",
                           targetLabel: String = "KO") -> String {
        let date = ISO8601DateFormatter().string(from: createdAt)
        let rows = displaySegments.map { segment in
            let stamp = String(format: "%02d:%02d", Int(segment.audioStart) / 60,
                               Int(segment.audioStart) % 60)
            let state = segment.isFinal ? "확정" : "미확정"
            return "[\(stamp) · \(state)]\n\(sourceLabel): \(segment.source)\n\(targetLabel): \(segment.translation ?? "번역 없음")"
        }
        return "Live Korean Captions\n\(date)\n\n" + rows.joined(separator: "\n\n") + "\n"
    }

    private func job(for segment: CaptionSegment) -> TranslationJob {
        TranslationJob(segmentID: segment.id, revision: segment.revision,
                       source: segment.source, isSourceFinal: segment.sourceIsFinal)
    }
}
