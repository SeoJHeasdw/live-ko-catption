import Foundation

struct RNG {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(bound))
    }
}

@main struct PropertyProbe {
    static func main() {
        var checks = 0
        var accepted = 0
        for seed in 1...100 {
            var rng = RNG(state: UInt64(seed))
            var timeline = CaptionTimeline()
            var queue = TranslationQueue(draftLimit: 4)
            var jobs: [TranslationJob] = []
            var contexts: [ContextTranslationJob] = []
            var frozen: [UUID: CaptionSegment] = [:]
            for step in 0..<1000 {
                switch rng.next(10) {
                case 0...5:
                    let start = Double(rng.next(4000)) / 10
                    let end = start + Double(rng.next(60)) / 10
                    let final = rng.next(3) == 0
                    if let job = timeline.accept(source: "seed\(seed) step\(step)", audioStart: start, audioEnd: end, isFinal: final) {
                        jobs.append(job)
                        queue.prune(using: timeline)
                        queue.enqueue(job)
                        accepted += 1
                    }
                case 6:
                    queue.prune(using: timeline)
                    if let job = queue.next(allowDraft: true) {
                        precondition(timeline.needsTranslation(job), "Queue returned stale revision")
                        _ = timeline.apply(translation: "T: " + job.source, for: job)
                    }
                case 7:
                    if !jobs.isEmpty {
                        let job = jobs[rng.next(jobs.count)]
                        if timeline.needsTranslation(job) { _ = timeline.apply(translation: "T: " + job.source, for: job) }
                        else if !timeline.isCurrent(job) {
                            let snapshot = timeline.segments
                            precondition(!timeline.apply(translation: "stale", for: job), "Stale job applied")
                            precondition(snapshot == timeline.segments, "Stale result mutated timeline")
                        }
                    }
                case 8:
                    if let ending = timeline.segments.last, let context = timeline.contextJob(endingAt: ending.id) {
                        contexts.append(context)
                        _ = timeline.applyContext(translation: "CT: " + context.source, for: context)
                    } else if !contexts.isEmpty {
                        let context = contexts[rng.next(contexts.count)]
                        let needed = timeline.needsContextTranslation(context)
                        let snapshot = timeline.displaySegments
                        let applied = timeline.applyContext(translation: "late context", for: context)
                        precondition(applied == needed, "Context applicability changed")
                        if !needed { precondition(snapshot == timeline.displaySegments, "Stale context mutated display") }
                    }
                default:
                    timeline.resetContext()
                    timeline.direction = timeline.direction == .englishToKorean ? .koreanToEnglish : .englishToKorean
                }
                for (id, old) in frozen {
                    guard let current = timeline.segments.first(where: { $0.id == id }) else { preconditionFailure("Final source disappeared") }
                    precondition(current == old, "Final source or exact translation changed")
                }
                for segment in timeline.segments where segment.isFinal { frozen[segment.id] = segment }
                precondition(zip(timeline.segments, timeline.segments.dropFirst()).allSatisfy { $0.audioStart <= $1.audioStart }, "Timeline is unsorted")
                let display = timeline.displaySegments
                precondition(display.count == timeline.displaySegmentCount, "Display count drift")
                precondition(display.reduce(0) { $0 + $1.contextSegmentCount } == timeline.segments.count, "Display lost or duplicated raw members")
                for limit in [0, 1, 2, 8, 100, Int.max] {
                    precondition(timeline.recentDisplaySegments(limit: limit) == Array(display.suffix(limit)), "Recent display disagrees with full suffix")
                }
                checks += 1
            }
        }
        print("PASS: \(checks) randomized timeline/queue transitions, \(accepted) accepted source revisions, 100 seeds; frozen-final, stale-job, stale-context, chronological-order, member-count and bounded-window properties.")
    }
}
