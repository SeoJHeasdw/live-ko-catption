import Foundation
@preconcurrency import Translation

/// Logical cancellation must not cancel Apple's session while its native await
/// is active: that can leave the await suspended permanently. Retire a lease
/// immediately, cancel its Swift task normally, and cancel the SDK session only
/// after every physical await exits. Admission counts survive retired leases
/// and app runs so a genuinely uncooperative call cannot grow without a bound.
@MainActor
final class TranslationSessionLease {
    enum Lane: Hashable, Sendable { case live, context }

    struct CapacityReached: LocalizedError {
        let lane: Lane
        var errorDescription: String? {
            "이전 번역 작업이 아직 종료되지 않아 새 번역을 시작할 수 없습니다. 잠시 기다린 뒤 다시 시도해 주세요."
        }
    }

    static let capacityPerLane = 2
    private static var physicalCounts: [Lane: Int] = [:]
    static var activeLiveCount: Int { activeCount(for: .live) }
    static var activeContextCount: Int { activeCount(for: .context) }
    static func activeCount(for lane: Lane) -> Int { physicalCounts[lane, default: 0] }

    let lane: Lane
    private(set) var isRetired = false
    private(set) var activeNativeCount = 0
    private var didCancelNative = false
    private let prepareNative: @MainActor () async throws -> Void
    private let translateNative: @MainActor (String) async throws -> String
    private let cancelNative: @MainActor () -> Void

    convenience init(installedSource: Locale.Language, target: Locale.Language,
                     preferredStrategy: TranslationSession.Strategy) {
        let session = TranslationSession(installedSource: installedSource, target: target,
                                         preferredStrategy: preferredStrategy)
        self.init(lane: preferredStrategy == .highFidelity ? .context : .live,
                  prepareNative: { try await session.prepareTranslation() },
                  translateNative: { try await session.translate($0).targetText },
                  cancelNative: { session.cancel() })
    }

    /// Inject the same physical-await boundary without requiring models or a
    /// microphone. Checks can deliberately hold native continuations forever.
    init(lane: Lane, prepareNative: @escaping @MainActor () async throws -> Void = {},
         translateNative: @escaping @MainActor (String) async throws -> String,
         cancelNative: @escaping @MainActor () -> Void) {
        self.lane = lane
        self.prepareNative = prepareNative
        self.translateNative = translateNative
        self.cancelNative = cancelNative
    }

    func prepareTranslation() async throws {
        try beginNativeAwait()
        defer { endNativeAwait() }
        try await prepareNative()
        try checkUsable()
    }

    func translate(_ source: String) async throws -> String {
        try beginNativeAwait()
        defer { endNativeAwait() }
        let text = try await translateNative(source)
        try checkUsable()
        return text
    }

    func retire() {
        isRetired = true
        cancelIfDrained()
    }

    private func checkUsable() throws {
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
    }

    private func beginNativeAwait() throws {
        try checkUsable()
        guard Self.activeCount(for: lane) < Self.capacityPerLane else {
            throw CapacityReached(lane: lane)
        }
        Self.physicalCounts[lane, default: 0] += 1
        activeNativeCount += 1
    }

    private func endNativeAwait() {
        Self.physicalCounts[lane, default: 0] -= 1
        activeNativeCount -= 1
        cancelIfDrained()
    }

    private func cancelIfDrained() {
        guard isRetired, activeNativeCount == 0, !didCancelNative else { return }
        didCancelNative = true
        cancelNative()
    }
}
