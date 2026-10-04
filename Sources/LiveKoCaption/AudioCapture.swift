@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import OSLog
import Speech

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    /// A stored selection that means "what this Mac plays", not a device UID.
    static let systemAudioUID = "io.javis.live-ko-caption.system-audio"
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// HAL property reads can wait for an audio driver. Never enumerate on the
    /// UI actor, and admit only one hardware operation/session at a time.
    static func available() async throws -> [AudioInputDevice] {
        try await AudioHardwarePermit.perform(operation: "오디오 장치 확인") { try all() }
    }

    static func all() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try devices.withUnsafeMutableBytes { bytes in
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!))
        }
        return devices.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }
            return AudioInputDevice(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                                    name: stringProperty(id, kAudioObjectPropertyName))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        let storage = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        storage.initialize(to: nil)
        defer { storage.deinitialize(count: 1); storage.deallocate() }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr,
              let value = storage.pointee else { return "오디오 입력 \(id)" }
        // CoreAudio transfers ownership of these CFString properties to its caller.
        return value.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw CaptionError.message("오디오 장치를 확인할 수 없습니다 (\(status)).") }
    }
}

enum CaptionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// A stuck HAL call retains its permit until it actually returns. Retrying
/// therefore cannot create an unbounded collection of blocked control workers.
final class AudioHardwarePermit: @unchecked Sendable {
    private static let admissionLock = NSLock()
    nonisolated(unsafe) private static var occupied = false
    private static let controlQueue = DispatchQueue(label: "io.javis.live-ko-caption.hardware-control", qos: .userInitiated)
    private let releaseLock = NSLock()
    private var released = false
    var queue: DispatchQueue { Self.controlQueue }

    static func claim() throws -> AudioHardwarePermit {
        try admissionLock.withLock {
            guard !occupied else {
                throw CaptionError.message("이전 오디오 입력을 정리하거나 장치를 확인하는 중입니다. 잠시 뒤 다시 시작해 주세요.")
            }
            occupied = true
            return AudioHardwarePermit()
        }
    }

    static func perform<Value: Sendable>(seconds: Double = 3, operation: String,
        work: @escaping @Sendable () throws -> Value) async throws -> Value {
        let permit = try claim()
        let ticket = AudioControlTicket<Value>()
        permit.queue.async {
            let result: Result<Value, any Error>
            do { result = .success(try work()) }
            catch { result = .failure(error) }
            // A resumed caller may immediately start capture after enumeration.
            // Publish completion only after its temporary permit is available.
            permit.release()
            ticket.complete(result)
        }
        return try await ticket.value(seconds: seconds, operation: operation)
    }

    func release() {
        let release = releaseLock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if release { Self.admissionLock.withLock { Self.occupied = false } }
    }
}

/// Races a synchronous driver's eventual result without waiting for that driver
/// to honor task cancellation. Its caller keeps hardware resources/permits alive.
final class AudioControlTicket<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    @discardableResult
    func complete(_ result: Result<Value, any Error>) -> Bool {
        let completion = lock.withLock { () -> (Bool, CheckedContinuation<Value, any Error>?) in
            guard outcome == nil else { return (false, nil) }
            outcome = result
            let done = continuation
            continuation = nil
            return (true, done)
        }
        completion.1?.resume(with: result)
        return completion.0
    }

    func value(seconds: Double, operation: String,
               onAbandon: @escaping @Sendable () -> Void = {}) async throws -> Value {
        let timer = Task.detached { [self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if complete(.failure(CaptionError.message("\(operation) 응답 시간이 초과됐습니다."))) { onAbandon() }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                let ready = lock.withLock { () -> Result<Value, any Error>? in
                    if let outcome { return outcome }
                    precondition(continuation == nil, "A control ticket has only one waiter")
                    continuation = done
                    return nil
                }
                if let ready { done.resume(with: ready) }
            }
        } onCancel: { [self] in
            if complete(.failure(CancellationError())) { onAbandon() }
        }
    }
}

