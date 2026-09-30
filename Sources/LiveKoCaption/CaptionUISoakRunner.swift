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
        let compactState = CommandLine.arguments.contains("--ui-soak-compact") ? CompactSoakState() : nil
        if let compactState {
            await compactState.prepare(model: model)
        }
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
        var begin: [String: Any] = ["event": "begin", "kind": "synthetic-ui-only", "requestedSeconds": seconds,
               "pid": ProcessInfo.processInfo.processIdentifier, "output": output,
               "phraseTicks": phraseTicks, "nominalInputLevelHz": 40,
               "nominalSourceUpdateHz": 10, "nominalFinalPeriodSeconds": Double(phraseTicks) / 40]
        if compactState != nil { begin["compactModeExercise"] = true }
        write(begin, to: file)
        compactState?.showCompact(model: model, reason: "initial", file: file)
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
            compactState?.exercise(model: model, elapsed: now - began, file: file)
            if now - lastReport >= 1 {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                let document = nativeDocument()
                let viewport = (document as? CaptionTextView)?.viewportInspection?()
                var heartbeat: [String: Any] = ["event": "heartbeat", "elapsedSeconds": now - began, "ticks": tick,
                       "rawSegments": model.segments.count,
                       "visibleSegments": model.recentDisplaySegments(limit: 100).count,
                       "queuedTranslations": model.queuedTranslations,
                       "maxMainActorPauseSeconds": maxPause, "peakRSSBytes": usage.ru_maxrss,
                       "nativeDocumentCharacters": document?.string.count ?? 0,
                       "firstVisibleSegmentID": viewport?.segmentID?.uuidString ?? "",
                       "followsLatest": viewport?.followsLatest ?? true,
                       "selectedStartSegmentID": viewport?.selectedStartSegmentID?.uuidString ?? "",
                       "selectedCharacters": document?.selectedRange().length ?? 0]
                if let compactState {
                    compactState.inspect(model: model)
                    heartbeat.merge(compactState.report) { _, new in new }
                }
                write(heartbeat, to: file)
                lastReport = now
            }
            let resizeIndex = Int((now - began) / 15)
            if resizeIndex > resized {
                resized = resizeIndex
                if let window = compactState?.windows?.detailWindow ??
                    NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
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
        if let compactState {
            // Inspect a settled tail so a SwiftUI transaction in progress is not
            // mistaken for a missing translation during synthetic ASR churn.
            compactState.showCompact(model: model, reason: "final-tail-inspection", file: file)
            try? await Task.sleep(for: .milliseconds(300))
            await compactState.exerciseNativeResize(model: model, file: file)
            try? await Task.sleep(for: .milliseconds(300))
            compactState.inspect(model: model, verifyLatest: true, file: file)
            compactState.showDetailed(model: model, reason: "restore-detail", file: file)
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
            && (compactState?.passed ?? true)
        var complete: [String: Any] = ["event": "complete", "passed": passed, "elapsedSeconds": now - began,
               "rawSegments": model.segments.count, "translatedSegments": translated,
               "visibleSegments": visible.count, "maxMainActorPauseSeconds": maxPause,
               "ticks": tick, "resizes": resized, "transcriptCharacters": model.transcriptText.count,
               "nativeDocumentCharacters": document?.string.count ?? 0,
               "nativeDocumentMatchesLatest": documentMatchesLatest]
        if let compactState { complete.merge(compactState.report) { _, new in new } }
        write(complete, to: file)
        try? file.synchronize()
        fputs("UI soak \(passed ? "passed" : "failed"): \(output)\n", stderr)
        // Leave the tested window alive for native UI inspection unless asked to
        // exit by the automated harness.
        if CommandLine.arguments.contains("--ui-soak-exit") { NSApp.terminate(nil) }
    }

    private static func nativeDocument() -> NSTextView? {
        for window in NSApp.windows where window.isVisible {
            if let content = window.contentView, let text = nativeDocument(in: content) { return text }
        }
        return nil
    }

    private static func nativeDocument(in view: NSView) -> NSTextView? {
        func find(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.enclosingScrollView is CaptionScrollView { return text }
            for child in view.subviews {
                if let text = find(in: child) { return text }
            }
            return nil
        }
        return find(in: view)
    }

    /// Optional window-mode checks do not change the original transcript soak.
    /// These gates concern synthetic rendering and window lifetime only.
    @MainActor
    private final class CompactSoakState {
        private let requiredMinimumSize = NSSize(width: 420, height: 144)
        var windows: CaptionWindowCoordinator?
        private var detailContentID: ObjectIdentifier?
        private var detailDocumentID: ObjectIdentifier?
        private var modelID: ObjectIdentifier?
        private var lastToggleIndex = 0
        private var lastResizeIndex = 0
        private var switches = 0
        private var compactResizes = 0
        private var compactInspections = 0
        private var maxRenderedRows = 0
        private var documentCharacters = 0
        private var coordinatorAvailable = false
        private var switchesPreserveModel = true
        private var switchesPreservePhase = true
        private var switchesPreserveHistory = true
        private var hiddenDetailStaysMounted = true
        private var compactRowsBounded = true
        private var compactRespectsMinimumSize = true
        private var compactDocumentPresent = true
        private var compactMatchesLatest = false
        private var compactTailVisible = false
        private var tailGlyphRect = NSRect.zero
        private var tailVisibleRect = NSRect.zero
        private var nativeResizeChecks = 0
        private var nativeResizeChecksPassed = true

        func prepare(model: CaptionModel) async {
            for _ in 0..<40 {
                if let candidate = CaptionAppDelegate.windows,
                   let content = candidate.detailWindow?.contentView {
                    windows = candidate
                    detailContentID = ObjectIdentifier(content)
                    detailDocumentID = nativeDocument(in: content).map { ObjectIdentifier($0) }
                    modelID = ObjectIdentifier(model)
                    coordinatorAvailable = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        func showCompact(model: CaptionModel, reason: String, file: FileHandle) {
            switchMode(model: model, compact: true, reason: reason, file: file)
        }

        func showDetailed(model: CaptionModel, reason: String, file: FileHandle) {
            switchMode(model: model, compact: false, reason: reason, file: file)
        }

        private func switchMode(model: CaptionModel, compact: Bool, reason: String, file: FileHandle) {
            guard let windows, windows.isCompact != compact else { return }
            let phase = String(describing: model.phase)
            let rawSegments = model.segments.count
            if compact { windows.showCompact() }
            else { windows.showDetailed() }
            switches += 1
            switchesPreserveModel = switchesPreserveModel && modelID == ObjectIdentifier(model)
                && CaptionAppDelegate.model === model && CaptionAppDelegate.windows === windows
            switchesPreservePhase = switchesPreservePhase && String(describing: model.phase) == phase
            switchesPreserveHistory = switchesPreserveHistory && model.segments.count == rawSegments
            inspectMountedDetail()
            write(["event": "compact-mode-switch", "reason": reason,
                   "isCompact": windows.isCompact, "rawSegments": model.segments.count,
                   "phase": String(describing: model.phase),
                   "modelIdentityPreserved": switchesPreserveModel,
                   "phasePreserved": switchesPreservePhase,
                   "rawHistoryPreserved": switchesPreserveHistory,
                   "hiddenDetailMounted": hiddenDetailStaysMounted], to: file)
        }

        func exercise(model: CaptionModel, elapsed: Double, file: FileHandle) {
            let toggleIndex = Int(elapsed / 5)
            if toggleIndex > lastToggleIndex {
                lastToggleIndex = toggleIndex
                if windows?.isCompact == true { showDetailed(model: model, reason: "periodic", file: file) }
                else { showCompact(model: model, reason: "periodic", file: file) }
            }
            let resizeIndex = Int(elapsed / 3)
            guard resizeIndex > lastResizeIndex else { return }
            lastResizeIndex = resizeIndex
            guard let windows, windows.isCompact, let panel = windows.compactPanel else { return }
            let frameMinimum = panel.contentRect(forFrameRect: NSRect(origin: .zero, size: panel.minSize)).size
            // The expected usable minimum is independent of live AppKit
            // getters, which can themselves be reset by hosting layout.
            let minimum = NSSize(width: max(requiredMinimumSize.width,
                max(panel.contentMinSize.width, frameMinimum.width)),
                height: max(requiredMinimumSize.height,
                    max(panel.contentMinSize.height, frameMinimum.height)))
            let sizes = [minimum,
                NSSize(width: max(minimum.width, 900), height: minimum.height),
                NSSize(width: minimum.width, height: max(minimum.height, 320)),
                NSSize(width: max(minimum.width, 620), height: max(minimum.height, 210))]
            let requested = sizes[compactResizes % sizes.count]
            panel.setContentSize(requested)
            compactResizes += 1
            let actual = panel.contentRect(forFrameRect: panel.frame).size
            compactRespectsMinimumSize = compactRespectsMinimumSize
                && actual.width >= minimum.width - 0.5 && actual.height >= minimum.height - 0.5
            write(["event": "compact-resize", "requestedWidth": requested.width,
                   "requestedHeight": requested.height, "actualWidth": actual.width,
                   "actualHeight": actual.height, "minimumWidth": minimum.width,
                   "minimumHeight": minimum.height,
                   "reportedFrameMinWidth": panel.minSize.width,
                   "reportedFrameMinHeight": panel.minSize.height,
                   "reportedContentMinWidth": panel.contentMinSize.width,
                   "reportedContentMinHeight": panel.contentMinSize.height,
                   "minimumSizeRespected": compactRespectsMinimumSize], to: file)
        }

        private func inspectMountedDetail() {
            guard let windows, windows.isCompact else { return }
            let content = windows.detailWindow?.contentView
            let document = content.flatMap { nativeDocument(in: $0) }
            // The empty initial detail has no transcript document. Capture its
            // identity when synthetic input first causes that view to mount.
            if detailDocumentID == nil, let document {
                detailDocumentID = ObjectIdentifier(document)
            }
            hiddenDetailStaysMounted = hiddenDetailStaysMounted
                && content.map { ObjectIdentifier($0) } == detailContentID
                && (detailDocumentID == nil || document.map { ObjectIdentifier($0) } == detailDocumentID)
                && windows.detailWindow?.isVisible == false
        }

        func exerciseNativeResize(model: CaptionModel, file: FileHandle) async {
            guard let windows, windows.isCompact, let panel = windows.compactPanel else { return }
            let original = panel.frame
            let phase = String(describing: model.phase)
            let historyCount = model.segments.count
            defer {
                panel.setFrame(original, display: true)
                panel.saveFrame(usingName: "CompactCaptionPanel")
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            // Exercise the actual overlay returned by the live view hierarchy,
            // without posting pointer events to the OS or moving the mouse.
            nativeResizeProbe(panel: panel, name: "right-bottom-grow",
                start: NSPoint(x: panel.frame.maxX - 3, y: panel.frame.minY + 3),
                delta: NSPoint(x: 80, y: -50), clampToMinimum: false, file: file)
            try? await Task.sleep(for: .milliseconds(200))
            panel.contentView?.layoutSubtreeIfNeeded()
            nativeResizeProbe(panel: panel, name: "left-top-minimum",
                start: NSPoint(x: panel.frame.minX + 3, y: panel.frame.maxY - 3),
                delta: NSPoint(x: panel.frame.width + 100, y: -panel.frame.height - 100),
                clampToMinimum: true, file: file)
            switchesPreserveModel = switchesPreserveModel && modelID == ObjectIdentifier(model)
                && CaptionAppDelegate.model === model && CaptionAppDelegate.windows === windows
            switchesPreservePhase = switchesPreservePhase && String(describing: model.phase) == phase
            switchesPreserveHistory = switchesPreserveHistory && model.segments.count == historyCount
            inspectMountedDetail()
        }

        private func nativeResizeProbe(panel: NSPanel, name: String, start: NSPoint,
                                       delta: NSPoint, clampToMinimum: Bool, file: FileHandle) {
            nativeResizeChecks += 1
            let before = panel.frame
            let windowPoint = panel.convertPoint(fromScreen: start)
            let content = panel.contentView
            let localPoint = content?.convert(windowPoint, from: nil)
            // NSView.hitTest receives coordinates in the receiver's superview.
            let hitPoint = localPoint.flatMap { content?.convert($0, to: content?.superview) }
            let hit = hitPoint.flatMap { content?.hitTest($0) }
            let hitType = hit.map { String(describing: type(of: $0)) } ?? "none"
            guard let hit, hitType.contains("ResizeView"),
                  let down = mouseEvent(.leftMouseDown, at: start, in: panel),
                  let dragged = mouseEvent(.leftMouseDragged,
                    at: NSPoint(x: start.x + delta.x, y: start.y + delta.y), in: panel) else {
                nativeResizeChecksPassed = false
                var failure: [String: Any] = ["event": "compact-native-resize", "probe": name, "hitView": hitType,
                    "passed": false, "reason": "Live border did not hit the native resize view",
                    "probeScreenPoint": [start.x, start.y],
                    "probeWindowPoint": [windowPoint.x, windowPoint.y]]
                if let localPoint { failure["probeContentLocalPoint"] = [localPoint.x, localPoint.y] }
                if let hitPoint { failure["probeContentSuperviewPoint"] = [hitPoint.x, hitPoint.y] }
                failure.merge(hierarchyDiagnostics(panel: panel)) { _, new in new }
                write(failure, to: file)
                return
            }
            hit.mouseDown(with: down)
            hit.mouseDragged(with: dragged)
            var didRelease = false
            if let up = mouseEvent(.leftMouseUp,
                at: NSPoint(x: start.x + delta.x, y: start.y + delta.y), in: panel) {
                hit.mouseUp(with: up)
                didRelease = true
            }
            let after = panel.frame
            let expectedWidth = clampToMinimum ? requiredMinimumSize.width : before.width + delta.x
            let expectedHeight = clampToMinimum ? requiredMinimumSize.height : before.height - delta.y
            let sizeMatches = abs(after.width - expectedWidth) <= 1
                && abs(after.height - expectedHeight) <= 1
            let anchorsMatch = clampToMinimum
                ? abs(after.maxX - before.maxX) <= 1 && abs(after.minY - before.minY) <= 1
                : abs(after.minX - before.minX) <= 1 && abs(after.maxY - before.maxY) <= 1
            let frameChanged = abs(after.width - before.width) > 1 || abs(after.height - before.height) > 1
            let passed = didRelease && frameChanged && sizeMatches && anchorsMatch
            compactRespectsMinimumSize = compactRespectsMinimumSize
                && after.width >= requiredMinimumSize.width - 0.5
                && after.height >= requiredMinimumSize.height - 0.5
            nativeResizeChecksPassed = nativeResizeChecksPassed && passed
            write(["event": "compact-native-resize", "probe": name, "hitView": hitType,
                   "frameChanged": frameChanged, "sizeMatches": sizeMatches,
                   "oppositeEdgesAnchored": anchorsMatch, "clampsToMinimum": clampToMinimum,
                   "expectedWidth": expectedWidth, "expectedHeight": expectedHeight,
                   "actualWidth": after.width, "actualHeight": after.height, "passed": passed], to: file)
        }

        private func mouseEvent(_ type: NSEvent.EventType, at screenPoint: NSPoint,
                                in panel: NSPanel) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: nativeResizeChecks,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }

        func inspect(model: CaptionModel, verifyLatest: Bool = false, file: FileHandle? = nil) {
            inspectMountedDetail()
            guard let windows, windows.isCompact else { return }
            compactInspections += 1
            if let panel = windows.compactPanel {
                let size = panel.contentRect(forFrameRect: panel.frame).size
                compactRespectsMinimumSize = compactRespectsMinimumSize
                    && size.width >= requiredMinimumSize.width - 0.5
                    && size.height >= requiredMinimumSize.height - 0.5
            }
            let document = windows.compactPanel?.contentView.flatMap { compactDocument(in: $0) }
            compactDocumentPresent = compactDocumentPresent && document != nil
            let text = document?.string ?? ""
            documentCharacters = text.count
            let rows = text.components(separatedBy: .newlines).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            maxRenderedRows = max(maxRenderedRows, rows)
            compactRowsBounded = compactRowsBounded && rows <= 2
                && model.recentDisplaySegments(limit: 2).count <= 2
            if verifyLatest {
                let tail = model.recentDisplaySegments(limit: 2)
                compactMatchesLatest = !tail.isEmpty && tail.allSatisfy {
                    guard let translation = $0.translation,
                          !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                    return text.contains(translation)
                }
                compactTailVisible = document.map { latestGlyphIsVisible(in: $0) } ?? false
                if !compactTailVisible, let panel = windows.compactPanel, let file {
                    var failure: [String: Any] = ["event": "compact-tail-visibility-failure",
                        "tailGlyphRect": rectValues(tailGlyphRect), "tailVisibleRect": rectValues(tailVisibleRect)]
                    failure.merge(hierarchyDiagnostics(panel: panel)) { _, new in new }
                    write(failure, to: file)
                }
            }
        }

        private func rectValues(_ rect: NSRect) -> [CGFloat] {
            [rect.origin.x, rect.origin.y, rect.width, rect.height]
        }

        private func viewDiagnostics(_ view: NSView) -> [String: Any] {
            ["type": String(describing: type(of: view)), "frame": rectValues(view.frame),
             "bounds": rectValues(view.bounds), "visibleRect": rectValues(view.visibleRect),
             "isHidden": view.isHidden, "hiddenAncestor": view.isHiddenOrHasHiddenAncestor,
             "isFlipped": view.isFlipped, "windowNumber": view.window?.windowNumber ?? -1]
        }

        private func hierarchyDiagnostics(panel: NSPanel) -> [String: Any] {
            var diagnostics: [String: Any] = ["panelFrame": rectValues(panel.frame),
                "panelVisible": panel.isVisible, "panelStyleMask": String(panel.styleMask.rawValue),
                "panelMinSize": [panel.minSize.width, panel.minSize.height],
                "panelContentMinSize": [panel.contentMinSize.width, panel.contentMinSize.height]]
            guard let content = panel.contentView else { return diagnostics }
            diagnostics["panelContentView"] = viewDiagnostics(content)
            var chains: [[String: Any]] = []
            func visit(_ view: NSView) {
                let type = String(describing: type(of: view))
                if view is CompactCaptionTextView || type.contains("ResizeView") {
                    var chain: [[String: Any]] = []
                    var ancestor: NSView? = view
                    while let current = ancestor {
                        chain.append(viewDiagnostics(current))
                        ancestor = current.superview
                    }
                    chains.append(["target": type, "ancestors": chain])
                }
                for child in view.subviews { visit(child) }
            }
            visit(content)
            diagnostics["compactTargetViewChains"] = chains
            return diagnostics
        }

        private func latestGlyphIsVisible(in text: NSTextView) -> Bool {
            guard let layout = text.layoutManager, let container = text.textContainer else { return false }
            let character = (text.string as NSString).rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
            guard character.location != NSNotFound else { return false }
            layout.ensureLayout(for: container)
            let glyph = layout.glyphRange(forCharacterRange: character, actualCharacterRange: nil)
            guard glyph.length > 0 else { return false }
            let origin = text.textContainerOrigin
            tailGlyphRect = layout.boundingRect(forGlyphRange: glyph, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
            tailVisibleRect = text.visibleRect
            // One point allows native pixel rounding while still requiring the
            // whole final glyph to fit inside the clipped caption viewport.
            return tailGlyphRect.width > 0 && tailGlyphRect.height > 0
                && tailVisibleRect.insetBy(dx: -1, dy: -1).contains(tailGlyphRect)
        }

        private func compactDocument(in view: NSView) -> NSTextView? {
            if let text = view as? CompactCaptionTextView { return text }
            for child in view.subviews {
                if let text = compactDocument(in: child) { return text }
            }
            return nil
        }

        var passed: Bool {
            coordinatorAvailable && switches >= 2 && compactInspections > 0
                && switchesPreserveModel && switchesPreservePhase && switchesPreserveHistory
                && hiddenDetailStaysMounted && detailDocumentID != nil
                && compactRowsBounded && compactRespectsMinimumSize
                && compactDocumentPresent && compactMatchesLatest && compactTailVisible
                && nativeResizeChecks == 2 && nativeResizeChecksPassed
                && windows?.isCompact == false
                && windows?.detailWindow?.isVisible == true
        }

        var report: [String: Any] {
            ["compactCoordinatorAvailable": coordinatorAvailable,
             "compactModeSwitches": switches, "compactResizes": compactResizes,
             "compactInspections": compactInspections, "compactMaxRenderedRows": maxRenderedRows,
             "compactDocumentCharacters": documentCharacters,
             "compactSwitchesPreserveModel": switchesPreserveModel,
             "compactSwitchesPreservePhase": switchesPreservePhase,
             "compactSwitchesPreserveRawHistory": switchesPreserveHistory,
             "compactHiddenDetailStaysMounted": hiddenDetailStaysMounted,
             "compactDetailDocumentObserved": detailDocumentID != nil,
             "compactRowsBounded": compactRowsBounded,
             "compactRespectsMinimumSize": compactRespectsMinimumSize,
             "compactDocumentPresent": compactDocumentPresent,
             "compactMatchesLatestTail": compactMatchesLatest,
             "compactTailVisible": compactTailVisible,
             "compactNativeResizeChecks": nativeResizeChecks,
             "compactNativeResizeChecksPassed": nativeResizeChecks == 2 && nativeResizeChecksPassed,
             "compactTailGlyphRect": [tailGlyphRect.origin.x, tailGlyphRect.origin.y,
                 tailGlyphRect.width, tailGlyphRect.height],
             "compactTailVisibleRect": [tailVisibleRect.origin.x, tailVisibleRect.origin.y,
                 tailVisibleRect.width, tailVisibleRect.height],
             "compactPanelVisible": windows?.compactPanel?.isVisible ?? false,
             "compactDetailVisible": windows?.detailWindow?.isVisible ?? false,
             "compactChecksPassed": passed]
        }
    }

    private static func write(_ values: [String: Any], to file: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? file.write(contentsOf: data + Data([10]))
    }
}
