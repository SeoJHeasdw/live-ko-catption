import CryptoKit
import Foundation
import Observation

/// The download is optional and starts only after an explicit user action.
/// Every installed file must match the immutable official LFS digest below.
@MainActor @Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    private(set) var isInstalled = false
    private(set) var isDownloading = false
    private(set) var isVerifying = false
    private(set) var progress: Double?
    private(set) var message = "문맥 다듬기 모델을 한 번 다운로드하면 오프라인으로 사용할 수 있습니다."

    var modelURL: URL? { isInstalled ? installedURL : nil }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let manifest: LocalModelManifest
    @ObservationIgnored private var validatedStamp: LocalModelFileStamp?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var downloadOperation: LocalModelDownload?
    @ObservationIgnored private var cancellation: LocalModelCancellation?

    private var installedURL: URL { directory.appendingPathComponent(manifest.filename) }

    init(directory: URL? = nil, manifest: LocalModelManifest = .hyMT2) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Live Korean Captions/Models", isDirectory: true)
        self.manifest = manifest
    }

    /// Checks the local file only. Hashing is streamed on a background task.
    /// A previously verified, unchanged file is not hashed again in this process.
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        guard !isDownloading else { return }
        let id = UUID()
        let flag = LocalModelCancellation()
        operationID = id
        cancellation = flag
        isVerifying = true
        isInstalled = false
        message = "로컬 문맥 다듬기 모델 확인 중"
        let file = installedURL
        let descriptor = manifest
        let cached = validatedStamp
        let task = Task {
            let result = await Self.verify(file: file, manifest: descriptor, cached: cached, cancellation: flag)
            guard self.operationID == id else { return }
            self.operationID = nil
            self.cancellation = nil
            self.isVerifying = false
            switch result {
            case .success(let stamp):
                self.validatedStamp = stamp
                self.isInstalled = true
                self.message = "문맥 다듬기 모델 준비됨 · 로컬 실행"
            case .failure(let error):
                self.validatedStamp = nil
                self.message = error.localizedDescription
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func requestDownload() {
        guard !isInstalled, !isDownloading, !isVerifying else { return }
        let id = UUID()
        let flag = LocalModelCancellation()
        operationID = id
        cancellation = flag
        isDownloading = true
        progress = 0
        message = "문맥 다듬기 모델 다운로드 중 · 약 1.47 GB"
        let stagingURL = directory.appendingPathComponent(".\(manifest.filename).\(id.uuidString).partial")
        let targetURL = installedURL
        let descriptor = manifest
        // The foreign-thread delegate is constructed outside MainActor isolation.
        let transfer = LocalModelDownload.make(url: descriptor.downloadURL, stagingURL: stagingURL,
                                              maximumBytes: descriptor.byteCount) { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id, !self.isVerifying else { return }
                self.progress = value
            }
        }
        downloadOperation = transfer
        operationTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            do {
                let file = try await transfer.download()
                guard let self, self.operationID == id else { return }
                self.isVerifying = true
                self.progress = nil
                self.message = "다운로드한 모델의 무결성 확인 중"
                let result = await Self.verify(file: file, manifest: descriptor, cached: nil, cancellation: flag)
                let stamp = try result.get()
                try flag.check()
                guard self.operationID == id else { return }
                // Staging and destination share a volume. POSIX rename replaces an
                // invalid old file atomically only after the new digest is verified.
                try Self.installVerified(file: file, target: targetURL)
                let installedStamp = try LocalModelFileStamp.read(targetURL)
                guard installedStamp.size == stamp.size else { throw LocalModelError.invalidSize }
                self.validatedStamp = installedStamp
                self.isInstalled = true
                self.finish(id: id, message: "문맥 다듬기 모델 준비됨 · 로컬 실행")
            } catch {
                guard let self, self.operationID == id else { return }
                self.validatedStamp = nil
                self.isInstalled = false
                self.finish(id: id, message: Self.downloadMessage(error))
            }
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        operationID = nil
        cancellation?.cancel()
        downloadOperation?.cancel()
        operationTask?.cancel()
        cancellation = nil
        downloadOperation = nil
        operationTask = nil
        isDownloading = false
        isVerifying = false
        progress = nil
        message = "모델 다운로드를 취소했습니다."
    }

    private func finish(id: UUID, message: String) {
        guard operationID == id else { return }
        operationID = nil
        operationTask = nil
        downloadOperation = nil
        cancellation = nil
        isDownloading = false
        isVerifying = false
        progress = nil
        self.message = message
    }

    private nonisolated static func downloadMessage(_ error: any Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "모델 다운로드를 취소했습니다."
        }
        return "모델을 준비하지 못했습니다: \(error.localizedDescription) 다시 다운로드할 수 있습니다."
    }

    private nonisolated static func verify(file: URL, manifest: LocalModelManifest,
                                           cached: LocalModelFileStamp?, cancellation: LocalModelCancellation)
        async -> Result<LocalModelFileStamp, any Error> {
        await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                Result {
                    try cancellation.check()
                    let stamp = try LocalModelFileStamp.read(file)
                    guard stamp.size == manifest.byteCount else { throw LocalModelError.invalidSize }
                    if stamp == cached { return stamp }
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while true {
                        try cancellation.check()
                        let data = try handle.read(upToCount: 1_048_576) ?? Data()
                        if data.isEmpty { break }
                        hasher.update(data: data)
                    }
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    guard digest == manifest.sha256 else { throw LocalModelError.invalidDigest }
                    // Do not cache a hash if the file changed while it was read.
                    guard try LocalModelFileStamp.read(file) == stamp else { throw LocalModelError.changedDuringVerification }
                    return stamp
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private nonisolated static func installVerified(file: URL, target: URL) throws {
        let status = file.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return rename(source, destination)
            }
        }
        guard status == 0 else { throw LocalModelError.installFailed }
    }
}

