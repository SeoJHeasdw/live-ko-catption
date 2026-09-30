import Foundation
@preconcurrency import Translation

private final class ProbeCancellation: @unchecked Sendable {
    let session: TranslationSession
    init(_ session: TranslationSession) { self.session = session }
    func cancel() { session.cancel() }
}

/// Isolates installed Apple Translation cancellation without CaptionModel,
/// speech input, microphone hardware, UI, or reusable-session accounting.
@main @MainActor struct CancellationProbe {
    static func main() async {
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "both"
        guard ["both", "session_only", "task_only", "none", "deferred_session"].contains(mode) else { exit(2) }
        let sourceLanguage = Locale.Language(identifier: "en")
        let targetLanguage = Locale.Language(identifier: "ko")
        guard await LanguageAvailability(preferredStrategy: .lowLatency).status(from: sourceLanguage, to: targetLanguage) == .installed else { print("SETUP_REQUIRED"); exit(2) }
        let began = ProcessInfo.processInfo.systemUptime
        var active: [Int: Double] = [:]
        var canceledReturned = 0
        var completedBeforeCancellation = 0
        var errors: [String] = []
        var cancellationErrors: [[String: Any]] = []
        var workers: [Task<Void, Never>] = []
        let repeats = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 1 : 1
        let rounds = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 24 : 24
        guard repeats > 0, repeats <= 50, rounds > 0, rounds <= 500 else { exit(2) }
        let source = String(repeating: "Please check the date carefully because the meeting is on Tuesday, not Thursday. ", count: repeats)
        var recoveryChecks = 0
        var maximumRecoverySeconds = 0.0
        for index in 0..<rounds {
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
            let cancellation = ProbeCancellation(session)
            active[index] = ProcessInfo.processInfo.systemUptime
            let worker = Task {
                defer {
                    active.removeValue(forKey: index)
                    if mode == "deferred_session" { cancellation.cancel() }
                }
                do {
                    _ = try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        let result = try await session.translate(source)
                        try Task.checkCancellation()
                        return result.targetText
                    } onCancel: { if mode == "both" || mode == "session_only" { cancellation.cancel() } }
                    completedBeforeCancellation += 1
                } catch {
                    canceledReturned += 1
                    cancellationErrors.append(["id": index, "task_is_canceled": Task.isCancelled, "error": error.localizedDescription])
                }
            }
            workers.append(worker)
            try? await Task.sleep(for: .milliseconds(8))
            if mode == "both" || mode == "task_only" || mode == "deferred_session" { worker.cancel() }
            if mode == "both" || mode == "session_only" { cancellation.cancel() }
            try? await Task.sleep(for: .milliseconds(12))
            // A representative short live-caption request separates each
            // preemption, preventing a burst of long decodes from confounding
            // cancellation with daemon/model resource saturation.
            let recovery = TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
            let recoveryBegan = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await OperationDeadline.run(seconds: 6, name: "between-cancellation recovery", onTimeout: { recovery.cancel() }) {
                    try await recovery.translate("We will continue the conversation now.").targetText
                }
                recoveryChecks += 1
                maximumRecoverySeconds = max(maximumRecoverySeconds, ProcessInfo.processInfo.systemUptime - recoveryBegan)
            } catch { errors.append("Round \(index) recovery failed: \(error.localizedDescription)"); break }
        }
        let nextSession = TranslationSession(installedSource: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
        var restartTarget: String?
        do {
            restartTarget = try await OperationDeadline.run(seconds: 6, name: "fresh translation after cancellations", onTimeout: { nextSession.cancel() }) {
                try await nextSession.translate("Thank you for joining us. We will continue the conversation now.").targetText
            }
        } catch { errors.append("Fresh request failed: \(error.localizedDescription)") }
        for _ in 0..<100 where !active.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let report: [String: Any] = ["mode": "isolated installed Apple Translation, fresh session for each forcibly canceled request", "cancellation_mode": mode,
            "returned_cancellation_errors": cancellationErrors,
            "requested_cancellations": workers.count, "successful_between_round_recoveries": recoveryChecks,
            "maximum_between_round_recovery_seconds": maximumRecoverySeconds,
            "source_character_count": source.count, "canceled_requests_returned": canceledReturned,
            "completed_before_cancellation": completedBeforeCancellation, "active_requests": active.map { id, start in
                ["id": id, "age_seconds": ProcessInfo.processInfo.systemUptime - start] as [String: Any]
            }, "fresh_restart_korean": restartTarget as Any? ?? NSNull(), "errors": errors,
            "wall_seconds": ProcessInfo.processInfo.systemUptime - began,
            "passed": active.isEmpty && errors.isEmpty && restartTarget != nil]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if CommandLine.arguments.count >= 2 { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
        if !active.isEmpty || !errors.isEmpty || restartTarget == nil { exit(1) }
    }
}
