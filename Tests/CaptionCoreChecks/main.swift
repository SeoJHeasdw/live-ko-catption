import CaptionCore
import Foundation

// No XCTest or Swift Testing dependency: these checks run with Command Line Tools.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

func require(_ job: TranslationJob?) throws -> TranslationJob {
    guard let job else { throw CheckFailure(description: "Expected a translation job") }
    return job
}

let checks: [(String, () throws -> Void)] = [
    ("late translation cannot overwrite a revised sentence", {
        var timeline = CaptionTimeline()
        let old = try require(timeline.accept(source: "We can", audioStart: 0, audioEnd: 1, isFinal: false))
        let current = try require(timeline.accept(source: "We cannot proceed", audioStart: 0, audioEnd: 2, isFinal: false))
        try expect(!timeline.apply(translation: "진행할 수 있습니다", for: old), "Stale revision accepted")
        try expect(timeline.apply(translation: "진행할 수 없습니다", for: current), "Current revision rejected")
        try expect(timeline.segments.count == 1, "Revision duplicated a row")
        try expect(timeline.segments[0].translation == "진행할 수 없습니다", "Wrong translation displayed")
        try expect(!timeline.segments[0].isFinal, "Draft marked final")
    }),
    ("final source waits for a matching translation", {
        var timeline = CaptionTimeline()
        let draft = try require(timeline.accept(source: "The price is fifteen", audioStart: 0, audioEnd: 2, isFinal: false))
        timeline.apply(translation: "가격은 15입니다", for: draft)
        let final = try require(timeline.accept(source: "The price is fifty.", audioStart: 0, audioEnd: 3, isFinal: true))
        try expect(!timeline.segments[0].isFinal, "Old translation finalized new source")
        try expect(!timeline.apply(translation: "가격은 15입니다", for: draft), "Old draft overwrote final source")
        timeline.apply(translation: "가격은 50입니다.", for: final)
        try expect(timeline.segments[0].isFinal, "Matching final translation stayed draft")
        try expect(timeline.accept(source: "The price is", audioStart: 0, audioEnd: 1, isFinal: false) == nil, "Final source reopened")
        try expect(timeline.segments[0].source == "The price is fifty.", "Final source mutated")
    }),
    ("confirming an unchanged draft avoids duplicate translation", {
        var timeline = CaptionTimeline()
        let draft = try require(timeline.accept(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: false))
        timeline.apply(translation: "안녕하세요.", for: draft)
        try expect(timeline.accept(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: true) == nil, "Unnecessary repeat translation")
        try expect(timeline.segments[0].isFinal, "Confirmed draft stayed provisional")
    }),
    ("a queued final job skips a draft translation completed in flight", {
        var timeline = CaptionTimeline()
        let draft = try require(timeline.accept(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: false))
        let final = try require(timeline.accept(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: true))
        timeline.apply(translation: "안녕하세요.", for: draft)
        try expect(timeline.segments[0].isFinal, "In-flight translation failed to finalize matching source")
        try expect(!timeline.needsTranslation(final), "Queued final job repeated an in-flight translation")
    }),
    ("revised audio ranges preserve an already final prefix", {
        var timeline = CaptionTimeline()
        let prefix = try require(timeline.accept(source: "Welcome.", audioStart: 0, audioEnd: 1, isFinal: true))
        timeline.apply(translation: "환영합니다.", for: prefix)
        _ = timeline.accept(source: "Let's", audioStart: 1.1, audioEnd: 2, isFinal: false)
        let next = try require(timeline.accept(source: "Let's get started.", audioStart: 1.12, audioEnd: 3, isFinal: true))
        timeline.apply(translation: "시작하겠습니다.", for: next)
        try expect(timeline.segments.count == 2, "Revised range duplicated a draft")
        try expect(timeline.segments[0].translation == "환영합니다.", "Final prefix replaced")
        try expect(timeline.segments.allSatisfy(\.isFinal), "Completed captions stayed gray")
    }),
    ("exports identify unfinished translations", {
        var timeline = CaptionTimeline()
        _ = timeline.accept(source: "Still speaking", audioStart: 65, audioEnd: 66, isFinal: false)
        let exported = timeline.exportText()
        try expect(exported.contains("[01:05 · 미확정]"), "Export hides provisional status")
        try expect(exported.contains("KO: 번역 없음"), "Missing translation misrepresented")
    })
]

do {
    for (name, check) in checks {
        try check()
        print("PASS: \(name)")
    }
    print("\(checks.count) caption checks passed.")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