struct LocalModelManifest: Sendable {
    let filename: String
    let downloadURL: URL
    let byteCount: UInt64
    let sha256: String

    static let hyMT2 = LocalModelManifest(
        filename: "Hy-MT2-1.8B-Q6_K.gguf",
        downloadURL: URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/a0c709d9fac510f2c807aa3af52872340dc37a4a/Hy-MT2-1.8B-Q6_K.gguf")!,
        byteCount: 1_474_785_120,
        sha256: "d98fe604dec1f28f58f80d7d560f7177e584d3b8e5835862687660e5ff97cb40"
    )
}

private struct LocalModelFileStamp: Equatable, Sendable {
    let size: UInt64
    let modificationTime: TimeInterval
    let inode: UInt64

    static func read(_ file: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { throw LocalModelError.notInstalled }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw LocalModelError.invalidFile }
        return Self(size: size.uint64Value, modificationTime: date.timeIntervalSince1970, inode: inode.uint64Value)
    }
}

private enum LocalModelError: LocalizedError, Sendable {
    case notInstalled, invalidFile, invalidSize, invalidDigest, changedDuringVerification, installFailed
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "문맥 다듬기 모델이 없습니다. 처음 한 번 다운로드가 필요합니다."
        case .invalidFile: return "모델 파일을 읽을 수 없습니다. 다시 다운로드해 주세요."
        case .invalidSize: return "모델 파일 크기가 올바르지 않습니다. 다시 다운로드해 주세요."
        case .invalidDigest: return "모델 파일의 무결성 확인에 실패했습니다. 다시 다운로드해 주세요."
        case .changedDuringVerification: return "확인 중 모델 파일이 변경되었습니다. 다시 확인해 주세요."
        case .installFailed: return "모델을 저장하지 못했습니다. 저장 공간과 폴더 권한을 확인해 주세요."
        case .httpStatus(let status): return "모델 다운로드 서버에서 오류가 발생했습니다 (HTTP \(status))."
        }
    }
}

private final class LocalModelCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Delegate callbacks never inherit MainActor isolation. The lock protects only
/// completion/progress bookkeeping; downloading and file moves stay off the UI.
private final class LocalModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let stagingURL: URL
    private let maximumBytes: UInt64
    private let onProgress: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finished = false
    private var staged = false
    private var stagingError: (any Error)?
    private var lastProgressTime: TimeInterval = -.infinity

    nonisolated static func make(url: URL, stagingURL: URL, maximumBytes: UInt64,
                                onProgress: @escaping @Sendable (Double?) -> Void) -> LocalModelDownload {
        LocalModelDownload(url: url, stagingURL: stagingURL, maximumBytes: maximumBytes, onProgress: onProgress)
    }

    private init(url: URL, stagingURL: URL, maximumBytes: UInt64, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.url = url
        self.stagingURL = stagingURL
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
    }

    func download() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in start(continuation) }
        } onCancel: {
            self.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<URL, any Error>) {
        do {
            try FileManager.default.createDirectory(at: stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 1_800
            configuration.urlCredentialStorage = nil
            configuration.httpCookieStorage = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .utility
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.downloadTask(with: url)
            let canStart = lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                self.session = session
                self.task = task
                return true
            }
            if canStart { task.resume() }
            else {
                session.invalidateAndCancel()
                continuation.resume(throwing: CancellationError())
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten < 0 || UInt64(totalBytesWritten) > maximumBytes ||
            (totalBytesExpectedToWrite > 0 && UInt64(totalBytesExpectedToWrite) > maximumBytes) {
            lock.withLock { stagingError = LocalModelError.invalidSize }
            downloadTask.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReport = lock.withLock {
            guard !finished, !cancelled, now - lastProgressTime >= 0.25 else { return false }
            lastProgressTime = now
            return true
        }
        guard shouldReport else { return }
        let fraction = totalBytesExpectedToWrite > 0 ?
            min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) : nil
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else {
            lock.withLock { stagingError = URLError(.secureConnectionFailed) }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw LocalModelError.httpStatus((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            guard response.url?.scheme == "https" else { throw URLError(.secureConnectionFailed) }
            if lock.withLock({ cancelled }) { throw CancellationError() }
            try FileManager.default.moveItem(at: location, to: stagingURL)
            lock.withLock { staged = true }
        } catch {
            lock.withLock { stagingError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let completion: (CheckedContinuation<URL, any Error>?, Result<URL, any Error>)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let result: Result<URL, any Error>
            if cancelled { result = .failure(CancellationError()) }
            else if let stagingError { result = .failure(stagingError) }
            else if let error { result = .failure(error) }
            else if staged { result = .success(stagingURL) }
            else { result = .failure(LocalModelError.invalidFile) }
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            self.session = nil
            return (continuation, result)
        }
        guard let (continuation, result) = completion else { return }
        if case .failure = result { try? FileManager.default.removeItem(at: stagingURL) }
        continuation?.resume(with: result)
        session.finishTasksAndInvalidate()
    }
}
