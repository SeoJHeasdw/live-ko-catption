import AppKit
import Darwin
import Foundation

/// Exercises the real visible window and caption scheduler without microphone
/// capture or Apple language engines. It reports UI stability only.
@MainActor
enum CaptionUISoakRunner {
    private static var task: Task<Void, Never>?

    static var requestedSeconds: Double? {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-soak-seconds"),
              CommandLine.arguments.indices.contains(index + 1),
              let seconds = Double(CommandLine.arguments[index + 1]),
              seconds.isFinite, seconds >= 1 else { return nil }
        return min(seconds, 7_200)
    }

    static func makeModel() -> CaptionModel {
        let injectFailure = CommandLine.arguments.contains("--ui-soak-inject-failure")
        var didInjectFailure = false
        let model = CaptionModel(translationOverride: { source, isContext in
            try await Task.sleep(for: .milliseconds(isContext ? 35 : 65))
            try Task.checkCancellation()
            if injectFailure, !didInjectFailure, !isContext,
               source.hasPrefix("[synthetic 0]"), source.hasSuffix("discussion") {
                didInjectFailure = true
                throw NSError(domain: "CaptionUISoak", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "합성 번역 실패 · 재시도 버튼 검사"
                ])
            }
            return "[합성 자막 검사] 다음 단계에 앞서 계획을 다시 확인하겠습니다. 이어지는 문맥에 따라 아직 생성 중인 자막과 확정된 자막을 갱신합니다. \(source)"
        })
        model.isUISoak = true
        model.isChecking = false
        model.assetsReady = true
        model.phase = .listening
        return model
    }

    static func start(model: CaptionModel) {
        guard let seconds = requestedSeconds, task == nil else { return }
        let output = argument(after: "--ui-soak-output") ??
            FileManager.default.temporaryDirectory.appendingPathComponent("caption-ui-soak-\(ProcessInfo.processInfo.processIdentifier).jsonl").path
        task = Task { @MainActor in
            await run(model: model, seconds: seconds, output: output)
        }
    }

    private static func argument(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func run(model: CaptionModel, seconds: Double, output: String) async {
        FileManager.default.createFile(atPath: output, contents: nil)
        guard let file = FileHandle(forWritingAtPath: output) else {
            fputs("Cannot open UI soak report: \(output)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        defer { try? file.close() }
        let initialFontSize = model.fontSize
        let initialShowEnglish = model.showEnglish
        let began = ProcessInfo.processInfo.systemUptime
        var lastTick = began
        var lastReport = began
        var maxPause: Double = 0
        var tick = 0
        var segmentNumber = 0
        var resized = 0
        let phraseTicks: Int
        if let value = argument(after: "--ui-soak-phrase-ticks"), let parsed = Int(value),
           (8...80).contains(parsed), parsed.isMultiple(of: 4) { phraseTicks = parsed }
        else { phraseTicks = 80 }
        let sourceWords = "Before we continue with the next part let us review the plan carefully and make sure everyone understands the context of this discussion".split(separator: " ")
        write(["event": "begin", "kind": "synthetic-ui-only", "requestedSeconds": seconds,
               "pid": ProcessInfo.processInfo.processIdentifier, "output": output,
               "phraseTicks": phraseTicks, "nominalInputLevelHz": 40,
               "nominalSourceUpdateHz": 10, "nominalFinalPeriodSeconds": Double(phraseTicks) / 40], to: file)
        while !Task.isCancelled, ProcessInfo.processInfo.systemUptime - began < seconds {
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { break }
            let now = ProcessInfo.processInfo.systemUptime
            maxPause = max(maxPause, max(0, now - lastTick - 0.025))
            lastTick = now
            tick += 1
            model.audioLevel = Double(tick % 37) / 36
            // Nominal 40 input-level updates/s and 10 ASR revisions/s; actual
            // delivered rate is recorded. Default finals occur every two seconds.
            // A short optional interval accelerates bounded-history browse checks.
            if tick % 4 == 0 {
                let partial = tick % phraseTicks
                let final = partial == 0
                let wordCount = final ? sourceWords.count : min(sourceWords.count, 3 + partial * 20 / phraseTicks)
                let source = "[synthetic \(segmentNumber)] " + sourceWords.prefix(wordCount).joined(separator: " ")
                let start = Double(segmentNumber) * 2
                model.receive(source: source, audioStart: start,
                    audioEnd: start + Double(final ? phraseTicks : partial) * 2 / Double(phraseTicks), isFinal: final)
                if final { segmentNumber += 1 }
            }
            if now - lastReport >= 1 {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let document = nativeDocument()
                let viewport = (document as? CaptionTextView)?.viewportInspection?()
                write(["event": "heartbeat", "elapsedSeconds": now - began, "ticks": tick,
                       "rawSegments": model.segments.count,
                       "visibleSegments": model.recentDisplaySegments(limit: 100).count,
                       "queuedTranslations": model.queuedTranslations,
                       "maxMainActorPauseSeconds": maxPause, "peakRSSBytes": usage.ru_maxrss,
                       "nativeDocumentCharacters": document?.string.count ?? 0,
                       "firstVisibleSegmentID": viewport?.segmentID?.uuidString ?? "",
                       "followsLatest": viewport?.followsLatest ?? true,
                       "selectedStartSegmentID": viewport?.selectedStartSegmentID?.uuidString ?? "",
                       "selectedCharacters": document?.selectedRange().length ?? 0], to: file)
                lastReport = now
            }
            let resizeIndex = Int((now - began) / 15)
            if resizeIndex > resized {
                resized = resizeIndex
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    window.setContentSize(resizeIndex.isMultiple(of: 2)
                        ? NSSize(width: 1120, height: 820) : NSSize(width: 950, height: 660))
                }
                model.fontSize = resizeIndex.isMultiple(of: 2) ? 35 : 48
                model.showEnglish = resizeIndex.isMultiple(of: 2)
            }
        }
        // Drain the final scheduler work and verify all source history survived
        // the bounded document, including source/translation state transitions.
        if tick % phraseTicks != 0 {
            let source = "[synthetic \(segmentNumber)] " + sourceWords.joined(separator: " ")
            model.receive(source: source, audioStart: Double(segmentNumber) * 2,
                audioEnd: Double(segmentNumber + 1) * 2, isFinal: true)
        }
        let drainStart = ProcessInfo.processInfo.systemUptime
        while model.hasPendingTranslations && ProcessInfo.processInfo.systemUptime - drainStart < 10 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        model.phase = .idle
        model.audioLevel = 0
        model.fontSize = initialFontSize
        model.showEnglish = initialShowEnglish
        try? await Task.sleep(for: .milliseconds(300))
        let now = ProcessInfo.processInfo.systemUptime
        let visible = model.recentDisplaySegments(limit: 100)
        let translated = model.segments.filter {
            $0.translatedRevision == $0.revision && $0.translationError == nil &&
                !($0.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }.count
        let document = nativeDocument()
        let documentMatchesLatest = visible.last.map { document?.string.contains($0.translation ?? "") == true } ?? false
        let passed = maxPause < 2 && visible.count <= 100 && !model.hasPendingTranslations
            && translated == model.segments.count && documentMatchesLatest
        write(["event": "complete", "passed": passed, "elapsedSeconds": now - began,
               "rawSegments": model.segments.count, "translatedSegments": translated,
               "visibleSegments": visible.count, "maxMainActorPauseSeconds": maxPause,
               "ticks": tick, "resizes": resized, "transcriptCharacters": model.transcriptText.count,
               "nativeDocumentCharacters": document?.string.count ?? 0,
               "nativeDocumentMatchesLatest": documentMatchesLatest], to: file)
        try? file.synchronize()
        fputs("UI soak \(passed ? "passed" : "failed"): \(output)\n", stderr)
        // Leave the tested window alive for native UI inspection unless asked to
        // exit by the automated harness.
        if CommandLine.arguments.contains("--ui-soak-exit") { NSApp.terminate(nil) }
    }

    private static func nativeDocument() -> NSTextView? {
        func find(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.enclosingScrollView is CaptionScrollView { return text }
            for child in view.subviews {
                if let text = find(in: child) { return text }
            }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView, let text = find(in: content) { return text }
        }
        return nil
    }

    private static func write(_ values: [String: Any], to file: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? file.write(contentsOf: data + Data([10]))
    }
}
