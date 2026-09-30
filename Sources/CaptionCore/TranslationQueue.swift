import Foundation

/// Final source revisions are never discarded. Drafts coalesce by segment and
/// can be evicted because a later source-final event queues the definitive job.
public struct TranslationQueue: Sendable {
    private var finals: [TranslationJob] = []
    private var drafts: [TranslationJob] = []
    public let draftLimit: Int
    public init(draftLimit: Int = 8) { self.draftLimit = max(1, draftLimit) }
    public var count: Int { finals.count + drafts.count }
    public var finalCount: Int { finals.count }
    public var hasFinals: Bool { !finals.isEmpty }

    public mutating func enqueue(_ job: TranslationJob) {
        if job.isSourceFinal {
            drafts.removeAll { $0.segmentID == job.segmentID }
            finals.removeAll { $0.segmentID == job.segmentID }
            finals.append(job)
        } else {
            guard !finals.contains(where: { $0.segmentID == job.segmentID }) else { return }
            drafts.removeAll { $0.segmentID == job.segmentID }
            drafts.append(job)
            if drafts.count > draftLimit { drafts.removeFirst(drafts.count - draftLimit) }
        }
    }

    public mutating func prune(using timeline: CaptionTimeline) {
        finals.removeAll { !timeline.needsTranslation($0) }
        drafts.removeAll { !timeline.needsTranslation($0) }
    }

    public mutating func next(allowDraft: Bool) -> TranslationJob? {
        if !finals.isEmpty { return finals.removeFirst() }
        // Newest live speech is most useful when the recognizer splits/replaces
        // volatile ranges. UUID ordering has no relationship to speech order.
        if allowDraft, !drafts.isEmpty { return drafts.removeLast() }
        return nil
    }

    public mutating func removeAll() { finals.removeAll(); drafts.removeAll() }
}