/// Owns buffers copied out of the audio tap. Conversion runs on one bounded queue,
/// rather than performing recognition or translation on the audio callback.
final class AudioPump: @unchecked Sendable {
    private enum FinishAction { case alreadyClosed, waitForDrain, closeNow }
    // Analyzer queue capacity must represent time, not the hardware callback
    // size. AUHAL commonly delivers 512 frames at 48 kHz (~94 callbacks/s).
    // Eight of those tiny buffers leave less than 90 ms of scheduling slack.
    // Accumulate 100 ms away from the callback before resampling/yielding.
    static let analyzerChunkDuration: TimeInterval = 0.1
    static let analyzerBufferLimit = 8
    private let queue = DispatchQueue(label: "io.javis.live-ko-caption.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var pendingInputFrames: Int64 = 0
    private var receivedInput = false
    static let startupInputWait: TimeInterval = 20
    static let runningInputWait: TimeInterval = 20
    private let startedAtUptime: TimeInterval
    private var lastInputUptime: TimeInterval
    private var acceptedInputFrames: Int64 = 0
    private var lastAudibleUptime: TimeInterval = 0
    private var finished = false
    private var closingScheduled = false
    private var closed = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var reportedProblem = false
    private var droppedBuffers = 0
    private var convertedBuffers = 0
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let sourceBatch: AVAudioPCMBuffer
    private let maximumPendingInputFrames: Int64
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private let onProblem: @Sendable (String) -> Void
    private let copyBuffer: @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    private var nextFrame: Int64 = 0
    private var lastMeterTime: TimeInterval = 0
    private var nextInputSequence = 0
    // Only the conversion queue accesses completed copies. Reservations stay
    // pending until consumed, so a slow earlier copy cannot grow this map.
    private enum CopiedInput: @unchecked Sendable { case buffer(AVAudioPCMBuffer, Int64), skipped(Int64) }
    private var completedCopies: [Int: CopiedInput] = [:]
    private var nextCopyToConsume = 0

    init(source: AVAudioFormat, target: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Double) -> Void,
         onProblem: @escaping @Sendable (String) -> Void,
         copyBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer? = AudioPump.copy,
         startedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptionError.message("이 마이크의 음성 형식을 변환할 수 없습니다.")
        }
        let batchFrames = AVAudioFrameCount(max(1, (source.sampleRate * Self.analyzerChunkDuration).rounded()))
        guard let sourceBatch = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: batchFrames) else {
            throw CaptionError.message("마이크 입력을 모을 메모리가 부족합니다.")
        }
        // The converter defaults to remapping, which selects only channel 0
        // for mono output. A stereo receiver carrying the speaker on its right
        // channel must remain audible to recognition.
        converter.downmix = source.channelCount > target.channelCount
        self.converter = converter
        self.sourceFormat = source
        self.sourceBatch = sourceBatch
        self.maximumPendingInputFrames = Int64(source.sampleRate / 2)
        self.target = target
        self.continuation = continuation
        self.onLevel = onLevel
        self.onProblem = onProblem
        self.copyBuffer = copyBuffer
        self.lastInputUptime = startedAtUptime
        self.startedAtUptime = startedAtUptime
    }

    // AVAudioNodeTapBlock is nonsendable in the SDK. Creating it inside the
    // @MainActor capture controller would infer MainActor isolation and trap
    // when AVAudioEngine invokes it on its real-time messenger queue.
    // Construct it here, in a nonisolated context, capturing only the pump.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in enqueue(buffer) }
    }

    var bufferCount: Int { lock.withLock { convertedBuffers } }
    var droppedBufferCount: Int { lock.withLock { droppedBuffers } }
    var hasReceivedInput: Bool { lock.withLock { receivedInput } }

    func hasStalledInput(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            !finished && (receivedInput
                ? uptime - lastInputUptime > Self.runningInputWait
                : uptime - startedAtUptime > Self.startupInputWait)
        }
    }

    /// Whether the source carried sound above the meter floor recently. A tap
    /// keeps delivering digital silence after playback ends, so buffer arrival
    /// alone does not show that something is playing.
    func hasAudibleInput(within seconds: TimeInterval, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { lastAudibleUptime > 0 && uptime - lastAudibleUptime <= seconds }
    }

    /// Computer sound delivers no buffers while nothing plays. One chunk of
    /// silence per idle chunk interval keeps recognition time moving, so a
    /// last sentence can finalize and a quiet source is not a stalled device.
    func enqueueSilenceIfIdle(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        guard !finished, uptime - lastInputUptime >= Self.analyzerChunkDuration else { lock.unlock(); return }
        // Fill elapsed time, including early/late timer ticks, rather than
        // emitting one fixed chunk and resetting a 100 ms threshold each tick.
        let elapsedFrames = floor(max(0, uptime - startedAtUptime) * sourceFormat.sampleRate + 0.000001)
        let owed = max(0, elapsedFrames - Double(acceptedInputFrames))
        let frameCount = Int64(min(owed, Double(maximumPendingInputFrames)))
        guard frameCount > 0 else { lock.unlock(); return }
        guard let sequence = reserveInput(frameCount: frameCount) else {
            lock.unlock()
            reportProblem("음성 처리가 밀려 일부 입력이 누락됐습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
            return
        }
        lock.unlock()
        guard let silence = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            submitCopy(.skipped(frameCount), sequence: sequence)
            lock.withLock { droppedBuffers += 1 }
            reportProblem("입력을 모을 메모리가 부족합니다.")
            return
        }
        silence.frameLength = AVAudioFrameCount(frameCount)
        for plane in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
        }
        // The timer owns this buffer already; there is no callback storage to copy.
        submitCopy(.buffer(silence, frameCount), sequence: sequence)
    }

    // Like the tap block, this handler runs on a foreign queue. Building it in
    // the @MainActor capture controller would infer MainActor isolation and
    // trap on its first tick. Construct it here, capturing only the pump.
    func makeSilenceTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + Self.analyzerChunkDuration, repeating: Self.analyzerChunkDuration)
        timer.setEventHandler { [self] in enqueueSilenceIfIdle() }
        return timer
    }

    func enqueue(_ original: AVAudioPCMBuffer, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard original.frameLength > 0 else { return }
        lock.lock()
        if finished { lock.unlock(); return }
        // This clock counts real hardware callbacks, including digital silence.
        // Synthesized idle silence must not claim that a device delivered input.
        lastInputUptime = uptime
        let frameCount = Int64(original.frameLength)
        guard let sequence = reserveInput(frameCount: frameCount) else {
            lock.unlock()
            reportProblem("음성 처리가 밀려 일부 입력이 누락됐습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
            return
        }
        receivedInput = true
        lock.unlock()

        guard original.format.isEqual(sourceFormat), let copy = copyBuffer(original) else {
            lock.withLock { droppedBuffers += 1 }
            submitCopy(.skipped(frameCount), sequence: sequence)
            reportProblem("마이크 입력을 읽을 수 없습니다. 입력 장치의 연결과 음성 형식을 확인해 주세요.")
            return
        }
        submitCopy(.buffer(copy, frameCount), sequence: sequence)
    }

    /// Called while holding lock, before a producer starts copying its buffer.
    private func reserveInput(frameCount: Int64) -> Int? {
        // Tap sizes can differ from the requested 1024 frames. Bound queued
        // audio by duration as well as count so a slow device does not create
        // several seconds of stale captions before overflow is noticed.
        guard pending < 32,
              pendingInputFrames + frameCount <= maximumPendingInputFrames else {
            droppedBuffers += 1
            return nil
        }
        pending += 1
        pendingInputFrames += frameCount
        acceptedInputFrames += frameCount
        let sequence = nextInputSequence
        nextInputSequence += 1
        return sequence
    }

    private func submitCopy(_ input: CopiedInput, sequence: Int) {
        queue.async { [self] in
            completedCopies[sequence] = input
            while let next = completedCopies.removeValue(forKey: nextCopyToConsume) {
                nextCopyToConsume += 1
                switch next {
                case .buffer(let copy, let frames):
                    consume(copy)
                    decrementPending(frameCount: frames)
                case .skipped(let frames): decrementPending(frameCount: frames)
                }
            }
        }
    }

    // A copied buffer is exclusively owned by the conversion queue. The
    // injectable copier lets the callback checks reproduce an in-flight copy
    // during stop without needing hardware timing or oversized allocations.
    static func copy(_ original: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: original.frameLength) else { return nil }
        copy.frameLength = original.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(original.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sources.count == destinations.count else { return nil }
        for index in sources.indices {
            guard sources[index].mDataByteSize <= destinations[index].mDataByteSize,
                  let source = sources[index].mData, let destination = destinations[index].mData else { return nil }
            memcpy(destination, source, Int(sources[index].mDataByteSize))
        }
        return copy
    }

    private func decrementPending(frameCount: Int64) {
        let shouldClose = lock.withLock {
            pending -= 1
            pendingInputFrames -= frameCount
            guard finished, pending == 0, !closingScheduled else { return false }
            closingScheduled = true
            return true
        }
        if shouldClose { queue.async { [self] in closeStream() } }
    }

    private func reportProblem(_ message: String) {
        let shouldReport = lock.withLock {
            guard !reportedProblem else { return false }
            reportedProblem = true
            return true
        }
        guard shouldReport else { return }
        // Do not create a MainActor Task or invoke client work from the tap.
        DispatchQueue.global(qos: .userInitiated).async { [onProblem] in onProblem(message) }
    }

    private func consume(_ source: AVAudioPCMBuffer) {
        let sources = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(sourceBatch.mutableAudioBufferList)
        let bytesPerFrame = Int(sourceFormat.streamDescription.pointee.mBytesPerFrame)
        var sourceOffset = 0
        while sourceOffset < Int(source.frameLength) {
            let destinationOffset = Int(sourceBatch.frameLength)
            let frames = min(Int(source.frameLength) - sourceOffset,
                             Int(sourceBatch.frameCapacity) - destinationOffset)
            for index in sources.indices {
                // copy() validated storage and formats before this queue owns
                // the input. Both interleaved and planar PCM use their format's
                // bytes-per-frame within each AudioBuffer plane.
                memcpy(destinations[index].mData!.advanced(by: destinationOffset * bytesPerFrame),
                       sources[index].mData!.advanced(by: sourceOffset * bytesPerFrame),
                       frames * bytesPerFrame)
            }
            sourceBatch.frameLength += AVAudioFrameCount(frames)
            sourceOffset += frames
            if sourceBatch.frameLength == sourceBatch.frameCapacity {
                convert(sourceBatch)
                sourceBatch.frameLength = 0
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterTime > 0.10, let level = Self.level(of: source) {
            lastMeterTime = now
            if level > 0.02 { lock.withLock { lastAudibleUptime = now } }
            onLevel(level)
        }
    }

    private func convert(_ source: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * target.sampleRate / source.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            lock.withLock { droppedBuffers += 1 }
            reportProblem("마이크 입력을 변환할 메모리가 부족합니다.")
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else {
            lock.withLock { droppedBuffers += 1 }
            reportProblem("마이크 입력을 변환하지 못했습니다. 입력 장치를 다시 선택해 주세요.")
            return
        }
        yield(output)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double? {
        guard buffer.floatChannelData != nil || buffer.int16ChannelData != nil else { return nil }
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        var largestRMS: Double = 0
        for channel in 0..<channels {
            var squares: Double = 0
            var sampled = 0
            for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                let index = interleaved ? frame * channels + channel : frame
                let plane = interleaved ? 0 : channel
                let sample: Double
                if let floats = buffer.floatChannelData { sample = Double(floats[plane][index]) }
                else if let integers = buffer.int16ChannelData { sample = Double(integers[plane][index]) / 32768 }
                else { continue }
                squares += sample * sample
                sampled += 1
            }
            largestRMS = max(largestRMS, sqrt(squares / Double(max(1, sampled))))
        }
        return min(1, max(0, (20 * log10(max(largestRMS, 0.00001)) + 60) / 60))
    }

    private func yield(_ output: AVAudioPCMBuffer) {
        guard output.frameLength > 0 else { return }
        lock.withLock { convertedBuffers += 1 }
        let startTime = CMTime(value: nextFrame, timescale: CMTimeScale(target.sampleRate))
        nextFrame += Int64(output.frameLength)
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: startTime)) {
            lock.withLock { droppedBuffers += 1 }
            reportProblem("음성 인식이 입력 속도를 따라가지 못해 일부 입력이 누락됐습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
        }
    }

    private func closeStream() {
        // Stop preserves the short final batch instead of requiring another
        // callback to fill it. Drain the resampler only after that source tail.
        if sourceBatch.frameLength > 0 {
            convert(sourceBatch)
            sourceBatch.frameLength = 0
        }
        // .noDataNow retains the resampler's trailing frames. End-of-stream
        // must be supplied after all accepted copies have been converted so
        // the final consonant is available to the speech analyzer.
        let capacity = AVAudioFrameCount(max(1, target.sampleRate / 10))
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                reportProblem("마지막 마이크 입력을 변환할 메모리가 부족합니다.")
                break
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || error != nil {
                reportProblem("마지막 마이크 입력을 변환하지 못했습니다.")
                break
            }
            yield(output)
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        continuation.finish()
        let waiters = lock.withLock {
            closed = true
            let waiting = finishWaiters
            finishWaiters.removeAll()
            return waiting
        }
        for waiter in waiters { waiter.resume() }
    }

    func finish() async {
        await withCheckedContinuation { done in
            let action = lock.withLock {
                finished = true
                guard !closed else { return FinishAction.alreadyClosed }
                finishWaiters.append(done)
                guard pending == 0, !closingScheduled else { return FinishAction.waitForDrain }
                closingScheduled = true
                return FinishAction.closeNow
            }
            if action == .alreadyClosed { done.resume() }
            else if action == .closeNow { queue.async { [self] in closeStream() } }
        }
    }
}

enum AudioCallbackBridge {
    // NotificationCenter can invoke this block on an internal audio queue.
    // Only the inner Task is MainActor-isolated; the foreign callback is not.
    static func configurationBlock(action: @escaping @MainActor @Sendable () -> Void)
        -> @Sendable (Notification) -> Void {
        { _ in Task { @MainActor in action() } }
    }
}

private final class AudioHardwareSession: @unchecked Sendable {
    struct Prepared: @unchecked Sendable {
        let stream: AsyncStream<AnalyzerInput>
        let pump: AudioPump
        let deviceID: AudioDeviceID
        let format: AVAudioFormat
        let timeOrigin: TimeInterval
    }
    private let permit: AudioHardwarePermit
    private let cancellationLock = NSLock()
    private var stopRequested = false
    private var startupTicket: AudioControlTicket<Prepared>?
    // The control queue exclusively owns these resources.
    private var source: AudioDeviceCapture?
    private var tap: SystemAudioTap?
    private var pump: AudioPump?
    private var cleaned = false
    private let stopped = AudioControlTicket<Void>()

    init() throws { permit = try AudioHardwarePermit.claim() }

    private func checkRunning() throws {
        if cancellationLock.withLock({ stopRequested }) { throw CancellationError() }
    }

    func prepare(deviceID: AudioDeviceID?, systemAudio: SystemAudioTap.Configuration?, target: AVAudioFormat,
                 onLevel: @escaping @Sendable (Double) -> Void,
                 onProblem: @escaping @Sendable (String) -> Void,
                 seconds: Double, beforeHardwarePrepare: (@Sendable () -> Void)?) async throws -> Prepared {
        let ticket = AudioControlTicket<Prepared>()
        cancellationLock.withLock { startupTicket = ticket }
        defer { cancellationLock.withLock { startupTicket = nil } }
        permit.queue.async { [self] in
            do {
                try checkRunning()
                beforeHardwarePrepare?()
                try checkRunning()
                if let systemAudio { tap = try SystemAudioTap(configuration: systemAudio) }
                try checkRunning()
                let device = try AudioDeviceCapture(deviceID: tap?.deviceID ?? deviceID)
                source = device
                try checkRunning()
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                    bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
                let timeOrigin = ProcessInfo.processInfo.systemUptime
                let audioPump = try AudioPump(source: device.format, target: target,
                    continuation: continuation, onLevel: onLevel, onProblem: onProblem,
                    startedAtUptime: timeOrigin)
                pump = audioPump
                try device.start(pump: audioPump, onProblem: onProblem)
                try checkRunning()
                if !ticket.complete(.success(Prepared(stream: stream, pump: audioPump,
                                                      deviceID: device.deviceID, format: device.format,
                                                      timeOrigin: timeOrigin))) {
                    requestStop()
                }
            } catch {
                ticket.complete(.failure(error))
                cleanup()
            }
        }
        return try await ticket.value(seconds: seconds, operation: "오디오 입력 시작", onAbandon: { [self] in requestStop() })
    }

    func configurationProblem() async throws -> String? {
        let ticket = AudioControlTicket<String?>()
        permit.queue.async { [self] in
            do {
                try checkRunning()
                ticket.complete(.success(source?.configurationProblem()))
            } catch { ticket.complete(.failure(error)) }
        }
        return try await ticket.value(seconds: 3, operation: "오디오 입력 상태 확인", onAbandon: { [self] in requestStop() })
    }

    func requestStop() {
        let request = cancellationLock.withLock { () -> (Bool, AudioControlTicket<Prepared>?) in
            guard !stopRequested else { return (false, nil) }
            stopRequested = true
            let ticket = startupTicket
            startupTicket = nil
            return (true, ticket)
        }
        request.1?.complete(.failure(CancellationError()))
        if request.0 { permit.queue.async { [self] in cleanup() } }
    }

    func stop() async {
        requestStop()
        // Hardware teardown may still be waiting after this returns. The permit
        // stays held, and cleanup completes automatically when the driver returns.
        _ = try? await stopped.value(seconds: 0.8, operation: "오디오 입력 정지")
    }

    private func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        source?.stop()
        source = nil
        tap?.destroy()
        tap = nil
        let closingPump = pump
        pump = nil
        permit.release()
        Task.detached { [stopped] in
            await closingPump?.finish()
            stopped.complete(.success(()))
        }
    }
}

