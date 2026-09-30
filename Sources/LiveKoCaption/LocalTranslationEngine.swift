import CaptionCore
import Darwin
import Foundation

struct LocalTranslationStatistics: Decodable, Sendable {
    var ttft_ms: Double?
    var total_ms: Double
    var prefill_ms: Double
    var decode_ms: Double
    var prompt_tokens: Int
    var output_tokens: Int
    var cancelled: Bool
    var timed_out: Bool
    var truncated: Bool
}

struct LocalTranslationResult: Sendable {
    var text: String
    var statistics: LocalTranslationStatistics
}

enum LocalTranslationError: LocalizedError {
    case unavailable, busy, notPrepared, native(Int32, String), unsafeOutput
    var errorDescription: String? {
        switch self {
        case .unavailable: return "로컬 보완 엔진을 사용할 수 없습니다. 최신 앱을 다시 열어 주세요."
        case .busy: return "이전 보완 작업을 정리 중입니다. 빠른 번역을 유지합니다."
        case .notPrepared: return "문맥 다듬기 모델을 먼저 준비해 주세요."
        case .native(let code, _): return code == 2 ? "문맥 다듬기가 지연돼 빠른 번역을 유지합니다." : "문맥 다듬기를 완료하지 못해 빠른 번역을 유지합니다."
        case .unsafeOutput: return "보완 결과의 형식이나 숫자가 달라 빠른 번역을 유지합니다."
        }
    }
}

/// One bounded serial worker owns the native context. C++ cancellation is scoped
/// to a request ID; a canceled Swift task never frees a still-running context.
final class LocalTranslationEngine: @unchecked Sendable {
    private typealias Load = @convention(c) (UnsafePointer<CChar>?, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32) -> UnsafeMutableRawPointer?
    private typealias Generate = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<CChar>?, Int32, Int32, UnsafeMutablePointer<CChar>?, Int32, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    private typealias Cancel = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private struct API: @unchecked Sendable { var load: Load; var generate: Generate; var cancel: Cancel; var free: Free }
    private let queue = DispatchQueue(label: "io.javis.caption.local-translation", qos: .userInitiated)
    private let lock = NSLock()
    private let runtimeURL: URL
    private var library: UnsafeMutableRawPointer?
    private var api: API?
    private var handle: UnsafeMutableRawPointer?
    private var preparedPath: String?
    private var nextID: UInt64 = 0
    private var activeID: UInt64?
    private var canceledID: UInt64?
    private var lifecycleRevision: UInt64 = 0
    private var desiredModelPath: String?

