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

func appendFinal(_ timeline: inout CaptionTimeline, source: String, translation: String,
                 start: Double, end: Double) throws -> TranslationJob {
    let job = try require(timeline.accept(source: source, audioStart: start, audioEnd: end, isFinal: true))
    try expect(timeline.apply(translation: translation, for: job), "Final translation was rejected")
    return job
}

func requireContext(_ job: ContextTranslationJob?) throws -> ContextTranslationJob {
    guard let job else { throw CheckFailure(description: "Expected a context translation job") }
    return job
}

func checkLateContextGapInsertion(isFinal: Bool) throws {
    var timeline = CaptionTimeline()
    _ = try appendFinal(&timeline, source: "First.", translation: "첫째.", start: 0, end: 1)
    let second = try appendFinal(&timeline, source: "Second.", translation: "둘째.", start: 2, end: 3)
    let firstContext = try requireContext(timeline.contextJob(endingAt: second.segmentID))
    try expect(timeline.applyContext(translation: "이미 합친 첫째와 둘째.", for: firstContext),
        "Could not create the context group interrupted by late input")
    let firstRecords = timeline.segments

    // A separate accepted group must survive an insertion into the earlier gap.
    timeline.resetContext()
    _ = try appendFinal(&timeline, source: "Unrelated first.", translation: "별도 첫째.", start: 10, end: 11)
    let unrelatedEnd = try appendFinal(&timeline, source: "Unrelated second.", translation: "별도 둘째.", start: 11, end: 12)
    let unrelatedContext = try requireContext(timeline.contextJob(endingAt: unrelatedEnd.segmentID))
    try expect(timeline.applyContext(translation: "바뀌면 안 되는 별도 문맥.", for: unrelatedContext),
        "Could not create the unrelated context group")
    let stableUnrelated = try { () throws -> CaptionSegment in
        guard let row = timeline.displaySegments.last else { throw CheckFailure(description: "Missing unrelated group") }
        return row
    }()

    let inserted = try require(timeline.accept(source: "Inserted between.", audioStart: 1.1,
        audioEnd: 1.9, isFinal: isFinal))
    try expect(timeline.apply(translation: "중간에 들어온 구절.", for: inserted), "Late source translation was rejected")
    try expect(timeline.segments.map(\.source) == ["First.", "Inserted between.", "Second.",
        "Unrelated first.", "Unrelated second."], "Late input did not preserve chronological raw sources")
    try expect(timeline.segments.first == firstRecords[0] && timeline.segments[2] == firstRecords[1],
        "Late insertion changed existing final source revisions")
    try expect(timeline.displaySegments.last == stableUnrelated, "Late insertion changed an unrelated accepted context group")

    let expectedSources = ["First.", "Inserted between.", "Second.", "Unrelated first. Unrelated second."]
    let display = timeline.displaySegments
    try expect(display.map(\.source) == expectedSources,
        "An interrupted context group reordered the late source in display/export")
    try expect(display[0].isFinal && display[2].isFinal && display[1].isFinal == isFinal,
        "Invalidating context changed exact isolated final/provisional state")
    try expect(display[0].translation == "첫째." && display[2].translation == "둘째.",
        "Invalidating context discarded the valid isolated translations")
    try expect(timeline.displaySegmentCount == display.count, "Invalidated context left an incorrect history count")
    for limit in [1, 2, 3, 4] {
        try expect(timeline.recentDisplaySegments(limit: limit) == Array(display.suffix(limit)),
            "Bounded display retained the interrupted group at limit \(limit)")
    }
    let exported = timeline.exportText()
    try expect(!exported.contains("이미 합친 첫째와 둘째."), "Export retained an aggregate across the inserted source")
    guard let firstRange = exported.range(of: "EN: First.\n"),
          let insertedRange = exported.range(of: "EN: Inserted between.\n"),
          let secondRange = exported.range(of: "EN: Second.\n") else {
        throw CheckFailure(description: "Export omitted the isolated chronological sources after insertion")
    }
    try expect(firstRange.lowerBound < insertedRange.lowerBound && insertedRange.lowerBound < secondRange.lowerBound,
        "Export moved a late source after the later final source")
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
    ("shifted late ranges cannot duplicate or reopen a final caption", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "We cannot approve it.", translation: "승인할 수 없습니다.", start: 0, end: 2)
        try expect(timeline.accept(source: "We can approve it", audioStart: 0.03, audioEnd: 1.9, isFinal: false) == nil,
                   "Shifted draft duplicated finalized audio")
        try expect(timeline.accept(source: "We can approve it.", audioStart: 0.04, audioEnd: 2.1, isFinal: true) == nil,
                   "Shifted final duplicated finalized audio")
        let next = try require(timeline.accept(source: "Let's revisit tomorrow.", audioStart: 2, audioEnd: 4, isFinal: true))
        try expect(timeline.segments.count == 2, "Adjacent final range was lost or overlap duplicated")
        try expect(next.source == "Let's revisit tomorrow.", "Adjacent source changed")
    }),
    ("a final prefix replaces a spanning draft and protects it from later combined drafts", {
        var timeline = CaptionTimeline()
        let old = try require(timeline.accept(source: "First part and the next part", audioStart: 0, audioEnd: 4, isFinal: false))
        let prefix = try require(timeline.accept(source: "First part.", audioStart: 0, audioEnd: 2, isFinal: true))
        try expect(!timeline.apply(translation: "첫 부분과 다음 부분", for: old), "Spanning draft overwrote final prefix")
        timeline.apply(translation: "첫 부분입니다.", for: prefix)
        try expect(timeline.accept(source: "First part and next", audioStart: 0.02, audioEnd: 4, isFinal: false) == nil,
                   "Late combined draft reopened final prefix")
        _ = try require(timeline.accept(source: "The next part", audioStart: 2, audioEnd: 4, isFinal: false))
        try expect(timeline.segments.count == 2, "Suffix was unable to continue after finalized prefix")
    }),
    ("jobs must match source text as well as ID and revision", {
        var timeline = CaptionTimeline()
        let current = try require(timeline.accept(source: "We cannot proceed.", audioStart: 0, audioEnd: 2, isFinal: true))
        let forged = TranslationJob(segmentID: current.segmentID, revision: current.revision,
                                    source: "We can proceed.", isSourceFinal: true)
        try expect(!timeline.isCurrent(forged), "Different source considered current")
        try expect(!timeline.needsTranslation(forged), "Different source queued for translation")
        try expect(!timeline.apply(translation: "진행할 수 있습니다.", for: forged), "Different source translation accepted")
        timeline.fail(forged, message: "Wrong job")
        try expect(timeline.segments[0].translationError == nil, "Different source job changed error state")
    }),
    ("invalid text and times do not create captions or final translations", {
        var timeline = CaptionTimeline()
        try expect(timeline.accept(source: " \n", audioStart: 0, audioEnd: 1, isFinal: true) == nil, "Blank source accepted")
        try expect(timeline.accept(source: "Hello", audioStart: -1, audioEnd: 1, isFinal: true) == nil, "Negative start accepted")
        try expect(timeline.accept(source: "Hello", audioStart: .infinity, audioEnd: .infinity, isFinal: true) == nil,
                   "Infinite range accepted")
        try expect(timeline.accept(source: "Hello", audioStart: 2, audioEnd: 1, isFinal: true) == nil, "Reversed range accepted")
        let job = try require(timeline.accept(source: "Hello", audioStart: 0, audioEnd: 1, isFinal: true))
        try expect(!timeline.apply(translation: " \n", for: job), "Empty translation accepted")
        try expect(!timeline.segments[0].isFinal, "Empty translation finalized a caption")
        timeline.fail(job, message: "Retry needed")
        try expect(timeline.segments[0].translationError == "Retry needed", "Current failure lost")
        timeline.apply(translation: "안녕하세요", for: job)
        timeline.fail(job, message: "Late redundant failure")
        try expect(timeline.segments[0].isFinal, "Redundant failure invalidated successful caption")
    }),
    ("following context can correct a final passage without changing ASR records", {
        var timeline = CaptionTimeline()
        let first = try appendFinal(&timeline, source: "He made a bank.", translation: "그는 은행을 만들었습니다.", start: 0, end: 2)
        try expect(timeline.contextJob(endingAt: first.segmentID) == nil, "Single caption requested context")
        let second = try appendFinal(&timeline, source: "The pilot turned the plane left.",
                                     translation: "조종사는 비행기를 왼쪽으로 돌렸습니다.", start: 2, end: 4)
        let originals = timeline.segments
        let context = try requireContext(timeline.contextJob(endingAt: second.segmentID))
        try expect(context.members.count == 2, "Context has wrong member count")
        try expect(context.source == "He made a bank. The pilot turned the plane left.", "Context lost or duplicated source")
        try expect(timeline.applyContext(translation: "조종사는 비행기를 기울여 왼쪽으로 선회했습니다.", for: context),
                   "Current contextual translation rejected")
        try expect(timeline.segments == originals, "Context mutated original ASR or isolated translations")
        try expect(timeline.displaySegments.count == 1, "Grouped context duplicated display rows")
        try expect(timeline.displaySegments[0].contextSegmentCount == 2, "Group size missing")
        try expect(timeline.displaySegments[0].isFinal, "Exact final context group stayed provisional")
        try expect(timeline.displaySegments[0].audioStart == 0 && timeline.displaySegments[0].audioEnd == 4,
                   "Context group lost audio range")
        try expect(!timeline.needsContextTranslation(context), "Completed context queued again")
        try expect(!timeline.applyContext(translation: "다른 결과", for: context), "Duplicate context overwrote stable result")
        let export = timeline.exportText()
        try expect(export.contains("KO: 조종사는 비행기를 기울여 왼쪽으로 선회했습니다."), "Export omitted corrected Korean")
        try expect(!export.contains("KO: 그는 은행을 만들었습니다."), "Export presented superseded isolated translation")
    }),
    ("context extends a pair through four chunks then freezes the completed passage", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "First.", translation: "첫째.", start: 0, end: 1)
        let second = try appendFinal(&timeline, source: "Second.", translation: "둘째.", start: 1, end: 2)
        let pair = try requireContext(timeline.contextJob(endingAt: second.segmentID))
        timeline.applyContext(translation: "첫 번째와 두 번째.", for: pair)
        let third = try appendFinal(&timeline, source: "Third.", translation: "셋째.", start: 2, end: 3)
        let triple = try requireContext(timeline.contextJob(endingAt: third.segmentID))
        try expect(triple.members.count == 3, "Existing pair was detached while extending")
        timeline.applyContext(translation: "첫째, 둘째, 셋째.", for: triple)
        let fourth = try appendFinal(&timeline, source: "Fourth.", translation: "넷째.", start: 3, end: 4)
        let four = try requireContext(timeline.contextJob(endingAt: fourth.segmentID))
        try expect(four.members.count == 4, "Existing triple was detached before the fourth chunk")
        timeline.applyContext(translation: "첫째, 둘째, 셋째, 넷째.", for: four)
        let fifth = try appendFinal(&timeline, source: "Fifth.", translation: "다섯째.", start: 4, end: 5)
        try expect(timeline.contextJob(endingAt: fifth.segmentID) == nil, "Frozen group reopened for a fifth member")
        let sixth = try appendFinal(&timeline, source: "Sixth.", translation: "여섯째.", start: 5, end: 6)
        let next = try requireContext(timeline.contextJob(endingAt: sixth.segmentID))
        try expect(next.members.map(\.segmentID) == [fifth.segmentID, sixth.segmentID], "New group reused frozen captions")
        timeline.applyContext(translation: "다섯째와 여섯째.", for: next)
        try expect(timeline.displaySegments.count == 2, "Frozen and new group were not separate")
        try expect(timeline.displaySegments[0].translation == "첫째, 둘째, 셋째, 넷째.", "Older stable Korean changed")
    }),
    ("an observed correction in the fourth ASR chunk can update the whole recent passage", {
        // These four source texts/ranges came from the paced local pipeline.
        // The injected Korean below checks state transitions, not engine quality.
        var timeline = CaptionTimeline()
        let first = try appendFinal(&timeline, source: "The meeting starts at 3.30.",
                                    translation: "회의는 3시 30분에 시작합니다.", start: 0, end: 2.04)
        let second = try appendFinal(&timeline, source: "We cannot approve this plan yet.",
                                     translation: "아직 이 계획을 승인할 수 없습니다.", start: 2.04, end: 3.54)
        timeline.applyContext(translation: "회의는 3시 30분에 시작하며 아직 이 계획을 승인할 수 없습니다.",
                              for: try requireContext(timeline.contextJob(endingAt: second.segmentID)))
        let third = try appendFinal(&timeline,
                                    source: "I thought the launch was on Tuesday, but let me correct that.",
                                    translation: "출시가 화요일인 줄 알았는데 정정하겠습니다.", start: 3.54, end: 7.02)
        timeline.applyContext(translation: "회의는 3시 30분에 시작합니다. 아직 이 계획을 승인할 수 없습니다. 출시는 화요일인 줄 알았는데 정정하겠습니다.",
                              for: try requireContext(timeline.contextJob(endingAt: third.segmentID)))
        let fourth = try appendFinal(&timeline, source: "It is on Thursday, October 15.",
                                     translation: "10월 15일 목요일입니다.", start: 7.02, end: 9.78)
        let originals = timeline.segments
        let context = try requireContext(timeline.contextJob(endingAt: fourth.segmentID))
        try expect(context.members.count == 4, "Correction was excluded after an already translated triple")
        try expect(context.members.map(\.segmentID) == [first.segmentID, second.segmentID, third.segmentID, fourth.segmentID],
                   "Correcting fourth chunk was detached from earlier source context")
        try expect(context.source.contains("Tuesday, but let me correct that. It is on Thursday, October 15."),
                   "Correction and corrected date did not reach the same translation request")
        let corrected = "회의는 3시 30분에 시작하며 아직 이 계획을 승인할 수 없습니다. 출시일은 화요일인 줄 알았지만 정정하겠습니다. 10월 15일 목요일입니다."
        try expect(timeline.applyContext(translation: corrected, for: context), "Fourth-chunk context update rejected")
        try expect(timeline.segments == originals, "Correction rewrote original ASR records")
        try expect(timeline.displaySegments.count == 1 && timeline.displaySegments[0].contextSegmentCount == 4,
                   "Corrected four-chunk passage was not displayed together")
        try expect(timeline.displaySegments[0].translation == corrected && timeline.displaySegments[0].isFinal,
                   "Corrected translation was missing or still provisional")
        let fifth = try appendFinal(&timeline, source: "Next topic.", translation: "다음 주제입니다.", start: 9.78, end: 10.8)
        try expect(timeline.contextJob(endingAt: fifth.segmentID) == nil, "Completed four-chunk passage reopened for a fifth")
        try expect(timeline.displaySegments[0].translation == corrected, "A new topic destabilized corrected Korean")
    }),
    ("new final source invalidates in-flight context while drafts do not", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "It happened.", translation: "일어났습니다.", start: 0, end: 1)
        let second = try appendFinal(&timeline, source: "Yesterday.", translation: "어제.", start: 1, end: 2)
        let pair = try requireContext(timeline.contextJob(endingAt: second.segmentID))
        _ = timeline.accept(source: "At", audioStart: 2, audioEnd: 3, isFinal: false)
        try expect(timeline.needsContextTranslation(pair), "Unrelated draft invalidated current final context")
        _ = try appendFinal(&timeline, source: "At noon.", translation: "정오에.", start: 2, end: 3)
        try expect(!timeline.applyContext(translation: "어제 일어났습니다.", for: pair), "Superseded context was applied")
        try expect(timeline.displaySegments.count == 3, "Rejected context changed display")
    }),
    ("context waits for exact isolated revisions and rejects forged snapshots", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "The cost is", translation: "비용은", start: 0, end: 1)
        let draft = try require(timeline.accept(source: "fifteen", audioStart: 1, audioEnd: 2, isFinal: false))
        timeline.apply(translation: "15", for: draft)
        let final = try require(timeline.accept(source: "fifty.", audioStart: 1, audioEnd: 2, isFinal: true))
        try expect(timeline.contextJob(endingAt: final.segmentID) == nil, "Stale isolated translation used as finalized context")
        timeline.apply(translation: "50입니다.", for: final)
        let context = try requireContext(timeline.contextJob(endingAt: final.segmentID))
        var forgedMembers = context.members
        let member = forgedMembers[0]
        forgedMembers[0] = TranslationJob(segmentID: member.segmentID, revision: member.revision,
                                           source: "The cost is not", isSourceFinal: true)
        let forged = ContextTranslationJob(members: forgedMembers, contextRevision: context.contextRevision)
        try expect(!timeline.applyContext(translation: "비용은 50이 아닙니다.", for: forged), "Forged context source applied")
        try expect(!timeline.applyContext(translation: " ", for: context), "Blank context applied")
        try expect(timeline.displaySegments.count == 2, "Failed optional context erased valid translations")
    }),
    ("context is bounded by pause, silence, duration, and source length", {
        var paused = CaptionTimeline()
        _ = try appendFinal(&paused, source: "Before pause.", translation: "멈추기 전.", start: 0, end: 1)
        paused.resetContext()
        let after = try appendFinal(&paused, source: "After pause.", translation: "재개 후.", start: 1, end: 2)
        try expect(paused.contextJob(endingAt: after.segmentID) == nil, "Context crossed a pause boundary")
        var silent = CaptionTimeline()
        _ = try appendFinal(&silent, source: "Before silence.", translation: "무음 전.", start: 0, end: 1)
        let later = try appendFinal(&silent, source: "After silence.", translation: "무음 후.", start: 3.1, end: 4)
        try expect(silent.contextJob(endingAt: later.segmentID) == nil, "Context crossed long silence")
        var long = CaptionTimeline()
        _ = try appendFinal(&long, source: "A long statement.", translation: "긴 문장.", start: 0, end: 7)
        let longer = try appendFinal(&long, source: "Another long statement.", translation: "또 긴 문장.", start: 7, end: 13)
        try expect(long.contextJob(endingAt: longer.segmentID) == nil, "Context exceeded duration limit")
        var verbose = CaptionTimeline()
        _ = try appendFinal(&verbose, source: String(repeating: "a", count: 300), translation: "첫 문장.", start: 0, end: 1)
        let verboseEnd = try appendFinal(&verbose, source: String(repeating: "b", count: 300), translation: "다음 문장.", start: 1, end: 2)
        try expect(verbose.contextJob(endingAt: verboseEnd.segmentID) == nil, "Context exceeded character limit")
    }),
    ("pending context presentation stays gray without reopening finalized ASR", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "First.", translation: "첫째.", start: 0, end: 1)
        let second = try appendFinal(&timeline, source: "Second.", translation: "둘째.", start: 1, end: 2)
        let context = try requireContext(timeline.contextJob(endingAt: second.segmentID))
        let pendingIDs = Set(context.members.map(\.segmentID))
        let pendingDisplay = timeline.displaySegments.map { segment in
            var display = segment
            display.contextIsPending = pendingIDs.contains(segment.id)
            return display
        }
        try expect(pendingDisplay.allSatisfy { !$0.isFinal && $0.contextIsPending }, "Pending context showed completed color")
        try expect(timeline.segments.allSatisfy(\.isFinal), "Display pending state reopened ASR")
        try expect(timeline.displaySegments.allSatisfy(\.isFinal), "Clearing pending presentation lost validated translations")
    }),
    ("resetting context rejects an outstanding job and preserves completed display", {
        var timeline = CaptionTimeline()
        _ = try appendFinal(&timeline, source: "First.", translation: "첫째.", start: 0, end: 1)
        let second = try appendFinal(&timeline, source: "Second.", translation: "둘째.", start: 1, end: 2)
        let context = try requireContext(timeline.contextJob(endingAt: second.segmentID))
        timeline.resetContext()
        try expect(!timeline.applyContext(translation: "첫째와 둘째.", for: context), "Previous run context applied after reset")
        try expect(timeline.displaySegments.count == 2 && timeline.segments.allSatisfy(\.isFinal), "Reset erased valid captions")
    }),
    ("late final inside an accepted context gap restores chronological rows and preserves unrelated groups", {
        try checkLateContextGapInsertion(isFinal: true)
    }),
    ("late draft inside an accepted context gap stays gray and preserves unrelated groups", {
        try checkLateContextGapInsertion(isFinal: false)
    }),
    ("bounded live windows preserve context groups and the complete long transcript", {
        var timeline = CaptionTimeline()
        for index in 0..<1_201 {
            let current = try appendFinal(&timeline, source: "Statement \(index).",
                translation: "확정 \(index).", start: Double(index) * 2, end: Double(index) * 2 + 1.5)
            if let context = timeline.contextJob(endingAt: current.segmentID) {
                try expect(timeline.applyContext(translation: "문맥: " + context.source, for: context),
                    "Long-running context was rejected")
            }
        }
        let stableFirst = timeline.segments[0]
        let draft = try require(timeline.accept(source: "Still speaking", audioStart: 2_402,
            audioEnd: 2_403, isFinal: false))
        timeline.apply(translation: "이어지는 중", for: draft)
        let full = timeline.displaySegments
        try expect(timeline.displaySegmentCount == full.count, "Display history count drifted")
        for limit in [0, 1, 2, 7, 99, 100, 201, Int.max] {
            let visible = timeline.recentDisplaySegments(limit: limit)
            let expected = limit == 0 ? [] : Array(full.suffix(min(limit, full.count)))
            try expect(visible == expected, "Live suffix split a context group at limit \(limit)")
        }
        try expect(timeline.recentDisplaySegments(limit: -1).isEmpty, "Negative limit rendered history")
        try expect(timeline.segments.count == 1_202 && timeline.segments[0] == stableFirst,
            "Render cap changed or discarded ASR history")
        let text = timeline.exportText()
        try expect(text.contains("Statement 0.") && text.contains("Statement 1200.") && text.contains("Still speaking"),
            "Bounded live window truncated exported history")
    }),
    ("exports identify unfinished translations", {
        var timeline = CaptionTimeline()
        _ = timeline.accept(source: "Still speaking", audioStart: 65, audioEnd: 66, isFinal: false)
        let exported = timeline.exportText()
        try expect(exported.contains("[01:05 · 미확정]"), "Export hides provisional status")
        try expect(exported.contains("KO: 번역 없음"), "Missing translation misrepresented")
    })
]

var failureCount = 0
for (name, check) in checks {
    do {
        try check()
        print("PASS: \(name)")
    } catch {
        failureCount += 1
        FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
    }
}
if failureCount == 0 {
    print("\(checks.count) caption checks passed.")
} else {
    FileHandle.standardError.write(Data("\(failureCount) of \(checks.count) caption checks failed.\n".utf8))
    exit(1)
}