@MainActor
final class AudioCapture {
    private static let logger = Logger(subsystem: "io.javis.live-ko-caption", category: "audio")
    private var hardwareSession: AudioHardwareSession?
    private var pump: AudioPump?
    private var silenceTimer: DispatchSourceTimer?
    private var watchdogTask: Task<Void, Never>?
    private(set) var deviceID: AudioDeviceID?
    private(set) var timeOrigin: TimeInterval?
    private let hardwareStartDeadline: Double
    private let beforeHardwarePrepare: (@Sendable () -> Void)?

    /// Checks inject a blocked control call before any microphone/tap is opened.
    init(hardwareStartDeadline: Double = 8, beforeHardwarePrepare: (@Sendable () -> Void)? = nil) {
        self.hardwareStartDeadline = hardwareStartDeadline
        self.beforeHardwarePrepare = beforeHardwarePrepare
    }

    deinit { hardwareSession?.requestStop() }

    /// Only option values cross the UI actor. HAL creation, startup, health
    /// queries and destruction all run on the admitted hardware control queue.
    func start(deviceID: AudioDeviceID?, systemAudio: SystemAudioTap.Configuration? = nil, target: AVAudioFormat,
               onLevel: @escaping @Sendable (Double) -> Void,
               onProblem: @escaping @Sendable (String) -> Void,
               onSourceActivity: (@MainActor @Sendable (Bool) -> Void)? = nil) async throws -> AsyncStream<AnalyzerInput> {
        guard hardwareSession == nil, pump == nil else {
            throw CaptionError.message("입력이 이미 실행 중입니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
        }
        let session = try AudioHardwareSession()
        hardwareSession = session
        let prepared: AudioHardwareSession.Prepared
        do {
            prepared = try await session.prepare(deviceID: deviceID, systemAudio: systemAudio,
                target: target, onLevel: onLevel, onProblem: onProblem,
                seconds: hardwareStartDeadline, beforeHardwarePrepare: beforeHardwarePrepare)
            try Task.checkCancellation()
            guard hardwareSession === session else { throw CancellationError() }
        } catch {
            session.requestStop()
            if hardwareSession === session { hardwareSession = nil }
            throw error
        }
        let audioPump = prepared.pump
        pump = audioPump
        self.deviceID = prepared.deviceID
        timeOrigin = prepared.timeOrigin
        if systemAudio != nil {
            let timer = audioPump.makeSilenceTimer()
            timer.resume()
            silenceTimer = timer
        }
        watchdogTask = Task { @MainActor [weak self] in
            var reportedFirstInput = false
            var sourceWasActive: Bool?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self, self.hardwareSession === session,
                      self.pump === audioPump else { return }
                let sourceIsActive = audioPump.hasAudibleInput(within: 1.5)
                if sourceIsActive != sourceWasActive {
                    sourceWasActive = sourceIsActive
                    onSourceActivity?(sourceIsActive)
                }
                if audioPump.hasReceivedInput && !reportedFirstInput {
                    reportedFirstInput = true
                    Self.logger.notice("Selected input receiving real hardware buffers: device=\(prepared.deviceID), convertedBuffers=\(audioPump.bufferCount)")
                }
                do {
                    let problem = try await session.configurationProblem()
                    guard !Task.isCancelled, self.hardwareSession === session else { return }
                    if let problem {
                        Self.logger.error("Selected input configuration changed: \(problem)")
                        onProblem(problem)
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.hardwareSession === session else { return }
                    onProblem(error.localizedDescription)
                    return
                }
                // A system tap normally has no callbacks during idle playback.
                // Its hardware running/alive state is checked separately above.
                guard systemAudio == nil, audioPump.hasStalledInput() else { continue }
                onProblem(audioPump.hasReceivedInput
                    ? "마이크의 오디오 입력이 20초 이상 중단됐습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요."
                    : "마이크 입력을 20초 동안 기다렸지만 연결되지 않았습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요.")
                return
            }
        }
        Self.logger.notice("Selected input started: device=\(prepared.deviceID), rate=\(prepared.format.sampleRate), channels=\(prepared.format.channelCount), target=\(target.sampleRate)")
        return prepared.stream
    }

    func stop() async {
        watchdogTask?.cancel(); watchdogTask = nil
        silenceTimer?.cancel(); silenceTimer = nil
        let closingSession = hardwareSession
        let closingPump = pump
        hardwareSession = nil; pump = nil; deviceID = nil; timeOrigin = nil
        await closingSession?.stop()
        Self.logger.notice("Input stop requested: convertedBuffers=\(closingPump?.bufferCount ?? 0), droppedBuffers=\(closingPump?.droppedBufferCount ?? 0)")
    }
}
