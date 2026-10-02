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
    ("a final baseline preview stays gray and cannot reopen completed captions", {
        var timeline = CaptionTimeline()
        let partial = try require(timeline.accept(source: "Still speaking", audioStart: 0, audioEnd: 1, isFinal: false))
        try expect(!timeline.preview(translation: "아직 말하는 중입니다.", for: partial),
            "Optional final preview accepted a provisional source")
        let final = try require(timeline.accept(source: "Finished speaking.", audioStart: 0, audioEnd: 1, isFinal: true))
        try expect(!timeline.preview(translation: "예전 원문 번역", for: partial), "Stale preview changed a newer final revision")
        try expect(!timeline.preview(translation: " \n ", for: final), "Empty preview hid the current translation")
        try expect(timeline.preview(translation: "빠르게 생성한 번역입니다.", for: final), "Current final baseline could not be shown")
        try expect(timeline.segments[0].sourceIsFinal && !timeline.segments[0].isFinal &&
            timeline.needsTranslation(final) && timeline.segments[0].translation == "빠르게 생성한 번역입니다.",
            "Visible pending baseline was incorrectly finalized")
        try expect(timeline.apply(translation: "다듬기를 마친 번역입니다.", for: final), "Exact final refinement could not be applied")
        let completed = timeline.segments[0]
        try expect(completed.isFinal && !timeline.preview(translation: "뒤늦은 중간 번역", for: final),
            "A completed final was reopened by a later preview")
        try expect(timeline.segments[0] == completed, "Rejected preview changed completed text or finality")
    }),
    ("optional refinement reuses an unchanged partial baseline while finality waits", {
        var timeline = CaptionTimeline()
        let partial = try require(timeline.accept(source: "The same sentence.", audioStart: 0, audioEnd: 1, isFinal: false))
        try expect(timeline.apply(translation: "같은 문장입니다.", for: partial), "Partial baseline could not be translated")
        let final = try require(timeline.accept(source: "The same sentence.", audioStart: 0, audioEnd: 1,
            isFinal: true, requireFinalTranslation: true))
        try expect(final.segmentID == partial.segmentID && final.revision == partial.revision && final.isSourceFinal,
            "Confirming unchanged text invented a different source revision")
        try expect(timeline.segments[0].translation == "같은 문장입니다." && !timeline.segments[0].isFinal && timeline.needsTranslation(final),
            "Unchanged final lost its fast baseline or skipped required final refinement")
        try expect(timeline.preview(translation: "같은 문장입니다.", for: final), "Cached baseline could not be used as a pending preview")
        try expect(timeline.apply(translation: "동일한 문장입니다.", for: final) && timeline.segments[0].isFinal,
            "Confirmed unchanged source could not finish optional refinement")
    }),
    ("bounded IT context guides classifier terminology without rewriting ordinary recall", {
        let classifier = LocalTranslationRequest(source: "Recall improved, while precision stayed the same.",
            direction: .englishToKorean, domain: .it, previousSentence: "We are comparing a binary classifier.")
        let classifierTerms = Dictionary(uniqueKeysWithValues: classifier.relevantTerms)
        try expect(classifierTerms["recall"] == "재현율" && classifierTerms["precision"] == "정밀도",
            "Classifier context did not supply the two correct metric translations")
        let ordinary = LocalTranslationRequest(source: "I recall the planning meeting.",
            direction: .englishToKorean, domain: .it, previousSentence: "We are discussing what happened last week.")
        try expect(!ordinary.relevantTerms.contains { $0.0 == "recall" },
            "Ordinary remembering was forced into a classifier metric")
        let general = LocalTranslationRequest(source: classifier.source, direction: .englishToKorean,
            domain: .general, previousSentence: classifier.previousSentence)
        try expect(!general.prompt.contains("Reference translations:"), "General mode silently applied the IT glossary")
        let reverse = LocalTranslationRequest(source: "캐시를 비우고 지연 시간을 확인하세요.", direction: .koreanToEnglish, domain: .it)
        let reverseTerms = Dictionary(uniqueKeysWithValues: reverse.relevantTerms)
        try expect(reverseTerms["캐시"] == "cache" && reverseTerms["지연 시간"] == "latency",
            "Reverse glossary failed to recognize Korean nouns followed by particles")
        let boundary = LocalTranslationRequest(source: "The response is uncached.", direction: .englishToKorean, domain: .it)
        try expect(!boundary.relevantTerms.contains { $0.0 == "cache" }, "Glossary matched a word inside an unrelated larger word")
        let longContext = LocalTranslationRequest(source: "Current source.", direction: .englishToKorean,
            previousSentence: String(repeating: "older context ", count: 100) + "most recent sentence")
        try expect(longContext.previousSentence.count <= 300 && longContext.previousSentence.hasSuffix("most recent sentence"),
            "Context budget lost recent information or admitted unbounded history")
        let oversized = LocalTranslationRequest(source: String(repeating: "a", count: 1_001), direction: .englishToKorean)
        try expect(!oversized.isWithinBudget, "Local refinement admitted an oversized source")
    }),
    ("each model size wraps the same instructions in its own chat template", {
        let request = LocalTranslationRequest(source: "Roll back the deployment.", direction: .englishToKorean, domain: .it)
        let small = request.prompt(template: .hyMT2Small), dense = request.prompt(template: .hyMT2Dense)
        try expect(request.prompt == small && small.hasPrefix("<｜hy_begin▁of▁sentence｜><｜hy_User｜>") &&
            small.hasSuffix("Roll back the deployment.<｜hy_Assistant｜>"), "The 1.8B wrapper changed")
        try expect(dense.hasPrefix("<|startoftext|>") && dense.hasSuffix("Roll back the deployment.<|extra_0|>") &&
            !dense.contains("hy_"), "The 7B wrapper mixed in the 1.8B tokens")
        let strip: (String) -> String = {
            $0.replacingOccurrences(of: "<｜hy_begin▁of▁sentence｜><｜hy_User｜>", with: "")
                .replacingOccurrences(of: "<｜hy_Assistant｜>", with: "")
                .replacingOccurrences(of: "<|startoftext|>", with: "").replacingOccurrences(of: "<|extra_0|>", with: "")
        }
        try expect(strip(small) == strip(dense), "The two wrappers carried different instructions")
        try expect(LocalPromptTemplate.matching(modelFileName: "Hy-MT2-7B-Q4_K_M.gguf") == .hyMT2Dense &&
            LocalPromptTemplate.matching(modelFileName: "HY-MT2-7B-Q6_K.gguf") == .hyMT2Dense &&
            LocalPromptTemplate.matching(modelFileName: "Hy-MT2-1.8B-Q6_K.gguf") == .hyMT2Small,
            "A pinned model file selected the wrong chat template")
        try expect(!request.accepts("배포를 롤백하세요.<|eos|>"), "A leaked 7B control token was accepted")
    }),
    ("the user's glossary corrects only listed spellings and supplies its terms first", {
        let glossary = CaptionGlossary(text: """
            # comment lines and blank lines are ignored

            OpenShift | open shift, Open Shifts
            service mesh = 서비스 메시 | service mash
            recall = 리콜률
            Northwind = 노스윈드 | 노스 윈드, north wind
            = 번역만 있는 줄
            """)
        try expect(glossary.entries.map(\.english) == ["OpenShift", "service mesh", "recall", "Northwind"] &&
            glossary.entries[0].korean == "OpenShift" && glossary.entries[0].heardAs == ["open shift", "Open Shifts"],
            "Glossary lines were not parsed into terms, kept names and listed spellings")
        let english = glossary.correcting("We run it on open shift with a service mash near the North Wind office. Reopen shifts later.",
                                          direction: .englishToKorean)
        try expect(english == "We run it on OpenShift with a service mesh near the Northwind office. Reopen shifts later.",
            "Listed English spellings were not corrected at word boundaries only: \(english)")
        let korean = glossary.correcting("노스 윈드의 서비스는 그대로입니다.", direction: .koreanToEnglish)
        try expect(korean == "노스윈드의 서비스는 그대로입니다.", "A Korean spelling followed by a particle was not corrected: \(korean)")
        try expect(CaptionGlossary.empty.correcting("open shift", direction: .englishToKorean) == "open shift" &&
            glossary.correcting("Nothing listed here.", direction: .englishToKorean) == "Nothing listed here.",
            "Text without a listed spelling was changed")
        let custom = LocalTranslationRequest(source: "Recall improved after Northwind moved the classifier to OpenShift.",
            direction: .englishToKorean, domain: .custom, glossary: glossary.entries)
        let terms = custom.relevantTerms
        try expect(terms.prefix(3).map(\.0) == ["OpenShift", "recall", "Northwind"] &&
            terms.first { $0.0 == "recall" }?.1 == "리콜률" && terms.filter { $0.0.lowercased() == "recall" }.count == 1,
            "The owner's terms did not come first or did not replace the built-in term of the same name: \(terms)")
        try expect(custom.prompt.contains("Northwind translates to 노스윈드") && custom.prompt.contains("OpenShift translates to OpenShift") &&
            !custom.prompt.contains("This is an IT discussion."),
            "The custom prompt did not reference the owner's terms")
        let reverse = LocalTranslationRequest(source: "노스윈드의 서비스 메시를 점검합니다.", direction: .koreanToEnglish,
            domain: .custom, glossary: glossary.entries)
        try expect(reverse.relevantTerms.contains { $0 == ("노스윈드", "Northwind") } &&
            reverse.relevantTerms.contains { $0 == ("서비스 메시", "service mesh") },
            "Korean input did not match the owner's Korean terms")
        let it = LocalTranslationRequest(source: custom.source, direction: .englishToKorean, domain: .it, glossary: glossary.entries)
        try expect(it.glossary.isEmpty && !it.prompt.contains("Northwind translates"),
            "The owner's glossary leaked into a conversation that did not select it")
        let many = CaptionGlossary(text: (0..<400).map { "term\($0) = 용어\($0)" }.joined(separator: "\n"))
        try expect(many.entries.count == CaptionGlossary.entryLimit, "The glossary admitted an unbounded number of terms")
    }),
    ("selected dictionaries combine subject areas and reference only current-source terms", {
        let selected = BuiltInDictionaries.all
        try expect(selected.count == 3 && Set(selected.map(\.id)).count == 3,
            "The three public dictionaries do not have independent identities")
        let request = LocalTranslationRequest(source: "IBM watsonx.ai uses a large language model to assess credit risk.",
            direction: .englishToKorean, dictionaries: selected,
            previousSentence: "The previous discussion covered retrieval-augmented generation.")
        let terms = Dictionary(uniqueKeysWithValues: request.relevantTerms)
        try expect(terms["watsonx.ai"] == "watsonx.ai" && terms["large language model"] == "대규모 언어 모델" &&
            terms["credit risk"] != nil, "Combining AI, IBM and finance dropped a selected source term: \(terms)")
        try expect(selected.allSatisfy { request.prompt.contains($0.context) },
            "A selected subject area's context was not included")
        try expect(!terms.keys.contains("retrieval-augmented generation") &&
            !request.prompt.contains("retrieval-augmented generation translates to"),
            "A term from an earlier sentence leaked into current-source references")
        let aiOnly = LocalTranslationRequest(source: request.source, direction: .englishToKorean,
            dictionaries: [BuiltInDictionaries.ai])
        try expect(aiOnly.relevantTerms.contains { $0.0 == "large language model" } &&
            !aiOnly.relevantTerms.contains { $0.0 == "watsonx.ai" || $0.0 == "credit risk" },
            "An unselected dictionary supplied terminology")
    }),
    ("reference terms stay bounded after combining dictionaries in either direction", {
        let entries = (0..<12).map { GlossaryEntry(english: "term\($0)", korean: "용어\($0)") }
        let first = CaptionDictionary(id: "test:first", name: "First", glossary: CaptionGlossary(entries: Array(entries.prefix(6))))
        let second = CaptionDictionary(id: "test:second", name: "Second", glossary: CaptionGlossary(entries: Array(entries.suffix(6))))
        let english = LocalTranslationRequest(source: entries.map(\.english).joined(separator: ", "),
            direction: .englishToKorean, dictionaries: [first, second])
        let korean = LocalTranslationRequest(source: entries.map { $0.korean + "를" }.joined(separator: ", "),
            direction: .koreanToEnglish, dictionaries: [first, second])
        try expect(english.relevantTerms.count == 8 && korean.relevantTerms.count == 8,
            "Combining dictionaries bypassed the eight-reference budget")
        let boundary = LocalTranslationRequest(source: "term10 and an unrelated term100.",
            direction: .englishToKorean, dictionaries: [first, second])
        try expect(boundary.relevantTerms.count == 1 && boundary.relevantTerms[0].0 == "term10",
            "A reference matched inside a different source word")
    }),
    ("dictionary references match plural and spacing variants without rewriting source", {
        let english = LocalTranslationRequest(source: "Large language models use retrieval augmented generation.",
            direction: .englishToKorean, dictionaries: [BuiltInDictionaries.ai])
        try expect(english.relevantTerms.contains { $0.0 == "large language model" } &&
            english.relevantTerms.contains { $0.0 == "retrieval-augmented generation" },
            "Plural or hyphen variants were missed")
        try expect(english.source == "Large language models use retrieval augmented generation." &&
            english.prompt.contains("Translate ONLY [Source Text]") &&
            english.prompt.contains("[Source Text]\n" + english.source),
            "Reference matching rewrote source or failed to isolate it from background")
        let korean = LocalTranslationRequest(source: "머신러닝과 자금 세탁 방지를 논의합니다.",
            direction: .koreanToEnglish, dictionaries: [BuiltInDictionaries.ai, BuiltInDictionaries.finance])
        try expect(korean.relevantTerms.contains { $0.1 == "machine learning" } &&
            korean.relevantTerms.contains { $0.1 == "anti-money laundering" },
            "Korean spacing variants were missed")
        try expect(!english.accepts("[Subject Areas] AI terminology") &&
            !english.accepts("[Background Information] AI terminology"), "Leaked prompt labels were accepted")
    }),
    ("personal reference terms override public suggestions regardless of selection order", {
        guard let publicRisk = BuiltInDictionaries.finance.glossary.entries.first(where: { $0.english == "credit risk" }) else {
            throw CheckFailure(description: "The finance dictionary is missing the credit-risk reference")
        }
        let personal = CaptionDictionary.local(fileName: "test-personal.txt", text: """
            # 이름: 개인 참고
            # 문맥: Use the owner's chosen terminology when it fits the sentence.
            credit risk = 개인 지정 신용 위험
            credit exposure = \(publicRisk.korean)
            """)
        try expect(personal.isPersonal && personal.id == CaptionDictionary.localID(fileName: "test-personal.txt") &&
            personal.name == "개인 참고" && !personal.context.isEmpty,
            "A local dictionary lost its identity, display name or subject information")
        for selected in [[BuiltInDictionaries.finance, personal], [personal, BuiltInDictionaries.finance]] {
            let forward = LocalTranslationRequest(source: "Assess credit risk.", direction: .englishToKorean,
                dictionaries: selected)
            try expect(forward.relevantTerms.count == 1 && forward.relevantTerms[0] == ("credit risk", "개인 지정 신용 위험"),
                "The public English term overrode the personal translation")
            let reverse = LocalTranslationRequest(source: publicRisk.korean + "를 평가합니다.", direction: .koreanToEnglish,
                dictionaries: selected)
            try expect(reverse.relevantTerms.count == 1 && reverse.relevantTerms[0] == (publicRisk.korean, "credit exposure"),
                "The public Korean term overrode the personal translation")
            try expect(!DictionaryTerms(dictionaries: selected, direction: .englishToKorean).conflicts.contains { $0.source == "credit risk" } &&
                !DictionaryTerms(dictionaries: selected, direction: .koreanToEnglish).conflicts.contains { $0.source == publicRisk.korean },
                "A resolved personal override was incorrectly reported as an unresolved conflict")
        }
    }),
    ("same-priority conflicts are omitted in either direction without depending on checkbox order", {
        for personal in [false, true] {
            let first = CaptionDictionary(id: "test:first", name: "First", glossary: CaptionGlossary(text: """
                shared phrase = 같은 표현
                choice = 선택
                risk exposure = 익스포저
                """), isPersonal: personal)
            let second = CaptionDictionary(id: "test:second", name: "Second", glossary: CaptionGlossary(text: """
                shared phrase = 같은 표현
                choice = 고르기
                credit exposure = 익스포저
                """), isPersonal: personal)
            for selected in [[first, second], [second, first]] {
                let forward = DictionaryTerms(dictionaries: selected, direction: .englishToKorean)
                try expect(!forward.pairs.contains { $0.0 == "choice" } && forward.conflicts.count == 1 &&
                    forward.conflicts[0].source == "choice" && forward.conflicts[0].dictionaries == ["First", "Second"],
                    "An English conflict was silently resolved by selection order")
                try expect(forward.pairs.filter { $0 == ("shared phrase", "같은 표현") }.count == 1,
                    "Identical references were treated as a conflict or duplicated")
                let reverse = DictionaryTerms(dictionaries: selected, direction: .koreanToEnglish)
                try expect(!reverse.pairs.contains { $0.0 == "익스포저" } && reverse.conflicts.count == 1 &&
                    reverse.conflicts[0].source == "익스포저" && reverse.conflicts[0].dictionaries == ["First", "Second"],
                    "A Korean conflict was silently resolved by selection order")
                let forwardRequest = LocalTranslationRequest(source: "choice and shared phrase.",
                    direction: .englishToKorean, dictionaries: selected)
                let reverseRequest = LocalTranslationRequest(source: "익스포저와 같은 표현을 검토합니다.",
                    direction: .koreanToEnglish, dictionaries: selected)
                try expect(forwardRequest.relevantTerms.count == 1 && reverseRequest.relevantTerms.count == 1 &&
                    !forwardRequest.prompt.contains("choice translates to") &&
                    !reverseRequest.prompt.contains("익스포저 translates to"),
                    "An omitted conflict still entered a model reference prompt")
            }
        }
    }),
    ("only unambiguous selected personal aliases can correct recognized source text", {
        // Public aliases are intentionally present here to test that even an
        // accidentally supplied alias cannot turn public hints into rewriting.
        let publicDictionary = CaptionDictionary(id: "test:public", name: "Public", glossary: CaptionGlossary(text: """
            IBM = IBM | eye bee em, 아이 비 엠
            """))
        for direction in [CaptionDirection.englishToKorean, .koreanToEnglish] {
            let publicCorrections = DictionaryTerms.corrections(dictionaries: [publicDictionary], direction: direction)
            try expect(publicCorrections.entries.isEmpty &&
                publicCorrections.correcting("eye bee em 아이 비 엠", direction: direction) == "eye bee em 아이 비 엠",
                "A public dictionary rewrote recognized text")
        }
        let first = CaptionDictionary.local(fileName: "first.txt", text: """
            OpenShift = 오픈시프트 | open shift, 오픈 시프트
            service mesh = 서비스 메시 | service mash, 서비스 매시
            """)
        let second = CaptionDictionary.local(fileName: "second.txt", text: """
            OpenSearch = 오픈서치 | open shift, 오픈 시프트
            """)
        for selected in [[publicDictionary, first, second], [second, first, publicDictionary]] {
            let english = DictionaryTerms.corrections(dictionaries: selected, direction: .englishToKorean)
            try expect(english.correcting("eye bee em on open shift with service mash.", direction: .englishToKorean) ==
                "eye bee em on open shift with service mesh.",
                "Public or ambiguous aliases changed English source, or a safe personal alias was lost")
            let korean = DictionaryTerms.corrections(dictionaries: selected, direction: .koreanToEnglish)
            try expect(korean.correcting("아이 비 엠과 오픈 시프트에서 서비스 매시를 확인합니다.", direction: .koreanToEnglish) ==
                "아이 비 엠과 오픈 시프트에서 서비스 메시를 확인합니다.",
                "Public or ambiguous aliases changed Korean source, or a safe personal alias was lost")
        }
        let firstOnly = DictionaryTerms.corrections(dictionaries: [first], direction: .englishToKorean)
        try expect(firstOnly.correcting("open shift", direction: .englishToKorean) == "OpenShift",
            "An unselected personal dictionary blocked a selected dictionary's unambiguous alias")
    }),
    ("composed corrections match original text once and prefer the longest listed phrase", {
        let first = CaptionDictionary.local(fileName: "first.txt", text: """
            OpenShift = 오픈시프트 | open shift, 오픈 시프트
            ShiftEngine = 시프트엔진 | open shift platform, 오픈 시프트 플랫폼
            """)
        let second = CaptionDictionary.local(fileName: "second.txt", text: """
            PlatformSuite = 플랫폼스위트 | OpenShift, 오픈시프트
            """)
        for selected in [[first, second], [second, first]] {
            let english = DictionaryTerms.corrections(dictionaries: selected, direction: .englishToKorean)
            try expect(english.correcting("We use open shift.", direction: .englishToKorean) == "We use OpenShift.",
                "A canonical spelling inserted by one dictionary cascaded into another dictionary's alias")
            try expect(english.correcting("We use open shift platform and open shift. Reopen shifts later.", direction: .englishToKorean) ==
                "We use ShiftEngine and OpenShift. Reopen shifts later.",
                "A shorter alias defeated the longest listed phrase or a Latin alias crossed a word boundary")
            let korean = DictionaryTerms.corrections(dictionaries: selected, direction: .koreanToEnglish)
            try expect(korean.correcting("오픈 시프트 플랫폼과 오픈 시프트를 확인합니다.", direction: .koreanToEnglish) ==
                "시프트엔진과 오픈시프트를 확인합니다.",
                "Korean corrections cascaded, lost the longest phrase or dropped following particles")
        }
    }),
    ("maximum-size unrelated dictionaries preserve partial text and still correct a last-file alias", {
        let dictionaries = (0..<32).map { dictionary in
            CaptionDictionary(id: "local:synthetic-\(dictionary).txt", name: "Synthetic \(dictionary)",
                glossary: CaptionGlossary(entries: (0..<300).map { term in
                    GlossaryEntry(english: "term\(dictionary)-\(term)", korean: "term\(dictionary)-\(term)",
                        heardAs: (0..<8).map { "misheard-\(dictionary)-\(term)-\($0)" })
                }), isPersonal: true)
        }
        let corrections = DictionaryTerms.corrections(dictionaries: dictionaries, direction: .englishToKorean)
        try expect(corrections.entries.count == 32 * 300 && corrections.entries.reduce(0) { $0 + $1.heardAs.count } == 32 * 300 * 8,
            "The maximum-size fixture did not cover all permitted local terms and aliases")
        let unrelated = String(repeating: "This is a synthetic partial caption with no matching aliases. ", count: 4)
        try expect(corrections.correcting(unrelated, direction: .englishToKorean) == unrelated,
            "Unrelated aliases changed a partial caption")
        try expect(corrections.correcting("Use misheard-31-299-7.", direction: .englishToKorean) == "Use term31-299.",
            "Combining dictionaries silently discarded a valid alias in the last local file")
    }),
    ("maximum-size shared-prefix aliases require a complete match and preserve the last valid alias", {
        let entries = (0..<(32 * 300)).map { index in
            GlossaryEntry(english: "Term\(index)", korean: "용어\(index)",
                heardAs: (0..<8).map { "ordinary alias \(index) spelling \($0)" })
        }
        let glossary = CaptionGlossary(entries: entries)
        try expect(glossary.entries.reduce(0) { $0 + $1.heardAs.count } == 32 * 300 * 8,
            "The common-prefix fixture did not cover the permitted maximum alias count")
        let source = String(repeating: "We discuss ordinary matters before the next planning meeting. ", count: 4)
        try expect(glossary.correcting(source, direction: .englishToKorean) == source,
            "A shared prefix admitted an incomplete alias into source correction")
        try expect(glossary.correcting("ordinary alias 9599 spelling", direction: .englishToKorean) == "ordinary alias 9599 spelling",
            "A prefix ending inside a compressed alias edge was treated as a complete spelling")
        try expect(glossary.correcting("Use ORDINARY ALIAS 9599 spelling 7.", direction: .englishToKorean) == "Use Term9599.",
            "The last shared-prefix alias was discarded or lost case-insensitive matching")
        try expect(glossary.correcting("ordinary alias 9599 spelling 7을 확인합니다.", direction: .koreanToEnglish) ==
            "ordinary alias 9599 spelling 7을 확인합니다.",
            "A Latin-ending alias lost its word boundary when followed by Korean text")
        try expect(glossary.correcting("ordinary alias 9599 spelling 7", direction: .koreanToEnglish) == "용어9599",
            "A shared-prefix alias used the wrong canonical spelling for Korean input")
    }),
    ("maximum-size reference catalogs preserve late matches and the eight-term budget", {
        let dictionaries = (0..<32).map { dictionary in
            CaptionDictionary(id: "local:references-\(dictionary).txt", name: "References \(dictionary)",
                glossary: CaptionGlossary(entries: (0..<300).map { term in
                    GlossaryEntry(english: "reference_\(dictionary)_\(term)", korean: "참고\(dictionary)_\(term)")
                }), isPersonal: true)
        }
        let unrelated = LocalTranslationRequest(source: "We discuss ordinary matters before the next planning meeting.",
            direction: .englishToKorean, dictionaries: dictionaries)
        try expect(unrelated.relevantTerms.isEmpty,
            "An unrelated source acquired references from a maximum-size catalog")
        let lastTerms = (292..<300).map { "reference_31_\($0)" }
        let late = LocalTranslationRequest(source: lastTerms.joined(separator: ", "),
            direction: .englishToKorean, dictionaries: dictionaries)
        try expect(late.relevantTerms.map(\.0) == lastTerms,
            "Scanning a large catalog discarded matching entries from its last dictionary")
        let firstTerms = (0..<8).map { "reference_0_\($0)" }
        let capped = LocalTranslationRequest(source: (lastTerms + firstTerms).joined(separator: ", "),
            direction: .englishToKorean, dictionaries: dictionaries)
        try expect(capped.relevantTerms.map(\.0) == firstTerms,
            "Later matching terms changed reference priority or bypassed the eight-term limit")
        let sharedPrefix = LocalTranslationRequest(source: "reference_31_299_extra and reference_31_2999 are different names.",
            direction: .englishToKorean, dictionaries: dictionaries)
        try expect(sharedPrefix.relevantTerms.isEmpty,
            "A shared word prefix became an unrelated glossary reference")
        let punctuation = CaptionDictionary.local(fileName: "punctuation.txt", text: "- = 대시\n-- = 이중대시")
        let withoutHyphen = LocalTranslationRequest(source: "An ordinary sentence.", direction: .englishToKorean,
            dictionaries: [punctuation])
        let withHyphen = LocalTranslationRequest(source: "Use - as a separator.", direction: .englishToKorean,
            dictionaries: [punctuation])
        let punctuationTerms = DictionaryTerms(dictionaries: [punctuation], direction: .englishToKorean)
        try expect(punctuationTerms.conflicts.isEmpty && punctuationTerms.pairs.count == 2 &&
            withoutHyphen.relevantTerms.isEmpty && withHyphen.relevantTerms.count == 1 &&
            withHyphen.relevantTerms[0] == ("-", "대시"),
            "Punctuation terms collided, became an empty regex or confused a single hyphen with a double hyphen")
    }),
    ("normalized source variants conflict while exact target spellings remain distinct", {
        let englishFirst = CaptionDictionary.local(fileName: "english-first.txt", text: "risk factor = 위험 요인")
        let englishSecond = CaptionDictionary.local(fileName: "english-second.txt", text: "risk-factor = 위험 요소")
        let koreanFirst = CaptionDictionary.local(fileName: "korean-first.txt", text: "risk factor = 위험 요인")
        let koreanSecond = CaptionDictionary.local(fileName: "korean-second.txt", text: "risk driver = 위험요인")
        let caseFirst = CaptionDictionary.local(fileName: "case-first.txt", text: "product name = MQ")
        let caseSecond = CaptionDictionary.local(fileName: "case-second.txt", text: "product name = mq")
        for reverseOrder in [false, true] {
            let english = reverseOrder ? [englishSecond, englishFirst] : [englishFirst, englishSecond]
            let korean = reverseOrder ? [koreanSecond, koreanFirst] : [koreanFirst, koreanSecond]
            let casing = reverseOrder ? [caseSecond, caseFirst] : [caseFirst, caseSecond]
            let englishTerms = DictionaryTerms(dictionaries: english, direction: .englishToKorean)
            let koreanTerms = DictionaryTerms(dictionaries: korean, direction: .koreanToEnglish)
            let caseTerms = DictionaryTerms(dictionaries: casing, direction: .englishToKorean)
            try expect(englishTerms.pairs.isEmpty && englishTerms.conflicts.count == 1,
                "Hyphen and space variants bypassed English translation conflict detection")
            try expect(koreanTerms.pairs.isEmpty && koreanTerms.conflicts.count == 1,
                "Korean spacing variants bypassed reverse translation conflict detection")
            try expect(caseTerms.pairs.isEmpty && caseTerms.conflicts.count == 1,
                "Distinct target case spellings were silently treated as interchangeable")
            let aliases = DictionaryTerms.corrections(dictionaries: [
                CaptionDictionary.local(fileName: "upper.txt", text: "OpenShift | open shift"),
                CaptionDictionary.local(fileName: "lower.txt", text: "Openshift | open shift")
            ], direction: .englishToKorean)
            try expect(aliases.correcting("Use open shift.", direction: .englishToKorean) == "Use open shift.",
                "An alias with distinct canonical case spellings was resolved silently")
        }
    }),
    ("no dictionary selection supplies no subject or terms and AI preserves everyday recall", {
        let source = "IBM watsonx.ai uses a large language model to assess credit risk."
        let none = LocalTranslationRequest(source: source, direction: .englishToKorean, dictionaries: [])
        try expect(none.relevantTerms.isEmpty && none.glossary.isEmpty &&
            !none.prompt.contains("[Background Information]") && !none.prompt.contains("Reference the following translations:"),
            "An empty selection silently supplied domain context or terminology")
        try expect(DictionaryTerms.corrections(dictionaries: [], direction: .englishToKorean)
            .correcting(source, direction: .englishToKorean) == source,
            "An empty selection changed recognized source text")
        let ordinary = LocalTranslationRequest(source: "I cannot recall our last planning meeting.",
            direction: .englishToKorean, dictionaries: BuiltInDictionaries.all)
        try expect(ordinary.relevantTerms.isEmpty && !ordinary.prompt.contains("recall translates to"),
            "AI selection mapped ordinary remembering to a classification metric")
    }),
    ("optional output checks reject obvious number and language corruption", {
        let request = LocalTranslationRequest(source: "The error rate is 2.5 percent, and latency is 120 milliseconds.",
            baseline: "오류율은 2.5%이며 지연 시간은 120밀리초입니다.", direction: .englishToKorean, domain: .it)
        try expect(request.accepts("오류율은 2.50%이고 지연 시간은 120 ms입니다."),
            "Equivalent numeric formatting was rejected")
        try expect(!request.accepts("오류율은 25%이고 지연 시간은 120밀리초입니다."), "Corrupted decimal was accepted")
        try expect(!request.accepts("오류율은 2.5%이고 지연 시간은 서버上에서 120밀리초입니다."),
            "A stray Chinese character in Korean output was accepted")
        try expect(!request.accepts("오류율은 2.5%입니다."), "Omitted latency number was accepted")
        try expect(!request.accepts("오류율은 2.5%이고 지연 시간은 120밀리초이며 재시도는 3번입니다."),
            "Invented number was accepted")
        try expect(!request.accepts("The error rate is 2.5 percent and latency is 120 milliseconds."),
            "English-only output was accepted for a Korean caption")
        try expect(!request.accepts("오류율 2.5%, 지연 120밀리초 <｜hy_Assistant｜>") && !request.accepts(""),
            "Model control tokens or empty output entered the caption")
        let reverse = LocalTranslationRequest(source: "재시도는 3번입니다.", baseline: "Retry 3 times.", direction: .koreanToEnglish)
        try expect(reverse.accepts("There are 3 retries.") && !reverse.accepts("재시도는 3번입니다."),
            "Reverse caption output language was not checked")
    }),
    ("translation directions map speech locales and export labels consistently", {
        let english = CaptionDirection.englishToKorean
        let korean = CaptionDirection.koreanToEnglish
        try expect(english.sourceLanguageCode == korean.targetLanguageCode &&
            english.targetLanguageCode == korean.sourceLanguageCode, "Direction languages are not inverse")
        try expect(english.speechLocaleIdentifier == "en-US" && korean.speechLocaleIdentifier == "ko-KR",
            "Speech locale does not match input language")
        var timeline = CaptionTimeline()
        timeline.direction = korean
        _ = try appendFinal(&timeline, source: "배포를 시작합니다.", translation: "Starting deployment.", start: 0, end: 1)
        // A conversation can switch direction; each row keeps its own labels.
        timeline.direction = english
        _ = try appendFinal(&timeline, source: "Thank you.", translation: "감사합니다.", start: 5, end: 6)
        let exported = timeline.exportText()
        try expect(exported.contains("KO: 배포를 시작합니다.\nEN: Starting deployment.") &&
            exported.contains("EN: Thank you.\nKO: 감사합니다."),
            "Export labels did not follow each row's own direction")
        try expect(timeline.segments.map(\.direction) == [korean, english],
            "A direction change relabeled an earlier caption")
    }),
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