    init(runtimeURL: URL? = nil) {
        self.runtimeURL = runtimeURL ?? (Bundle.main.privateFrameworksURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks"))
            .appendingPathComponent("libcaption_local_translation.dylib")
    }

    var isPrepared: Bool { lock.withLock { handle != nil } }

    func prepare(modelURL: URL) async throws {
        try Task.checkCancellation()
        let revision = lock.withLock {
            lifecycleRevision &+= 1
            desiredModelPath = modelURL.path
            return lifecycleRevision
        }
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard lock.withLock({ lifecycleRevision == revision }) else { throw CancellationError() }
                    if lock.withLock({ preparedPath == modelURL.path && handle != nil }) {
                        continuation.resume(); return
                    }
                    let functions = try loadAPI()
                    var error = [CChar](repeating: 0, count: 1_024)
                    let loaded = modelURL.path.withCString { path in
                        error.withUnsafeMutableBufferPointer { functions.load(path, 99, 2_048, $0.baseAddress, 1_024) }
                    }
                    guard let loaded else { throw LocalTranslationError.native(-1, Self.string(error)) }
                    let published = lock.withLock { () -> (Bool, UnsafeMutableRawPointer?) in
                        // Rapid off/on toggles coalesce. An already loaded file
                        // can serve the latest on request without loading twice.
                        guard desiredModelPath == modelURL.path else { return (false, nil) }
                        let old = handle
                        handle = loaded
                        preparedPath = modelURL.path
                        return (true, old)
                    }
                    guard published.0 else { functions.free(loaded); throw CancellationError() }
                    if let old = published.1 { functions.free(old) }
                    guard lock.withLock({ lifecycleRevision == revision }) else { throw CancellationError() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
    }

    func translate(_ request: LocalTranslationRequest, timeoutMilliseconds: Int32 = 1_500,
                   validateResult: Bool = true) async throws -> LocalTranslationResult {
        try Task.checkCancellation()
        guard request.isWithinBudget else { throw LocalTranslationError.unsafeOutput }
        let id = try claim()
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    defer { release(id) }
                    do {
                        let snapshot = lock.withLock { (api, handle, canceledID == id) }
                        guard !snapshot.2 else { throw CancellationError() }
                        guard let functions = snapshot.0, let native = snapshot.1 else { throw LocalTranslationError.notPrepared }
                        var output = [CChar](repeating: 0, count: 8_192)
                        var stats = [CChar](repeating: 0, count: 2_048)
                        let status = request.prompt.withCString { prompt in
                            output.withUnsafeMutableBufferPointer { out in
                                stats.withUnsafeMutableBufferPointer { json in
                                    functions.generate(native, id, prompt, 192, timeoutMilliseconds,
                                        out.baseAddress, Int32(out.count), json.baseAddress, Int32(json.count))
                                }
                            }
                        }
                        if status == 1 || lock.withLock({ canceledID == id }) { throw CancellationError() }
                        guard status == 0 else { throw LocalTranslationError.native(status, Self.string(stats)) }
                        let text = Self.string(output).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !validateResult || request.accepts(text) else { throw LocalTranslationError.unsafeOutput }
                        let measured = try JSONDecoder().decode(LocalTranslationStatistics.self, from: Data(Self.string(stats).utf8))
                        release(id)
                        continuation.resume(returning: LocalTranslationResult(text: text, statistics: measured))
                    } catch { release(id); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { [self] in cancel(id) }
    }

    func cancelActive() { if let id = lock.withLock({ activeID }) { cancel(id) } }

    func unload() {
        cancelActive()
        let revision = lock.withLock {
            lifecycleRevision &+= 1
            desiredModelPath = nil
            return lifecycleRevision
        }
        queue.async { [self] in
            let old = lock.withLock {
                guard lifecycleRevision == revision, desiredModelPath == nil else { return (nil, nil) as (UnsafeMutableRawPointer?, API?) }
                let old = (handle, api)
                handle = nil
                preparedPath = nil
                return old
            }
            if let handle = old.0, let api = old.1 { api.free(handle) }
        }
    }

    private func claim() throws -> UInt64 {
        try lock.withLock {
            guard handle != nil else { throw LocalTranslationError.notPrepared }
            guard activeID == nil else { throw LocalTranslationError.busy }
            nextID &+= 1
            activeID = nextID
            canceledID = nil
            return nextID
        }
    }
    private func cancel(_ id: UInt64) {
        lock.withLock {
            guard activeID == id else { return }
            canceledID = id
            if let api, let handle { api.cancel(handle, id) }
        }
    }
    private func release(_ id: UInt64) {
        lock.withLock {
            if activeID == id { activeID = nil; canceledID = nil }
        }
    }

    private func loadAPI() throws -> API {
        if let api { return api }
        guard let library = dlopen(runtimeURL.path, RTLD_NOW | RTLD_LOCAL) else { throw LocalTranslationError.unavailable }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let raw = dlsym(library, name) else { throw LocalTranslationError.unavailable }
            return unsafeBitCast(raw, to: T.self)
        }
        do {
            let functions = try API(load: symbol("lc_load", Load.self), generate: symbol("lc_translate", Generate.self),
                cancel: symbol("lc_cancel", Cancel.self), free: symbol("lc_free", Free.self))
            self.library = library
            lock.withLock { api = functions }
            return functions
        } catch { dlclose(library); throw error }
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    deinit {
        // Queue closures retain this owner until native calls actually return.
        if let handle, let api { api.free(handle) }
        if let library { dlclose(library) }
    }
}
