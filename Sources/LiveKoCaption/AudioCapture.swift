@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import OSLog
import Speech

struct AudioInputDevice: Identifiable, Equatable, Sendable {
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
    private let queue = DispatchQueue(label: "io.javis.live-ko-caption.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var finished = false
    private var convertedBuffers = 0
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private let onProblem: @Sendable (String) -> Void
    private var nextFrame: Int64 = 0
    private var lastMeterTime: TimeInterval = 0

    init(source: AVAudioFormat, target: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Double) -> Void,
         onProblem: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw CaptionError.message("이 마이크의 음성 형식을 변환할 수 없습니다.")
        }
        self.converter = converter
        self.target = target
        self.continuation = continuation
        self.onLevel = onLevel
        self.onProblem = onProblem
    }

    // AVAudioNodeTapBlock is nonsendable in the SDK. Creating it inside the
    // @MainActor capture controller would infer MainActor isolation and trap
    // when AVAudioEngine invokes it on its real-time messenger queue.
    // Construct it here, in a nonisolated context, capturing only the pump.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in enqueue(buffer) }
    }

    var bufferCount: Int { lock.withLock { convertedBuffers } }

    func enqueue(_ original: AVAudioPCMBuffer) {
        lock.lock()
        if finished { lock.unlock(); return }
        guard pending < 32 else {
            lock.unlock()
            onProblem("음성 처리가 밀려 일부 입력이 누락됐습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
            return
        }
        pending += 1
        lock.unlock()

        guard let copy = AVAudioPCMBuffer(pcmFormat: original.format, frameCapacity: original.frameLength) else {
            decrementPending()
            onProblem("마이크 입력을 읽을 수 없습니다.")
            return
        }
        copy.frameLength = original.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(original.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in sources.indices {
            if let source = sources[index].mData, let destination = destinations[index].mData {
                memcpy(destination, source, Int(sources[index].mDataByteSize))
            }
        }
        queue.async { [self, copy] in
            defer { decrementPending() }
            convert(copy)
        }
    }

    private func decrementPending() {
        lock.lock(); pending -= 1; lock.unlock()
    }

    private func convert(_ source: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * target.sampleRate / source.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else {
            onProblem("마이크 입력을 변환하지 못했습니다. 입력 장치를 다시 선택해 주세요.")
            return
        }
        guard output.frameLength > 0 else { return }
        lock.withLock { convertedBuffers += 1 }
        let startTime = CMTime(value: nextFrame, timescale: CMTimeScale(target.sampleRate))
        nextFrame += Int64(output.frameLength)
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: startTime)) {
            onProblem("음성 인식이 입력 속도를 따라가지 못했습니다. 잠시 멈춘 뒤 다시 시작해 주세요.")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterTime > 0.10, let samples = source.floatChannelData?[0] {
            lastMeterTime = now
            let count = Int(source.frameLength)
            var squares: Float = 0
            for index in stride(from: 0, to: count, by: 4) { squares += samples[index] * samples[index] }
            let rms = sqrt(Double(squares) / Double(max(1, count / 4)))
            onLevel(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 60)))
        }
    }

    func finish() async {
        lock.withLock { finished = true }
        await withCheckedContinuation { done in
            queue.async { [self] in
                continuation.finish()
                done.resume()
            }
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
    private let engine = AVAudioEngine()
    private var pump: AudioPump?
    private var hasTap = false
    private var configurationObserver: NSObjectProtocol?
    private var configurationRestarts = 0

    func start(deviceID: AudioDeviceID?, target: AVAudioFormat,
               onLevel: @escaping @Sendable (Double) -> Void,
               onProblem: @escaping @Sendable (String) -> Void) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        if var deviceID {
            guard let unit = input.audioUnit else {
                throw CaptionError.message("선택한 마이크를 사용할 수 없습니다. 다른 입력 장치를 선택해 주세요.")
            }
            var currentDevice = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                 kAudioUnitScope_Global, 0, &currentDevice, &size)
            if readStatus != noErr || currentDevice != deviceID {
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                 kAudioUnitScope_Global, 0, &deviceID,
                                                 UInt32(MemoryLayout<AudioDeviceID>.size))
                guard status == noErr else {
                    throw CaptionError.message("선택한 마이크를 열 수 없습니다 (\(status)). 연결 상태를 확인해 주세요.")
                }
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptionError.message("마이크에서 음성이 들어오지 않습니다. 연결 상태를 확인해 주세요.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(128))
        let audioPump = try AudioPump(source: format, target: target, continuation: continuation,
                                     onLevel: onLevel, onProblem: onProblem)
        pump = audioPump
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: audioPump.makeTapBlock())
        hasTap = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
            continuation.finish()
            throw error
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
            using: AudioCallbackBridge.configurationBlock { [weak self] in
                guard let self, self.hasTap else { return }
                let current = self.engine.inputNode.outputFormat(forBus: 0)
                if current.isEqual(format) {
                    if self.engine.isRunning {
                        Self.logger.debug("Ignored a settled configuration notification; input is unchanged and running.")
                        return
                    }
                    // AVAudioEngine stops itself when the I/O unit settles a
                    // device configuration. If the tap format is still valid,
                    // restarting the same graph is sufficient and preserves
                    // the analyzer stream. Bound retries if hardware flaps.
                    if self.configurationRestarts < 2 {
                        do {
                            try self.engine.start()
                            self.configurationRestarts += 1
                            Self.logger.notice("Microphone graph recovered after configuration notification.")
                            return
                        } catch {
                            Self.logger.error("Microphone graph recovery failed: \(error.localizedDescription)")
                        }
                    }
                }
                Self.logger.error("Input configuration changed: running=\(self.engine.isRunning), rate=\(current.sampleRate), channels=\(current.channelCount)")
                onProblem("마이크 연결 또는 음성 형식이 바뀌었습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요.")
            }
        )
        Self.logger.notice("Microphone started: rate=\(format.sampleRate), channels=\(format.channelCount), target=\(target.sampleRate)")
        return stream
    }

    func stop() async {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        await pump?.finish()
        Self.logger.notice("Microphone stopped: convertedBuffers=\(self.pump?.bufferCount ?? 0)")
        pump = nil
    }
}
