import Foundation

var timeline = CaptionTimeline()
let first = timeline.accept(source: "The server failed.", audioStart: 0, audioEnd: 1, isFinal: true)!
_ = timeline.apply(translation: "서버가 실패했습니다.", for: first)
let before = timeline.segments[0]
let overwritten = timeline.apply(translation: "서버가 성공했습니다.", for: first)
print("FINAL_REAPPLY accepted=\(overwritten), changed=\(before != timeline.segments[0]), final=\(timeline.segments[0].isFinal)")

timeline.direction = .koreanToEnglish
let second = timeline.accept(source: "서버를 복구합니다.", audioStart: 1, audioEnd: 2, isFinal: true)!
_ = timeline.apply(translation: "Restore the server.", for: second)
if let context = timeline.contextJob(endingAt: second.segmentID) {
    print("MIXED_CONTEXT admitted=\(context.source)")
    _ = timeline.applyContext(translation: "Combined Korean and English output", for: context)
    print(timeline.exportText())
}

var huge = CaptionTimeline()
let large = huge.accept(source: "Malformed range", audioStart: Double.greatestFiniteMagnitude, audioEnd: Double.greatestFiniteMagnitude, isFinal: true)
print("HUGE_TIME_ACCEPTED=\(large != nil)")
if CommandLine.arguments.contains("--crash-export") { print(huge.exportText()) }
