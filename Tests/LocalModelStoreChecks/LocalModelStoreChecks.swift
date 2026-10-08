import CryptoKit
import Foundation

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
private struct LocalModelStoreChecks {
    @MainActor
    static func main() async {
        do {
            try await run()
            print("LocalModelStoreChecks passed: missing, valid, unchanged refresh, same-size corruption with restored mtime/inode, wrong size, cancellation cleanup, overlapping refresh.")
        } catch {
            FileHandle.standardError.write(Data("LocalModelStoreChecks failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("caption-model-store-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // No real model is downloaded. The reserved invalid.example URL must
        // never be reached: the explicit-download test cancels before yielding.
        let manifest = LocalModelManifest(filename: "fixture.gguf", downloadURL: URL(string: "https://invalid.example/model")!, byteCount: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let store = LocalModelStore(directory: folder, manifest: manifest)
        await store.refresh()
        try require(!store.isInstalled && !store.isDownloading && !store.isVerifying && store.modelURL == nil,
                    "Missing local file became ready or started a download.")

        let file = folder.appendingPathComponent(manifest.filename)
        try Data("abc".utf8).write(to: file)
        // An integral timestamp survives Foundation round trips exactly.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        await store.refresh()
        try require(store.isInstalled && store.modelURL == file && !store.isVerifying,
                    "Verified local file did not become ready.")
        await store.refresh()
        try require(store.isInstalled && store.modelURL == file,
                    "Unchanged verified file lost readiness on refresh.")

        let original = try FileManager.default.attributesOfItem(atPath: file.path)
        let overwritten = try FileHandle(forWritingTo: file)
        try overwritten.write(contentsOf: Data("def".utf8))
        try overwritten.close()
        try FileManager.default.setAttributes([.modificationDate: original[.modificationDate]!], ofItemAtPath: file.path)
        let restored = try FileManager.default.attributesOfItem(atPath: file.path)
        try require(original[.systemFileNumber] as? NSNumber == restored[.systemFileNumber] as? NSNumber &&
                    original[.size] as? NSNumber == restored[.size] as? NSNumber &&
                    original[.modificationDate] as? Date == restored[.modificationDate] as? Date,
                    "Fixture failed to preserve inode, size and mtime.")
        await store.refresh()
        try require(!store.isInstalled && store.modelURL == nil,
                    "A write with restored metadata bypassed the pinned digest.")

        try Data("abc".utf8).write(to: file)
        await store.refresh()
        try require(store.isInstalled, "Restoring pinned bytes did not recover model readiness.")

        try Data("def".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        await store.refresh()
        try require(!store.isInstalled && store.modelURL == nil,
                    "Same-size corrupted file bypassed digest verification.")
        try Data("wrong-size".utf8).write(to: file)
        await store.refresh()
        try require(!store.isInstalled && store.modelURL == nil,
                    "Wrong-sized file became ready.")

        // Settings learns the installed state without rehashing a model it has
        // already verified; only a refresh before loading rechecks the bytes.
        try Data("abc".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let settingsStore = LocalModelStore(directory: folder, manifest: manifest)
        try require(!settingsStore.isInstalled && !settingsStore.isVerifying,
                    "A new store claimed readiness or hashed before anything asked.")
        await settingsStore.refreshIfNeeded()
        try require(settingsStore.isInstalled && settingsStore.modelURL == file,
                    "The first Settings view did not verify the installed model.")
        try Data("def".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        await settingsStore.refreshIfNeeded()
        try require(settingsStore.isInstalled, "A later Settings view rehashed a model it had already verified.")
        await settingsStore.refresh()
        try require(!settingsStore.isInstalled && settingsStore.modelURL == nil,
                    "The refresh that precedes loading missed a changed model.")

        try FileManager.default.removeItem(at: file)
        store.requestDownload()
        try require(store.isDownloading, "Explicit download did not enter the in-progress state.")
        store.cancelDownload()
        try require(!store.isDownloading && !store.isVerifying && store.progress == nil && store.modelURL == nil,
                    "Cancellation left download/verification state active.")
        try await Task.sleep(for: .milliseconds(100))
        try require(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty,
                    "Canceled download left a staged partial file.")

        // A small streamed fixture is large enough to keep hashing active while
        // a second caller joins it. This reproduces the early-return readiness
        // race without reading or retaining a production 1.47 GB model.
        let overlapFile = folder.appendingPathComponent("overlap.gguf")
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        try Data().write(to: overlapFile)
        let writer = try FileHandle(forWritingTo: overlapFile)
        var hash = SHA256()
        for _ in 0..<32 {
            try writer.write(contentsOf: chunk)
            hash.update(data: chunk)
        }
        try writer.close()
        let overlapManifest = LocalModelManifest(filename: "overlap.gguf", downloadURL: manifest.downloadURL,
            byteCount: UInt64(chunk.count * 32), sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        let overlapping = LocalModelStore(directory: folder, manifest: overlapManifest)
        let first = Task { @MainActor in
            await overlapping.refresh()
            return overlapping.isInstalled && overlapping.modelURL == overlapFile
        }
        while !overlapping.isVerifying && !overlapping.isInstalled { await Task.yield() }
        try require(overlapping.isVerifying, "Overlap fixture finished before the second caller could exercise shared verification.")
        let second = Task { @MainActor in
            await overlapping.refresh()
            return overlapping.isInstalled && overlapping.modelURL == overlapFile
        }
        let secondReady = await second.value
        let firstReady = await first.value
        try require(firstReady && secondReady && !overlapping.isVerifying,
                    "One overlapping refresh returned before the model was validated and ready.")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
    }
}
