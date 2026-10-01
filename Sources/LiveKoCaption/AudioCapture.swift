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
    private let silentBatch: AVAudioPCMBuffer
    private let maximumPendingInputFrames: Int64
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private let onProblem: @Sendable (String) -> Void
    private let copyBuffer: @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer?
    private var nextFrame: Int64 = 0
    private var lastMeterTime: TimeInterval = 0

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
        guard let silentBatch = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: batchFrames) else {
            throw CaptionError.message("입력을 모을 메모리가 부족합니다.")
        }
        silentBatch.frameLength = batchFrames
        for plane in UnsafeMutableAudioBufferListPointer(silentBatch.mutableAudioBufferList) {
            if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
        }
        // The converter defaults to remapping, which selects only channel 0
        // for mono output. A stereo receiver carrying the speaker on its right
        // channel must remain audible to recognition.
        converter.downmix = source.channelCount > target.channelCount
        self.converter = converter
        self.sourceFormat = source
        self.sourceBatch = sourceBatch
        self.silentBatch = silentBatch
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
        guard lock.withLock({ !finished && uptime - lastInputUptime >= Self.analyzerChunkDuration }) else { return }
        enqueue(silentBatch, at: uptime)
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
        // Silence is healthy input. Only missing nonempty tap buffers indicate
        // a stalled device; the watchdog never depends on speech or loudness.
        lastInputUptime = uptime
        let frameCount = Int64(original.frameLength)
        // Tap sizes can differ from the requested 1024 frames. Bound queued
        // audio by duration as well as count so a slow device does not create
        // several seconds of stale captions before overflow is noticed.
        guard pending < 32,
              pendingInputFrames + frameCount <= maximumPendingInputFrames else {
            droppedBuffers += 1
            lock.unlock()
            reportProblem("음성 처리가 밀려 일부 입력이 누락됐습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
            return
        }
        pending += 1
        pendingInputFrames += frameCount
        receivedInput = true
        lock.unlock()

        guard original.format.isEqual(sourceFormat), let copy = copyBuffer(original) else {
            lock.withLock { droppedBuffers += 1 }
            decrementPending(frameCount: frameCount)
            reportProblem("마이크 입력을 읽을 수 없습니다. 입력 장치의 연결과 음성 형식을 확인해 주세요.")
            return
        }

        queue.async { [self, copy] in
            defer { decrementPending(frameCount: frameCount) }
            consume(copy)
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

@MainActor
final class AudioCapture {
    private static let logger = Logger(subsystem: "io.javis.live-ko-caption", category: "audio")
    private let stopQueue = DispatchQueue(label: "io.javis.live-ko-caption.device-stop")
    private var deviceCapture: AudioDeviceCapture?
    private var pump: AudioPump?
    private var systemAudio: SystemAudioTap?
    private var silenceTimer: DispatchSourceTimer?
    private var watchdogTask: Task<Void, Never>?

    /// A system audio tap replaces the microphone device for this run. This
    /// capture owns the tap and destroys it after the unit has stopped.
    func start(deviceID: AudioDeviceID?, systemAudio tap: SystemAudioTap? = nil, target: AVAudioFormat,
               onLevel: @escaping @Sendable (Double) -> Void,
               onProblem: @escaping @Sendable (String) -> Void,
               onSourceActivity: (@MainActor @Sendable (Bool) -> Void)? = nil) throws -> AsyncStream<AnalyzerInput> {
        guard deviceCapture == nil, pump == nil else {
            tap?.destroy()
            throw CaptionError.message("입력이 이미 실행 중입니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
        }
        // A dedicated input-only AudioUnit keeps the selected input independent
        // of AVAudioEngine's default input/output aggregate-device rebuilding.
        let source: AudioDeviceCapture
        do { source = try AudioDeviceCapture(deviceID: tap?.deviceID ?? deviceID) }
        catch { tap?.destroy(); throw error }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let audioPump: AudioPump
        do {
            audioPump = try AudioPump(source: source.format, target: target,
                continuation: continuation, onLevel: onLevel, onProblem: onProblem)
        } catch { source.stop(); tap?.destroy(); continuation.finish(); throw error }
        deviceCapture = source
        pump = audioPump
        systemAudio = tap
        do { try source.start(pump: audioPump, onProblem: onProblem) }
        catch {
            deviceCapture = nil
            pump = nil
            systemAudio = nil
            source.stop()
            tap?.destroy()
            continuation.finish()
            throw error
        }
        if tap != nil {
            let timer = audioPump.makeSilenceTimer()
            timer.resume()
            silenceTimer = timer
        }
        watchdogTask = Task { @MainActor [weak self] in
            var reportedFirstInput = false
            var sourceWasActive: Bool?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self, self.deviceCapture === source,
                      self.pump === audioPump else { return }
                let sourceIsActive = audioPump.hasAudibleInput(within: 1.5)
                if sourceIsActive != sourceWasActive {
                    sourceWasActive = sourceIsActive
                    onSourceActivity?(sourceIsActive)
                }
                if audioPump.hasReceivedInput && !reportedFirstInput {
                    reportedFirstInput = true
                    Self.logger.notice("Selected microphone receiving input: device=\(source.deviceID), convertedBuffers=\(audioPump.bufferCount)")
                }
                if let problem = source.configurationProblem() {
                    Self.logger.error("Selected microphone configuration changed: \(problem)")
                    onProblem(problem)
                    return
                }
                guard audioPump.hasStalledInput() else { continue }
                Self.logger.error("Selected microphone has not delivered buffers for over twenty seconds; running=\(source.isRunning)")
                onProblem(audioPump.hasReceivedInput
                    ? "마이크의 오디오 입력이 20초 이상 중단됐습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요."
                    : "마이크 입력을 20초 동안 기다렸지만 연결되지 않았습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요.")
                return
            }
        }
        Self.logger.notice("Selected microphone started: device=\(source.deviceID), rate=\(source.format.sampleRate), channels=\(source.format.channelCount), target=\(target.sampleRate)")
        return stream
    }

    func stop() async {
        watchdogTask?.cancel(); watchdogTask = nil
        let closingSource = deviceCapture
        let closingPump = pump
        let closingTap = systemAudio
        deviceCapture = nil; pump = nil; systemAudio = nil
        silenceTimer?.cancel(); silenceTimer = nil
        // Hardware stop can wait for its callback. Keep it off the UI actor so
        // input failure cannot freeze the Start button or the stop deadline.
        await withCheckedContinuation { done in
            stopQueue.async {
                closingSource?.stop()
                closingTap?.destroy()
                done.resume()
            }
        }
        await closingPump?.finish()
        Self.logger.notice("Microphone stopped: convertedBuffers=\(closingPump?.bufferCount ?? 0), droppedBuffers=\(closingPump?.droppedBufferCount ?? 0)")
    }
}
