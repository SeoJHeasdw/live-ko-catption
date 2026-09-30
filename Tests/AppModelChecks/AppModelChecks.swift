import CaptionCore
import Foundation

struct ModelCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ModelCheckFailure(description: message) }
}

@MainActor
func waitUntil(_ message: String, seconds: Double = 2,
               condition: @MainActor () -> Bool) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else {
            throw ModelCheckFailure(description: message)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Holding continuations deliberately ignores cancellation, like a stuck system
/// framework. Tests release them afterward and verify their late output is inert.
@MainActor
final class TranslatorProbe {
    struct Call: Equatable {
        let source: String
        let context: Bool
    }
    var calls: [Call] = []
    var heldSources: Set<String> = []
    var holdContexts = false
    var failuresRemaining: [String: Int] = [:]
    var cancellationsRemaining: [String: Int] = [:]
    var responseDelay: Duration?
    private var held: [(Call, CheckedContinuation<String, any Error>)] = []

    func translate(_ source: String, context: Bool) async throws -> String {
        let call = Call(source: source, context: context)
        calls.append(call)
        if heldSources.contains(source) || (context && holdContexts) {
            return try await withCheckedThrowingContinuation { held.append((call, $0)) }
        }
        if let responseDelay { try await Task.sleep(for: responseDelay) }
        if let remaining = cancellationsRemaining[source], remaining > 0 {
            cancellationsRemaining[source] = remaining - 1
            throw CancellationError()
        }
        if let remaining = failuresRemaining[source], remaining > 0 {
            failuresRemaining[source] = remaining - 1
            throw ModelCheckFailure(description: "Injected translation failure")
        }
        return "KO: \(source)"
    }

    func release(source: String? = nil, context: Bool? = nil, translation: String) {
        let matching = held.filter {
            (source == nil || $0.0.source == source) && (context == nil || $0.0.context == context)
        }
        held.removeAll {
            (source == nil || $0.0.source == source) && (context == nil || $0.0.context == context)
        }
        for (_, continuation) in matching { continuation.resume(returning: translation) }
    }

    func failHeldContexts() {
        let matching = held.filter { $0.0.context }
        held.removeAll { $0.0.context }
        for (_, continuation) in matching {
            continuation.resume(throwing: ModelCheckFailure(description: "Injected context failure"))
        }
    }

    func releaseAll() {
        let pending = held
        held.removeAll()
        for (_, continuation) in pending { continuation.resume(returning: "Ignored late response") }
    }
}

@MainActor
final class PermissionProbe {
    var calls = 0
    private var waiting: [CheckedContinuation<Bool, Never>] = []

    func request() async -> Bool {
        calls += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func releaseFirst(_ allowed: Bool) {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume(returning: allowed)
    }

    func releaseAll() {
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: false) }
    }
}

@MainActor
func makeModel(_ probe: TranslatorProbe, context: Bool = false) -> CaptionModel {
    let model = CaptionModel(translationOverride: { source, isContext in
        try await probe.translate(source, context: isContext)
    })
    model.isChecking = false
    model.assetsReady = true
    model.contextCorrectionEnabled = context
    return model
}

