import CaptionCore
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
func job(_ id: UUID = UUID(), revision: Int = 1, final: Bool = false) -> TranslationJob {
    TranslationJob(segmentID: id, revision: revision, source: "revision \(revision)", isSourceFinal: final)
}

var queue = TranslationQueue(draftLimit: 3)
let firstID = UUID()
for revision in 1...1000 { queue.enqueue(job(firstID, revision: revision)) }
expect(queue.count == 1, "Partial burst must coalesce")
let final = job(firstID, revision: 1001, final: true)
queue.enqueue(final)
queue.enqueue(job())
expect(queue.next(allowDraft: true) == final, "Final must preempt draft cooldown")
queue.removeAll()
let oldest = job(), newest = job()
queue.enqueue(oldest); queue.enqueue(newest)
expect(queue.next(allowDraft: true) == newest, "Latest speech must not be scheduled by random UUID order")
expect(queue.next(allowDraft: false) == nil, "Cooldown must hold provisional work")
for _ in 0..<1000 { queue.enqueue(job()) }
expect(queue.count == 3, "Draft replacement must have a hard queue bound")
queue.removeAll()
let finalID = UUID()
queue.enqueue(job(finalID, final: true))
queue.enqueue(job(finalID, revision: 2))
expect(queue.count == 1 && queue.hasFinals, "Late draft must not undo final priority")
queue.removeAll()
var timeline = CaptionTimeline()
let prior = timeline.accept(source: "We can", audioStart: 0, audioEnd: 1, isFinal: false)!
let latest = timeline.accept(source: "We cannot", audioStart: 0, audioEnd: 2, isFinal: false)!
queue.enqueue(prior); queue.prune(using: timeline)
expect(queue.count == 0, "Stale source revisions must be pruned before translation")
queue.enqueue(latest)
timeline.apply(translation: "할 수 없습니다", for: latest)
queue.prune(using: timeline)
expect(queue.count == 0, "An in-flight translation must make duplicate final/draft work unnecessary")
print("7 translation scheduling checks passed.")
