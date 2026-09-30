import Foundation

@main @MainActor
struct LifecycleChecks {
    static func main() async throws {
        let value = try await OperationDeadline.run(seconds: 1, name: "test") { 42 }
        precondition(value == 42)

        // Continuation deliberately ignores cancellation, like a stalled system
        // service. Deadline must still return and cancel the framework once.
        var delayed: CheckedContinuation<Int, Never>?
        var canceled = 0
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let _: Int = try await OperationDeadline.run(seconds: 0.04, name: "stalled", onTimeout: { canceled += 1 }) {
                await withCheckedContinuation { delayed = $0 }
            }
            fatalError("Timeout accepted stalled work")
        } catch is OperationDeadline.Expired {}
        precondition(canceled == 1)
        precondition(ProcessInfo.processInfo.systemUptime - began < 1)
        delayed?.resume(returning: 9)
        await Task.yield()

        var canceledWork: CheckedContinuation<Int, Never>?
        let task = Task { try await OperationDeadline.run(seconds: 10, name: "canceled") {
            await withCheckedContinuation { canceledWork = $0 }
        } }
        while canceledWork == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation accepted work") }
        catch is CancellationError {}
        canceledWork?.resume(returning: 7)
        await Task.yield()
        print("3 lifecycle deadline checks passed.")
    }
}
