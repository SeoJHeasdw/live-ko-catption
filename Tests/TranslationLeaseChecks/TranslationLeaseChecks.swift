import Foundation

private struct LeaseCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class NativeProbe {
    weak var lease: TranslationSessionLease?
    var holdTranslation = false
    var holdPreparation = false
    var failTranslation = false
    var translationCalls = 0
    var preparationCalls = 0
    var cancelCalls = 0
    var canceledWhileActive = false
    private var translations: [String: CheckedContinuation<String, any Error>] = [:]
    private var preparation: CheckedContinuation<Void, any Error>?

    func makeLease(lane: TranslationSessionLease.Lane = .live) -> TranslationSessionLease {
        let created = TranslationSessionLease(lane: lane,
            prepareNative: { try await self.prepare() },
            translateNative: { try await self.translate($0) },
            cancelNative: { self.cancel() })
        lease = created
        return created
    }

    private func prepare() async throws {
        preparationCalls += 1
        if holdPreparation {
            try await withCheckedThrowingContinuation { preparation = $0 }
        }
    }

    private func translate(_ source: String) async throws -> String {
        translationCalls += 1
        if failTranslation { throw LeaseCheckFailure(description: "Injected native failure") }
        if holdTranslation {
            return try await withCheckedThrowingContinuation { translations[source] = $0 }
        }
        return "KO: \(source)"
    }

    private func cancel() {
        cancelCalls += 1
        canceledWhileActive = canceledWhileActive || (lease?.activeNativeCount ?? 0) > 0
    }

    func release(_ source: String) { translations.removeValue(forKey: source)?.resume(returning: "Late: \(source)") }
    func releasePreparation() { let held = preparation; preparation = nil; held?.resume() }
    func releaseAll() {
        let held = translations; translations.removeAll()
        for (source, continuation) in held { continuation.resume(returning: "Late: \(source)") }
        releasePreparation()
    }
}