@main @MainActor
struct AppModelChecks {
    static func main() async {
        let savedContextPreference = UserDefaults.standard.object(forKey: "contextCorrectionEnabled")
        defer {
            if let savedContextPreference {
                UserDefaults.standard.set(savedContextPreference, forKey: "contextCorrectionEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled")
            }
        }
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("a canceled startup cannot resurrect itself or overwrite a newer startup", {
                let permission = PermissionProbe()
                defer { permission.releaseAll() }
                let model = CaptionModel(microphoneAccessOverride: { await permission.request() })
                let savedInput = model.selectedDeviceUID
                defer { model.selectedDeviceUID = savedInput }
                model.selectedDeviceUID = ""
                model.isChecking = false
                model.assetsReady = true
                let oldStart = Task { await model.start() }
                try await waitUntil("Initial startup did not reach permission wait") { permission.calls == 1 && model.phase == .starting }
                await model.stop()
                try expect(model.phase == .idle && model.canStart, "Canceling startup left controls blocked")
                let newStart = Task { await model.start() }
                try await waitUntil("New startup did not reach permission wait") { permission.calls == 2 && model.phase == .starting }
                permission.releaseFirst(true)
                await oldStart.value
                try expect(model.phase == .starting && model.message == nil, "Old startup modified the newer run")
                permission.releaseFirst(false)
                await newStart.value
                try expect(model.phase == .idle && !model.hasPendingTranslations, "Denied new startup did not clean up")
                try expect(model.message?.contains("마이크 접근") == true, "New startup permission error was lost")
                try expect(model.segments.isEmpty, "Startup cancellation invented caption content")
            }),
            ("finals preempt a stuck draft, coalesce revisions, and beat queued drafts", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Old draft", "First final."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Old draft", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("First draft never started") { probe.calls.count == 1 }
                model.receive(source: "Updated draft", audioStart: 0, audioEnd: 2, isFinal: false)
                model.receive(source: "First final.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Final remained blocked behind a canceled draft", seconds: 1) {
                    probe.calls.contains(.init(source: "First final.", context: false))
                }
                model.receive(source: "Newest draft", audioStart: 3, audioEnd: 4, isFinal: false)
                model.receive(source: "Second final.", audioStart: 4, audioEnd: 5, isFinal: true)
                probe.release(source: "First final.", translation: "첫 확정 문장.")
                try await waitUntil("Second final never translated") {
                    probe.calls.contains(.init(source: "Second final.", context: false))
                }
                let finalIndex = probe.calls.firstIndex(of: .init(source: "Second final.", context: false))!
                if let draftIndex = probe.calls.firstIndex(of: .init(source: "Newest draft", context: false)) {
                    try expect(finalIndex < draftIndex, "Queued draft ran before queued final")
                }
                probe.release(source: "Old draft", translation: "잘못된 이전 번역")
                try await waitUntil("Draft revisions did not finish", seconds: 3) { !model.hasPendingTranslations }
                try expect(model.segments.first?.source == "Updated draft", "Draft source was lost")
                try expect(model.segments.first?.translation == "KO: Updated draft", "Late draft overwrote current text")
                try expect(model.queuedTranslations == 0, "Queue counter stayed nonzero after drain")
                try expect(!probe.calls.contains(.init(source: "Old draft", context: true)), "Context ran while disabled")
            }),
            ("an unchanged in-flight draft becomes final without a second call", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Hello."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: false)
                try await waitUntil("Draft never started") { probe.calls.count == 1 }
                model.receive(source: "Hello.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await Task.sleep(for: .milliseconds(50))
                try expect(probe.calls.count == 1, "ASR confirmation repeated or preempted matching translation")
                probe.release(source: "Hello.", translation: "안녕하세요.")
                try await waitUntil("Confirmed in-flight draft did not finalize") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 1, "Matching final queued a redundant translation")
            }),
            ("context goes gray, corrects earlier Korean, and preserves ASR records", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "I saw her duck.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("First final did not translate") { model.segments.first?.isFinal == true }
                model.receive(source: "She bent down to avoid the ball.", audioStart: 1, audioEnd: 3, isFinal: true)
                try await waitUntil("Context was not scheduled") { probe.calls.contains(where: \.context) }
                let originals = model.segments
                try expect(model.displaySegments.allSatisfy(\.contextIsPending), "Context work was not shown as pending")
                try expect(model.displaySegments.allSatisfy { !$0.isFinal }, "Pending context stayed final-colored")
                probe.release(context: true, translation: "그녀가 공을 피하려고 몸을 숙이는 모습을 봤습니다.")
                try await waitUntil("Context did not replace display passage") {
                    model.displaySegments.count == 1 && !model.hasPendingTranslations
                }
                try expect(model.segments == originals, "Context changed stable ASR records")
                try expect(model.displaySegments[0].isFinal, "Completed context stayed gray")
                try expect(model.displaySegments[0].contextSegmentCount == 2, "Passage membership lost")
                try expect(model.displaySegments[0].translation == "그녀가 공을 피하려고 몸을 숙이는 모습을 봤습니다.",
                           "Earlier Korean was not reconsidered")
            }),
            ("a new final preempts uncooperative context and rejects its late result", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("First context never started") { probe.calls.contains(where: \.context) }
                let oldContextSource = "First. Second."
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("New final blocked behind stale context", seconds: 1) {
                    probe.calls.contains(.init(source: "Third.", context: false))
                }
                probe.release(source: oldContextSource, context: true, translation: "늦은 이전 문맥 결과")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "늦은 이전 문맥 결과" },
                           "Late superseded context changed captions")
                model.contextCorrectionEnabled = false
                try await waitUntil("Disabling context did not clear pending display", seconds: 1) {
                    !model.displaySegments.contains(where: \.contextIsPending) && !model.hasPendingTranslations
                }
                probe.release(context: true, translation: "설정 해제 후 도착한 결과")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "설정 해제 후 도착한 결과" },
                           "Disabled context still replaced captions")
            }),
            ("a new conversation rejects late old worker output", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Old conversation."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.receive(source: "Old conversation.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Old worker never started") { probe.calls.count == 1 }
                model.newSession()
                model.receive(source: "New conversation.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("New worker failed to finish") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                probe.release(source: "Old conversation.", translation: "이전 대화의 늦은 번역")
                try await Task.sleep(for: .milliseconds(50))
                try expect(model.segments.count == 1 && model.segments[0].source == "New conversation.", "Old conversation reappeared")
                try expect(model.segments[0].translation == "KO: New conversation.", "Old worker polluted new translation")
                try expect(model.segments[0].translationError == nil, "Old worker polluted new error state")
                try expect(model.queuedTranslations == 0 && !model.hasPendingTranslations, "Old worker left scheduling state stuck")
            }),
            ("failed final translations retry through the production scheduler", {
                let probe = TranslatorProbe()
                probe.failuresRemaining["Retry me."] = 1
                let model = makeModel(probe)
                model.receive(source: "Retry me.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Injected failure did not finish") {
                    model.segments.first?.translationError != nil && !model.hasPendingTranslations
                }
                try expect(model.segments.first?.isFinal == false, "Failed final appeared complete")
                model.retryFailedTranslations()
                try await waitUntil("Retry did not recover exact final revision") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 2, "Retry did not make exactly one replacement call")
                try expect(model.segments.first?.translationError == nil, "Successful retry kept failure state")
                try expect(model.message == nil, "Successful retry kept a stale translation-failure warning")
            }),
            ("unexpected framework cancellation leaves the current final retryable", {
                let probe = TranslatorProbe()
                probe.cancellationsRemaining["Canceled final."] = 1
                let model = makeModel(probe)
                model.receive(source: "Canceled final.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Unexpected cancellation vanished without a retryable failure") {
                    model.segments.first?.translationError != nil && !model.hasPendingTranslations
                }
                try expect(model.segments.first?.isFinal == false, "Canceled final was presented as complete")
                model.retryFailedTranslations()
                try await waitUntil("Unexpectedly canceled final could not recover") {
                    model.segments.first?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.count == 2, "Canceled source was not retried exactly once")
                try expect(model.segments.first?.translation == "KO: Canceled final.", "Retry used wrong source text")
            }),
            ("optional context failure preserves exact translations and later context recovers", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Optional context never started") { probe.calls.contains(where: \.context) }
                let originalTranslations = model.segments.map(\.translation)
                probe.failHeldContexts()
                try await waitUntil("Optional context failure left the display pending") { !model.hasPendingTranslations }
                try expect(model.displaySegments.allSatisfy(\.isFinal), "Optional context failure invalidated exact translations")
                try expect(model.segments.map(\.translation) == originalTranslations, "Optional failure erased valid Korean")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Optional failure appeared as isolated translation failure")
                probe.holdContexts = false
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Following context did not recover after optional failure") {
                    !model.hasPendingTranslations && model.displaySegments.contains { $0.contextSegmentCount == 2 }
                }
                try expect(probe.calls.filter(\.context).count == 2, "Later context was not retried after ordinary failure")
            }),
            ("context timeout clears gray state, reports degradation, and keeps live translation working", {
                let probe = TranslatorProbe()
                probe.holdContexts = true
                defer { probe.releaseAll() }
                let model = makeModel(probe, context: true)
                model.receive(source: "First.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second.", audioStart: 1, audioEnd: 2, isFinal: true)
                try await waitUntil("Timeout fixture context never started") { probe.calls.contains(where: \.context) }
                try await waitUntil("Optional context timeout did not return", seconds: 5) { !model.hasPendingTranslations }
                try expect(model.displaySegments.allSatisfy(\.isFinal), "Context timeout left gray or unfinished captions")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Context timeout damaged validated translations")
                try expect(model.message?.contains("문맥 보정이 지연") == true, "Disabled correction after timeout was hidden")
                model.receive(source: "Third.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Caption translation did not continue after context timeout") {
                    model.segments.last?.isFinal == true && !model.hasPendingTranslations
                }
                try expect(probe.calls.filter(\.context).count == 1, "Timed-out correction kept blocking this run")
                probe.release(context: true, translation: "시간 초과 뒤 도착한 이전 문맥")
                try await Task.sleep(for: .milliseconds(50))
                try expect(!model.displaySegments.contains { $0.translation == "시간 초과 뒤 도착한 이전 문맥" },
                           "Expired context changed completed captions")
            }),
            ("final overload stops input, preserves all sources, and retries every incomplete revision", {
                let probe = TranslatorProbe()
                probe.heldSources = ["Final 0."]
                defer { probe.releaseAll() }
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "Final 0.", audioStart: 0, audioEnd: 1, isFinal: true)
                try await waitUntil("Held final never started") { probe.calls.count == 1 }
                for index in 1...13 {
                    model.receive(source: "Final \(index).", audioStart: Double(index), audioEnd: Double(index + 1), isFinal: true)
                }
                try await waitUntil("Final queue overload did not stop input", seconds: 1) { model.phase != .listening }
                try await waitUntil("Overload stop never returned", seconds: 9) { model.phase == .idle && !model.hasPendingTranslations }
                let allSources = (0...13).map { "Final \($0)." }
                try expect(model.segments.map(\.source) == allSources, "Overload dropped a source-final caption")
                try expect(model.segments.allSatisfy { $0.translationError != nil && !$0.isFinal },
                           "Overload hid incomplete revisions or falsely finalized them")
                try expect(model.queuedTranslations == 0, "Overload left phantom queue items")
                probe.heldSources.removeAll()
                probe.release(source: "Final 0.", translation: "기한을 넘긴 결과")
                model.retryFailedTranslations()
                try expect(!model.canStart, "Capture was allowed to restart during recovery")
                try await waitUntil("Overload recovery did not retry all preserved sources", seconds: 3) {
                    model.segments.allSatisfy(\.isFinal) && !model.hasPendingTranslations
                }
                try expect(model.segments.map(\.source) == allSources, "Retry changed or dropped source text")
                try expect(model.segments[0].translation == "KO: Final 0.", "Late timed-out final replaced retry output")
                try expect(model.segments.allSatisfy { $0.translationError == nil }, "Retry left an incomplete error state")
            }),
            ("stopping has an overall deadline and retains incomplete source", {
                let probe = TranslatorProbe()
                probe.responseDelay = .seconds(4)
                let model = makeModel(probe)
                model.phase = .listening
                model.receive(source: "First pending.", audioStart: 0, audioEnd: 1, isFinal: true)
                model.receive(source: "Second pending.", audioStart: 1, audioEnd: 2, isFinal: true)
                model.receive(source: "Third pending.", audioStart: 2, audioEnd: 3, isFinal: true)
                try await waitUntil("Worker never started") { probe.calls.count == 1 }
                let began = ProcessInfo.processInfo.systemUptime
                await model.stop()
                let duration = ProcessInfo.processInfo.systemUptime - began
                try expect(duration < 9, "Stop blocked beyond its overall deadline")
                try expect(model.phase == .idle && !model.hasPendingTranslations, "Stop left controls or worker blocked")
                try expect(model.segments.map(\.source) == ["First pending.", "Second pending.", "Third pending."], "Stop dropped ASR source")
                try expect(model.segments.contains { $0.translationError != nil && !$0.isFinal }, "Incomplete source falsely finalized")
                try expect(model.queuedTranslations == 0, "Stop retained phantom queue items")
            }),
            ("deadline and cancellation return even when underlying work ignores cancellation", {
                let probe = TranslatorProbe()
                probe.heldSources = ["timeout", "cancel"]
                defer { probe.releaseAll() }
                let began = ProcessInfo.processInfo.systemUptime
                do {
                    _ = try await OperationDeadline.run(seconds: 0.04, name: "check") {
                        try await probe.translate("timeout", context: false)
                    }
                    throw ModelCheckFailure(description: "Deadline accepted an unfinished operation")
                } catch is OperationDeadline.Expired { }
                try expect(ProcessInfo.processInfo.systemUptime - began < 0.5, "Deadline waited for uncooperative work")
                let task = Task {
                    try await OperationDeadline.run(seconds: 10, name: "cancel check") {
                        try await probe.translate("cancel", context: false)
                    }
                }
                try await waitUntil("Cancellation fixture never started") { probe.calls.count == 2 }
                let canceledAt = ProcessInfo.processInfo.systemUptime
                task.cancel()
                do {
                    _ = try await task.value
                    throw ModelCheckFailure(description: "Canceled deadline returned success")
                } catch is CancellationError { }
                try expect(ProcessInfo.processInfo.systemUptime - canceledAt < 0.5, "Cancellation waited for uncooperative work")
            })
        ]
        do {
            for (name, check) in checks {
                try await check()
                print("PASS: \(name)")
            }
            print("\(checks.count) production model checks passed; no microphone or live engine accuracy was tested.")
        } catch {
            if let savedContextPreference {
                UserDefaults.standard.set(savedContextPreference, forKey: "contextCorrectionEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "contextCorrectionEnabled")
            }
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
