import Foundation

/// A system framework may ignore task cancellation. An unstructured race keeps
/// the UI responsive without waiting for that operation to cooperate. Callers
/// must invalidate their run/worker token before accepting any late result.
@MainActor
enum OperationDeadline {
    struct Expired: LocalizedError {
        let operation: String
        var errorDescription: String? { "\(operation) 응답 시간이 초과됐습니다." }
    }

    static func run<Value: Sendable>(seconds: Double, name: String,
        onTimeout: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                race.operation = Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.timer = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    guard race.continuation != nil else { return }
                    onTimeout()
                    race.finish(.failure(Expired(operation: name)))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    @MainActor private final class Race<Value: Sendable> {
        var continuation: CheckedContinuation<Value, any Error>?
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func finish(_ result: Result<Value, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            operation?.cancel()
            timer = nil
            operation = nil
            continuation.resume(with: result)
        }
    }
}