@main @MainActor
struct TranslationLeaseChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw LeaseCheckFailure(description: message) }
    }

    private static func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition() {
            try expect(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func expectCanceled(_ task: Task<String, any Error>) async throws {
        do { _ = try await task.value; throw LeaseCheckFailure(description: "Retired native output escaped the lease") }
        catch is CancellationError { }
    }

    static func main() async {
        do {
            try await checkDeferredCancellation()
            try await checkPhysicalAdmission()
            try await checkPreparation()
            try await checkMultipleAwaits()
            try await checkFailureCleanup()
            try expect(TranslationSessionLease.activeLiveCount == 0 && TranslationSessionLease.activeContextCount == 0,
                       "Lease checks left physically unfinished native work")
            print("5 translation lease checks passed. No Apple language engine or microphone was opened.")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func checkDeferredCancellation() async throws {
        let probe = NativeProbe(); probe.holdTranslation = true
        defer { probe.releaseAll() }
        let lease = probe.makeLease()
        let operation = Task { try await lease.translate("Held source") }
        try await waitFor("Native translate did not start") { probe.translationCalls == 1 }
        lease.retire(); operation.cancel()
        try expect(lease.isRetired && lease.activeNativeCount == 1 && probe.cancelCalls == 0,
                   "Retirement canceled the SDK before its native await returned")
        do { _ = try await lease.translate("Rejected source"); throw LeaseCheckFailure(description: "Retired lease admitted work") }
        catch is CancellationError { }
        try expect(probe.translationCalls == 1, "Retired lease entered the native engine")
        probe.release("Held source")
        try await expectCanceled(operation)
        lease.retire()
        try expect(lease.activeNativeCount == 0 && probe.cancelCalls == 1 && !probe.canceledWhileActive,
                   "Drained retirement did not cancel the SDK exactly once")
        print("PASS: logical retirement is immediate; SDK cancellation waits for the actual await to exit")
    }

    private static func checkPhysicalAdmission() async throws {
        let firstProbe = NativeProbe(); firstProbe.holdTranslation = true
        let secondProbe = NativeProbe(); secondProbe.holdTranslation = true
        defer { firstProbe.releaseAll(); secondProbe.releaseAll() }
        let first = firstProbe.makeLease(), second = secondProbe.makeLease()
        let firstTask = Task { try await first.translate("First held") }
        let secondTask = Task { try await second.translate("Second held") }
        try await waitFor("Two physical awaits did not fill the lane") { TranslationSessionLease.activeLiveCount == 2 }
        first.retire(); second.retire(); firstTask.cancel(); secondTask.cancel()
        let replacementProbe = NativeProbe(), replacement = replacementProbe.makeLease()
        do { _ = try await replacement.translate("Blocked replacement"); throw LeaseCheckFailure(description: "Retired physical work did not occupy admission slots") }
        catch let error as TranslationSessionLease.CapacityReached { try expect(error.lane == .live, "Wrong capacity lane") }
        do { try await replacement.prepareTranslation(); throw LeaseCheckFailure(description: "Preparation bypassed the physical cap") }
        catch is TranslationSessionLease.CapacityReached { }
        try expect(replacementProbe.translationCalls == 0 && replacementProbe.preparationCalls == 0,
                   "Capacity rejection happened after native work entered")
        let contextProbe = NativeProbe(), context = contextProbe.makeLease(lane: .context)
        let contextText = try await context.translate("Independent context")
        try expect(contextText == "KO: Independent context", "Live capacity blocked the independent context lane")
        context.retire()
        firstProbe.release("First held"); try await expectCanceled(firstTask)
        let replacementText = try await replacement.translate("Recovered replacement")
        try expect(replacementText == "KO: Recovered replacement" && TranslationSessionLease.activeLiveCount == 1,
                   "Actual late completion did not free its global slot")
        secondProbe.release("Second held"); try await expectCanceled(secondTask)
        replacement.retire()
        print("PASS: physical admission stays bounded across retired/replacement leases; actual completion frees capacity")
    }

    private static func checkPreparation() async throws {
        let probe = NativeProbe(); probe.holdPreparation = true
        defer { probe.releaseAll() }
        let lease = probe.makeLease()
        let operation = Task { try await lease.prepareTranslation() }
        try await waitFor("Native preparation did not start") { probe.preparationCalls == 1 }
        lease.retire(); operation.cancel()
        try expect(TranslationSessionLease.activeLiveCount == 1 && probe.cancelCalls == 0,
                   "Preparation was not tracked as a physical await")
        probe.releasePreparation()
        do { try await operation.value; throw LeaseCheckFailure(description: "Retired preparation returned as usable") }
        catch is CancellationError { }
        try expect(probe.cancelCalls == 1 && !probe.canceledWhileActive && TranslationSessionLease.activeLiveCount == 0,
                   "Preparation exit did not release capacity before SDK cancellation")
        print("PASS: language preparation has the same physical-await retirement protection")
    }

    private static func checkMultipleAwaits() async throws {
        let probe = NativeProbe(); probe.holdTranslation = true
        defer { probe.releaseAll() }
        let lease = probe.makeLease(lane: .context)
        let first = Task { try await lease.translate("Context one") }
        let second = Task { try await lease.translate("Context two") }
        try await waitFor("Both context awaits did not start") { lease.activeNativeCount == 2 }
        let blockedProbe = NativeProbe(), blockedLease = blockedProbe.makeLease(lane: .context)
        do { _ = try await blockedLease.translate("Third context"); throw LeaseCheckFailure(description: "Context lane admitted a third physical await") }
        catch let error as TranslationSessionLease.CapacityReached { try expect(error.lane == .context, "Context capacity used the wrong lane") }
        try expect(blockedProbe.translationCalls == 0 && TranslationSessionLease.activeContextCount == 2,
                   "Context admission did not count outstanding work across leases")
        blockedLease.retire()
        lease.retire(); first.cancel(); second.cancel()
        probe.release("Context one"); try await expectCanceled(first)
        try expect(lease.activeNativeCount == 1 && probe.cancelCalls == 0,
                   "The first completion canceled a session with another await still active")
        probe.release("Context two"); try await expectCanceled(second)
        try expect(probe.cancelCalls == 1 && !probe.canceledWhileActive && TranslationSessionLease.activeContextCount == 0,
                   "The last physical completion did not finish retirement")
        print("PASS: retirement waits for every native await on the same lease")
    }

    private static func checkFailureCleanup() async throws {
        let probe = NativeProbe(); probe.failTranslation = true
        let lease = probe.makeLease()
        do { _ = try await lease.translate("Failing source"); throw LeaseCheckFailure(description: "Injected failure was lost") }
        catch let failure as LeaseCheckFailure { try expect(failure.description == "Injected native failure", "Unexpected injected failure") }
        try expect(lease.activeNativeCount == 0 && TranslationSessionLease.activeLiveCount == 0,
                   "Throwing native work leaked an admission slot")
        lease.retire(); lease.retire()
        try expect(probe.cancelCalls == 1 && !probe.canceledWhileActive,
                   "Inactive retirement did not cancel exactly once")
        print("PASS: native failures release slots; inactive retirement is idempotent")
    }
}
