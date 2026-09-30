@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A dedicated input-only AUHAL keeps microphone selection independent from
/// AVAudioEngine's asynchronous default input/output aggregate management.
/// All control operations are serialized; the foreign callback uses only its
/// preallocated render buffer and the bounded audio pump.
final class AudioDeviceCapture: @unchecked Sendable {
    let deviceID: AudioDeviceID
    let format: AVAudioFormat

    private let unit: AudioUnit
    private let controlLock = NSLock()
    private let stateLock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    private var pump: AudioPump?
    private var onProblem: (@Sendable (String) -> Void)?
    private var reportedProblem = false
    private var running = false
    private var initialized = false
    private var disposed = false

    init(deviceID requestedDevice: AudioDeviceID?) throws {
        deviceID = try requestedDevice ?? Self.defaultInputDevice()
        format = try Self.hardwareFormat(deviceID)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptionError.message("마이크 입력 기능을 찾지 못했습니다.")
        }
        var createdUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &createdUnit), "마이크 입력을 만들 수 없습니다")
        guard let createdUnit else { throw CaptionError.message("마이크 입력을 만들 수 없습니다.") }
        unit = createdUnit
        do {
            // Configure input before selecting an input-only device. No output
            // device or system default route is modified by this capture unit.
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)), "마이크 입력을 켤 수 없습니다")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &disabled, UInt32(MemoryLayout<UInt32>.size)), "마이크 출력을 끌 수 없습니다")
            var selectedDevice = deviceID
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selectedDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "선택한 마이크를 열 수 없습니다")
            var streamFormat = format.streamDescription.pointee
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "마이크 음성 형식을 설정할 수 없습니다")
            var callback = AURenderCallbackStruct(inputProc: Self.makeInputCallback(),
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "마이크 입력을 연결할 수 없습니다")
            try Self.check(AudioUnitInitialize(unit), "마이크 입력을 준비할 수 없습니다")
            initialized = true
            var maximumFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maximumFrames, &size), "마이크 버퍼 크기를 확인할 수 없습니다")
            // Reject implausible allocations instead of allowing a faulty
            // device to allocate an unbounded callback buffer.
            guard maximumFrames > 0, maximumFrames <= 262_144,
                  let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
                throw CaptionError.message("이 마이크의 입력 버퍼를 준비할 수 없습니다.")
            }
            buffer = renderBuffer
            try verifySelectedDevice()
        } catch {
            stop()
            throw error
        }
    }

    func start(pump: AudioPump, onProblem: @escaping @Sendable (String) -> Void) throws {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !disposed, !running else {
            throw CaptionError.message("마이크 입력을 다시 준비해 주세요.")
        }
        stateLock.withLock {
            self.pump = pump
            self.onProblem = onProblem
            reportedProblem = false
        }
        do {
            try verifySelectedDevice()
            try Self.check(AudioOutputUnitStart(unit), "선택한 마이크를 시작할 수 없습니다")
            running = true
            // A successful start is not evidence that the requested device is
            // still selected. Read the unit back before accepting startup.
            try verifySelectedDevice()
        } catch {
            if running { AudioOutputUnitStop(unit); running = false }
            stateLock.withLock { self.pump = nil; self.onProblem = nil }
            throw error
        }
    }

    func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard !disposed else { return }
        // Stop waits for the render callback before its buffer, pump, or
        // unretained refcon can be released. The callback never takes this lock.
        if running { AudioOutputUnitStop(unit); running = false }
        if initialized { AudioUnitUninitialize(unit); initialized = false }
        var emptyCallback = AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &emptyCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        AudioComponentInstanceDispose(unit)
        disposed = true
        stateLock.withLock { pump = nil; onProblem = nil }
        buffer = nil
    }

    deinit { stop() }

    var isRunning: Bool {
        controlLock.withLock {
            guard running, !disposed else { return false }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning,
                kAudioUnitScope_Global, 0, &value, &size) == noErr && value != 0
        }
    }

    /// Called away from the render callback. A chosen microphone may disappear
    /// or change format even though its old client PCM format remains valid.
    func configurationProblem() -> String? {
        controlLock.withLock {
            guard running, !disposed else { return nil }
            do {
                var alive: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr,
                      alive != 0 else {
                    return "선택한 마이크의 연결이 끊겼습니다. 다시 연결하거나 다른 입력 장치를 선택해 주세요."
                }
                try verifySelectedDevice()
                let currentFormat = try Self.hardwareFormat(deviceID)
                guard currentFormat.sampleRate == format.sampleRate,
                      currentFormat.channelCount == format.channelCount else {
                    return "마이크의 음성 형식이 바뀌었습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요."
                }
                return nil
            } catch { return error.localizedDescription }
        }
    }

    // Construct this C callback in a nonisolated factory. Capturing a closure
    // from a MainActor startup method can trap on the first hardware buffer.
    private static func makeInputCallback() -> AURenderCallback {
        { refcon, flags, timestamp, _, frameCount, _ in
            let capture = Unmanaged<AudioDeviceCapture>.fromOpaque(refcon).takeUnretainedValue()
            return capture.receive(flags: flags, timestamp: timestamp, frameCount: frameCount)
        }
    }

    private func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         timestamp: UnsafePointer<AudioTimeStamp>, frameCount: UInt32) -> OSStatus {
        guard frameCount > 0 else { return noErr }
        guard let buffer, frameCount <= buffer.frameCapacity else {
            reportProblem(.oversizedBuffer)
            return noErr
        }
        buffer.frameLength = frameCount
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, buffer.mutableAudioBufferList)
        guard status == noErr else {
            reportProblem(.renderFailed(status))
            return status
        }
        stateLock.withLock { pump }?.enqueue(buffer)
        return noErr
    }

    private enum InputProblem: Sendable { case oversizedBuffer, renderFailed(OSStatus) }

    private func reportProblem(_ problem: InputProblem) {
        let handler: (@Sendable (String) -> Void)? = stateLock.withLock {
            guard !reportedProblem else { return nil }
            reportedProblem = true
            return onProblem
        }
        guard let handler else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            switch problem {
            case .oversizedBuffer:
                handler("마이크가 예상보다 큰 입력을 보내 일부 음성이 누락됐습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요.")
            case .renderFailed(let status):
                handler("마이크에서 오디오 입력을 읽지 못했습니다 (\(status)). 입력 장치를 확인한 뒤 다시 시작해 주세요.")
            }
        }
    }

    private func verifySelectedDevice() throws {
        var actualDevice = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actualDevice, &size), "선택한 마이크를 확인할 수 없습니다")
        guard actualDevice == deviceID else {
            throw CaptionError.message("선택한 마이크 대신 다른 입력 장치가 연결됐습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요.")
        }
    }

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device), "시스템 기본 마이크를 확인할 수 없습니다")
        guard device != 0 else { throw CaptionError.message("사용할 수 있는 기본 마이크가 없습니다.") }
        return device
    }

    private static func hardwareFormat(_ device: AudioDeviceID) throws -> AVAudioFormat {
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &sampleRate), "마이크 샘플 속도를 확인할 수 없습니다")
        address.mSelector = kAudioDevicePropertyStreamConfiguration
        address.mScope = kAudioObjectPropertyScopeInput
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "마이크 채널을 확인할 수 없습니다")
        guard size >= MemoryLayout<AudioBufferList>.size else {
            throw CaptionError.message("선택한 장치에 마이크 입력이 없습니다.")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage), "마이크 채널을 읽을 수 없습니다")
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        guard sampleRate > 0, channels > 0, channels <= 64,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw CaptionError.message("선택한 마이크의 음성 형식을 사용할 수 없습니다.")
        }
        return format
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr { throw CaptionError.message("\(message) (\(status)).") }
    }
}
