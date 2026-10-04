@preconcurrency import AVFoundation
import Foundation
import Speech
import CoreMedia
@preconcurrency import Translation

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var problems: [String] = []
    private var meterLevels: [Double] = []
    private var didFinish = false
    func report(_ problem: String) { lock.withLock { problems.append(problem) } }
    func meter(_ level: Double) { lock.withLock { meterLevels.append(level) } }
    func markFinished() { lock.withLock { didFinish = true } }
    var errors: [String] { lock.withLock { problems } }
    var levels: [Double] { lock.withLock { meterLevels } }
    var isFinished: Bool { lock.withLock { didFinish } }
}

private final class CallbackGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var claimed = false
    func blockOnce() {
        guard lock.withLock({ if claimed { return false }; claimed = true; return true }) else { return }
        entered.signal()
        release.wait()
    }
}

// The AVAudioEngine contract calls a nonsendable Objective-C block from its
// own audio queue. This wrapper reproduces that exact boundary for the check.
private final class TapInvocation: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    init(block: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer) {
        self.block = block; self.buffer = buffer
    }
    func invoke() { block(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)) }
}

@main @MainActor
struct AudioCallbackChecks {
    static func main() async {
        do {
            for (rate, channels) in [(48000.0, AVAudioChannelCount(1)), (44100.0, AVAudioChannelCount(2))] {
                try await checkTap(rate: rate, channels: channels)
            }
            try await checkNotification()
            try await checkFinishDuringCopy()
            try await checkConversionOverflow()
            try await checkAnalyzerOverflow()
            try await checkRightChannelMeter()
            try await checkCopyFailure()
            try await checkInputHeartbeat()
            try await checkSmallHardwareBuffers()
            try await checkIdleSilenceTime()
            try await checkPlaybackIdleBoundaries()
            try await checkConcurrentInputOrder()
            try await checkHardwareDeadlineAdmission()
            try await checkHardwareCancellationAdmission()
            try await checkCaptureStartupDeadline()
            try await checkCaptureStartupStop()
            try await checkHardwarePermitHandoff()
            print("18 audio callback and hardware control checks passed.")
            if CommandLine.arguments.dropFirst().first == "--conversion-soak" {
                try await checkConversionSoak()
            } else if CommandLine.arguments.count == 2 {
                try await checkLiveStream(filePath: CommandLine.arguments[1])
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func checkTap(rate: Double, channels: AVAudioChannelCount) async throws {
        guard let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800) else {
            throw Failure("Could not make fixture formats")
        }
        buffer.frameLength = 4800
        for channel in 0..<Int(channels) {
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = sin(Float(index) * 0.04) * 0.25
            }
        }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<Speech.AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) })
        // Deliberately create the production tap from the main actor, just as
        // the app does, and then invoke it on a foreign queue.
        let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
        await withCheckedContinuation { finished in
            DispatchQueue.global(qos: .userInitiated).async {
                invocation.invoke()
                finished.resume()
            }
        }
        await pump.finish()
        var frames: UInt64 = 0
        for await input in stream {
            guard let start = input.bufferStartTime,
                  abs(CMTimeGetSeconds(start) - Double(frames) / target.sampleRate) < 0.000001 else {
                throw Failure("Converted buffer timestamps are discontinuous")
            }
            frames += UInt64(input.buffer.frameLength)
        }
        let expectedFrames = Double(buffer.frameLength) * target.sampleRate / source.sampleRate
        guard abs(Double(frames) - expectedFrames) <= 1, pump.bufferCount > 0, state.errors.isEmpty else {
            throw Failure("Foreign-queue tap failed: frames=\(frames), errors=\(state.errors)")
        }
        print("PASS: foreign audio queue, \(Int(rate)) Hz / \(channels) ch → mono Int16; \(frames) frames")
    }

    private static func checkNotification() async throws {
        var handledOnMain = false
        let callback = AudioCallbackBridge.configurationBlock {
            handledOnMain = Thread.isMainThread
        }
        await withCheckedContinuation { finished in
            DispatchQueue.global().async {
                callback(Notification(name: .AVAudioEngineConfigurationChange))
                finished.resume()
            }
        }
        for _ in 0..<40 where !handledOnMain { try await Task.sleep(for: .milliseconds(25)) }
        guard handledOnMain else { throw Failure("Configuration notification did not hop to the main actor") }
        print("PASS: foreign configuration notification safely reaches main actor")
    }

    private static func fixture() throws -> (AVAudioFormat, AVAudioPCMBuffer) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw Failure("Could not allocate callback fixture")
        }
        buffer.frameLength = 1024
        for index in 0..<1024 { buffer.floatChannelData![0][index] = 0.25 }
        return (format, buffer)
    }

    private static func waitForGate(_ gate: CallbackGate) async -> Bool {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                done.resume(returning: gate.entered.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private static func checkFinishDuringCopy() async throws {
        let (format, buffer) = try fixture()
        let state = CallbackState()
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) },
                                 copyBuffer: { original in
                                     gate.blockOnce()
                                     return AudioPump.copy(original)
                                 })
        let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
        let callback = Task.detached { invocation.invoke() }
        guard await waitForGate(gate) else { throw Failure("In-flight copy did not reach the gate") }
        guard pump.hasReceivedInput, pump.bufferCount == 0 else {
            throw Failure("Capture recovery cannot distinguish received input from conversion completion")
        }
        let stopping = Task { await pump.finish(); state.markFinished() }
        try await Task.sleep(for: .milliseconds(30))
        guard !state.isFinished else { throw Failure("finish() discarded a tap buffer still being copied") }
        gate.release.signal()
        await callback.value
        await stopping.value
        // Repeated finish must be safe and return after the same completed drain.
        await pump.finish()
        var frames = 0
        for await input in stream { frames += Int(input.buffer.frameLength) }
        guard frames == 1024, state.errors.isEmpty else {
            throw Failure("Accepted in-flight buffer was lost during stop: \(frames) frames")
        }
        pump.enqueue(buffer)
        guard pump.bufferCount == 1 else { throw Failure("A finished pump accepted more microphone input") }
        print("PASS: stop waits for accepted copy, drains it once, and rejects later input")
    }

    private static func waitForProblem(_ state: CallbackState) async throws {
        for _ in 0..<40 where state.errors.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func checkConversionOverflow() async throws {
        let (format, buffer) = try fixture()
        let state = CallbackState()
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
                                 onLevel: { _ in gate.blockOnce() }, onProblem: { state.report($0) })
        pump.enqueue(buffer)
        guard await waitForGate(gate) else { throw Failure("Conversion did not reach its meter gate") }
        for _ in 0..<100 { pump.enqueue(buffer) }
        gate.release.signal()
        await pump.finish()
        var retainedFrames = 0
        for await input in stream { retainedFrames += Int(input.buffer.frameLength) }
        try await waitForProblem(state)
        guard retainedFrames == 7 * 1024, pump.droppedBufferCount == 94, state.errors.count == 1 else {
            throw Failure("Conversion queue was not bounded by input duration, or errors flooded: retainedFrames=\(retainedFrames), dropped=\(pump.droppedBufferCount), errors=\(state.errors.count)")
        }
        print("PASS: conversion backlog stays below 0.5 s and 94 dropped buffers produce one error")
    }

    private static func checkAnalyzerOverflow() async throws {
        let (format, buffer) = try fixture()
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) })
        for _ in 0..<20 {
            pump.enqueue(buffer)
            try await Task.sleep(for: .milliseconds(5))
        }
        await pump.finish()
        var retainedBuffers = 0
        for await _ in stream { retainedBuffers += 1 }
        try await waitForProblem(state)
        guard retainedBuffers == AudioPump.analyzerBufferLimit,
              pump.droppedBufferCount == pump.bufferCount - retainedBuffers, state.errors.count == 1 else {
            throw Failure("Analyzer overflow was not bounded/reported once: retained=\(retainedBuffers), dropped=\(pump.droppedBufferCount), errors=\(state.errors.count)")
        }
        print("PASS: slow analyzer retains at most \(retainedBuffers) buffers and reports dropped input once")
    }

    private static func checkRightChannelMeter() async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 2, interleaved: true),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            throw Failure("Could not allocate stereo meter fixture")
        }
        buffer.frameLength = 1024
        for frame in 0..<1024 {
            buffer.floatChannelData![0][frame * 2] = 0
            buffer.floatChannelData![0][frame * 2 + 1] = 0.25
        }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: target, continuation: continuation,
                                 onLevel: { state.meter($0) }, onProblem: { state.report($0) })
        pump.enqueue(buffer)
        await pump.finish()
        var peak: Float = 0
        for await input in stream {
            guard let samples = input.buffer.floatChannelData?[0] else { continue }
            for frame in 0..<Int(input.buffer.frameLength) { peak = max(peak, abs(samples[frame])) }
        }
        guard let level = state.levels.first, level > 0.5, peak > 0.01, state.errors.isEmpty else {
            throw Failure("A right-channel microphone appeared silent or was lost in the mono conversion")
        }
        print("PASS: interleaved right-channel microphone survives mono conversion and appears on the meter")
    }

    private static func checkCopyFailure() async throws {
        let (format, buffer) = try fixture()
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) },
                                 copyBuffer: { _ in nil })
        pump.enqueue(buffer)
        await pump.finish()
        var frames = 0
        for await input in stream { frames += Int(input.buffer.frameLength) }
        try await waitForProblem(state)
        guard frames == 0, pump.droppedBufferCount == 1, state.errors.count == 1 else {
            throw Failure("Failed audio copy was hidden or prevented stream shutdown")
        }
        print("PASS: failed microphone copy is counted/reported and still permits shutdown")
    }

    private static func checkInputHeartbeat() async throws {
        let (format, buffer) = try fixture()
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0 }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) },
                                 startedAtUptime: 100)
        guard !pump.hasStalledInput(at: 103), !pump.hasStalledInput(at: 119.9), !pump.hasStalledInput(at: 120),
              pump.hasStalledInput(at: 120.001), !pump.hasReceivedInput else {
            throw Failure("Never-started microphone does not become stale after its startup allowance")
        }
        // All-zero audio represents a quiet room, not a disconnected input.
        pump.enqueue(buffer, at: 119)
        guard pump.hasReceivedInput, !pump.hasStalledInput(at: 122), !pump.hasStalledInput(at: 139), pump.hasStalledInput(at: 139.001) else {
            throw Failure("Silent audio did not refresh the microphone heartbeat")
        }
        buffer.frameLength = 0
        pump.enqueue(buffer, at: 139)
        guard pump.hasStalledInput(at: 139.001) else {
            throw Failure("An empty callback concealed a stalled microphone")
        }
        await pump.finish()
        for await _ in stream {}
        guard !pump.hasStalledInput(at: 1000), state.errors.isEmpty else {
            throw Failure("A stopped microphone remained eligible for a watchdog error")
        }
        print("PASS: microphone waits at least 20 s, silent input stays healthy, and stop disables heartbeat errors")
    }

    private static func checkSmallHardwareBuffers() async throws {
        // Reproduce the built-in microphone cadence, with a consumer paused
        // for 0.6 s. Eight hardware buffers alone would lose ~0.5 s of input.
        // 100 ms batches must retain it all and flush the unfilled final batch.
        guard let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 512) else {
            throw Failure("Could not allocate hardware-sized fixture")
        }
        buffer.frameLength = 512
        for frame in 0..<512 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.04) * 0.25 }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) })
        let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
        for _ in 0..<56 {
            await withCheckedContinuation { done in
                DispatchQueue.global(qos: .userInitiated).async {
                    invocation.invoke()
                    done.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(11))
        }
        await pump.finish()
        var frames: Int64 = 0
        var buffers = 0
        for await input in stream {
            guard let start = input.bufferStartTime,
                  abs(CMTimeGetSeconds(start) - Double(frames) / target.sampleRate) < 0.000001 else {
                throw Failure("Batched hardware-sized audio lost timestamp continuity")
            }
            frames += Int64(input.buffer.frameLength)
            buffers += 1
        }
        try await waitForProblem(state)
        let expectedFrames = Double(56 * 512) * target.sampleRate / source.sampleRate
        guard abs(Double(frames) - expectedFrames) <= 1, buffers <= AudioPump.analyzerBufferLimit,
              pump.droppedBufferCount == 0, state.errors.isEmpty else {
            throw Failure("Hardware-sized callbacks lost audio during bounded analyzer pause: frames=\(frames), buffers=\(buffers), dropped=\(pump.droppedBufferCount), errors=\(state.errors)")
        }
        print("PASS: 56 small hardware callbacks retain ~0.6 s input as \(buffers) analyzer buffers, with exact final tail")
    }

    private static func checkIdleSilenceTime() async throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
            onLevel: { _ in }, onProblem: { state.report($0) }, startedAtUptime: 100)
        let reader = Task.detached { () -> Int64 in
            var frames: Int64 = 0
            for await input in stream { frames += Int64(input.buffer.frameLength) }
            return frames
        }
        for tick in 1...100 {
            // A one-microsecond alternation previously discarded every other
            // timer tick and converted ten seconds of silence into five.
            let jitter = tick.isMultiple(of: 2) ? 0.0 : 0.000001
            pump.enqueueSilenceIfIdle(at: 100 + Double(tick) * 0.1 + jitter)
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !pump.hasReceivedInput, pump.hasStalledInput(at: 121) else {
            throw Failure("Synthesized silence pretended a real device delivered buffers")
        }
        await pump.finish()
        let frames = await reader.value
        guard frames == 160_000, pump.droppedBufferCount == 0, state.errors.isEmpty else {
            throw Failure("Idle timer jitter lost elapsed audio time: frames=\(frames), errors=\(state.errors)")
        }
        print("PASS: 100 jittered idle ticks retain ten seconds and never refresh the real hardware heartbeat")
    }

    private static func checkConcurrentInputOrder() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let first = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        let second = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        first.frameLength = 1600; second.frameLength = 1600
        for frame in 0..<1600 {
            first.int16ChannelData![0][frame] = 1000
            second.int16ChannelData![0][frame] = -1000
        }
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
            onLevel: { _ in }, onProblem: { state.report($0) },
            copyBuffer: { input in gate.blockOnce(); return AudioPump.copy(input) }, startedAtUptime: 100)
        let earlier = Task.detached { pump.enqueue(first, at: 100.1) }
        guard await waitForGate(gate) else { throw Failure("Earlier audio copy never reached its gate") }
        // The real callback and system-idle timer are separate producers.
        pump.enqueueSilenceIfIdle(at: 100.2)
        pump.enqueue(second, at: 100.3)
        gate.release.signal()
        await earlier.value
        await pump.finish()
        var order: [Int16] = []
        for await input in stream { order.append(input.buffer.int16ChannelData![0][0]) }
        guard order == [1000, 0, -1000], pump.droppedBufferCount == 0, state.errors.isEmpty else {
            throw Failure("Concurrent copying reordered real and synthetic input: \(order)")
        }
        print("PASS: a delayed earlier copy keeps real, synthetic silence, and following real audio in order")
    }

    private static func checkPlaybackIdleBoundaries() async throws {
        let (format, buffer) = try fixture()
        buffer.frameLength = 512
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
            onLevel: { _ in }, onProblem: { state.report($0) }, startedAtUptime: 100)
        let reader = Task.detached { () -> (Int, Int) in
            var frames = 0
            var audibleFrames = 0
            for await input in stream {
                frames += Int(input.buffer.frameLength)
                for frame in 0..<Int(input.buffer.frameLength) where input.buffer.floatChannelData![0][frame] != 0 {
                    audibleFrames += 1
                }
            }
            return (frames, audibleFrames)
        }
        pump.enqueueSilenceIfIdle(at: 100.1)
        pump.enqueueSilenceIfIdle(at: 100.2)
        // A real callback arriving just after an idle tick must be credited to
        // the same frame clock, so the next gap does not count it a second time.
        pump.enqueue(buffer, at: 100.205)
        try await Task.sleep(for: .milliseconds(5))
        pump.enqueueSilenceIfIdle(at: 100.305)
        pump.enqueue(buffer, at: 100.31)
        try await Task.sleep(for: .milliseconds(5))
        pump.enqueueSilenceIfIdle(at: 100.411)
        await pump.finish()
        let (frames, audibleFrames) = await reader.value
        guard frames == 6576, audibleFrames == 1024, pump.droppedBufferCount == 0, state.errors.isEmpty else {
            throw Failure("Playback/idle transitions duplicated or lost time/speech: frames=\(frames), audible=\(audibleFrames)")
        }
        print("PASS: idle/playback boundaries keep exactly 411 ms of elapsed audio and preserve both real buffers")
    }

    private static func checkHardwareDeadlineAdmission() async throws {
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let state = CallbackState()
        let permit = try AudioHardwarePermit.claim()
        let ticket = AudioControlTicket<Int>()
        permit.queue.async {
            if Thread.isMainThread { state.report("Hardware control ran on the UI thread") }
            gate.blockOnce()
            ticket.complete(.success(42))
            permit.release()
            state.markFinished()
        }
        guard await waitForGate(gate) else { throw Failure("Blocked hardware fixture never started") }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await ticket.value(seconds: 0.04, operation: "blocked driver")
            throw Failure("A blocked driver escaped its deadline")
        } catch is CaptionError { }
        guard ProcessInfo.processInfo.systemUptime - began < 1 else { throw Failure("Blocked driver froze the UI deadline") }
        for _ in 0..<10 {
            do { let extra = try AudioHardwarePermit.claim(); extra.release(); throw Failure("A stuck driver admitted another worker") }
            catch is CaptionError { }
        }
        gate.release.signal()
        for _ in 0..<200 where !state.isFinished { try await Task.sleep(for: .milliseconds(5)) }
        guard state.isFinished, state.errors.isEmpty else { throw Failure("Late hardware completion did not release its admission") }
        let recovered = try AudioHardwarePermit.claim()
        recovered.release()
        print("PASS: blocked hardware waits off the UI thread, deadline returns, retries stay bounded, and late completion recovers")
    }

    private static func checkHardwareCancellationAdmission() async throws {
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let state = CallbackState()
        let operation = Task {
            try await AudioHardwarePermit.perform(seconds: 10, operation: "canceled driver") {
                gate.blockOnce()
                state.markFinished()
                return 42
            }
        }
        guard await waitForGate(gate) else { throw Failure("Canceled hardware fixture never started") }
        let began = ProcessInfo.processInfo.systemUptime
        operation.cancel()
        do { _ = try await operation.value; throw Failure("Canceled driver returned success") }
        catch is CancellationError { }
        guard ProcessInfo.processInfo.systemUptime - began < 1 else { throw Failure("Cancellation waited for the driver") }
        do { let extra = try AudioHardwarePermit.claim(); extra.release(); throw Failure("Canceling wait released a still-blocked driver") }
        catch is CaptionError { }
        gate.release.signal()
        for _ in 0..<200 where !state.isFinished { try await Task.sleep(for: .milliseconds(5)) }
        // perform releases immediately after the fixture returns; wait for that
        // tiny interval without scheduling a second hardware job.
        var recovered = false
        for _ in 0..<200 where !recovered {
            if let permit = try? AudioHardwarePermit.claim() { permit.release(); recovered = true }
            else { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard recovered else { throw Failure("Canceled driver's late completion kept admission occupied") }
        print("PASS: cancellation returns before a stuck driver, and its permit stays held until actual completion")
    }

    private static func waitForHardwareRelease() async throws {
        for _ in 0..<200 {
            if let permit = try? AudioHardwarePermit.claim() { permit.release(); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure("Late capture cleanup kept hardware admission occupied")
    }

    private static func checkCaptureStartupDeadline() async throws {
        let (format, _) = try fixture()
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let state = CallbackState()
        let capture = AudioCapture(hardwareStartDeadline: 0.04, beforeHardwarePrepare: {
            if Thread.isMainThread { state.report("Capture preparation ran on the UI thread") }
            gate.blockOnce()
        })
        let starting = Task { try await capture.start(deviceID: nil, target: format, onLevel: { _ in }, onProblem: { state.report($0) }) }
        guard await waitForGate(gate) else { throw Failure("Capture startup did not enter its control worker") }
        let began = ProcessInfo.processInfo.systemUptime
        do { _ = try await starting.value; throw Failure("Blocked capture startup returned success") }
        catch is CaptionError { }
        guard ProcessInfo.processInfo.systemUptime - began < 1, capture.deviceID == nil,
              capture.timeOrigin == nil, state.errors.isEmpty else {
            throw Failure("Blocked startup failed to return safely before hardware preparation")
        }
        for _ in 0..<5 {
            do {
                _ = try await capture.start(deviceID: nil, target: format, onLevel: { _ in }, onProblem: { state.report($0) })
                throw Failure("Timed-out capture admitted another hardware startup")
            } catch is CaptionError { }
        }
        gate.release.signal()
        try await waitForHardwareRelease()
        await capture.stop()
        print("PASS: production capture startup times out off the UI, rejects retries until late cleanup, and opens no microphone")
    }

    private static func checkCaptureStartupStop() async throws {
        let (format, _) = try fixture()
        let gate = CallbackGate()
        defer { gate.release.signal() }
        let state = CallbackState()
        let capture = AudioCapture(beforeHardwarePrepare: { gate.blockOnce() })
        let starting = Task { try await capture.start(deviceID: nil, target: format, onLevel: { _ in }, onProblem: { state.report($0) }) }
        guard await waitForGate(gate) else { throw Failure("Capture stop fixture never entered startup") }
        let began = ProcessInfo.processInfo.systemUptime
        await capture.stop()
        do { _ = try await starting.value; throw Failure("Stopped capture startup resurrected itself") }
        catch is CancellationError { }
        guard ProcessInfo.processInfo.systemUptime - began < 1.5, capture.deviceID == nil,
              capture.timeOrigin == nil, state.errors.isEmpty else {
            throw Failure("Stop waited for a blocked startup or published stale hardware")
        }
        do { let extra = try AudioHardwarePermit.claim(); extra.release(); throw Failure("Stop released blocked hardware admission early") }
        catch is CaptionError { }
        gate.release.signal()
        try await waitForHardwareRelease()
        print("PASS: stopping blocked startup cancels its waiter immediately, bounds stop to 0.8 s, and cleans late resources")
    }

    private static func checkHardwarePermitHandoff() async throws {
        for _ in 0..<500 {
            let value = try await AudioHardwarePermit.perform(operation: "device handoff fixture") { 42 }
            guard value == 42 else { throw Failure("Control operation changed its result") }
            // Enumeration completes immediately before capture claims a permit.
            // Completion must never be published while the old permit is held.
            let capturePermit = try AudioHardwarePermit.claim()
            capturePermit.release()
        }
        print("PASS: 500 completed hardware reads hand their permit immediately to the next capture")
    }

    private static func checkConversionSoak() async throws {
        guard let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 512) else {
            throw Failure("Could not allocate conversion soak fixture")
        }
        buffer.frameLength = 512
        for frame in 0..<512 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.04) * 0.25 }
        let state = CallbackState()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
                                 onLevel: { _ in }, onProblem: { state.report($0) })
        let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
        let reader = Task.detached { () throws -> (Int64, Int) in
            var frames: Int64 = 0
            var buffers = 0
            for await input in stream {
                guard let start = input.bufferStartTime,
                      abs(CMTimeGetSeconds(start) - Double(frames) / target.sampleRate) < 0.000001 else {
                    throw Failure("Long conversion stream lost timestamp continuity at buffer \(buffers)")
                }
                frames += Int64(input.buffer.frameLength)
                buffers += 1
            }
            return (frames, buffers)
        }
        let producer = Task.detached {
            var producedFrames = 0
            let totalFrames = 48_000 * 30 * 60
            while producedFrames < totalFrames {
                let expectedBatches = producedFrames / 4800 + 1
                repeat {
                    invocation.invoke()
                    producedFrames += 512
                } while producedFrames < totalFrames && producedFrames / 4800 < expectedBatches
                // Accelerate wall time while permitting the production queue
                // to drain. This exercises 30 min of frame/timestamp state;
                // it is explicitly not a 30 min hardware or recognition run.
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while pump.bufferCount < producedFrames / 4800 {
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw Failure("Conversion soak failed to drain its bounded queue")
                    }
                    try await Task.sleep(for: .microseconds(100))
                }
            }
        }
        do { try await producer.value }
        catch {
            await pump.finish()
            _ = try? await reader.value
            throw error
        }
        await pump.finish()
        let (frames, buffers) = try await reader.value
        try await waitForProblem(state)
        guard frames == 16_000 * 30 * 60, pump.droppedBufferCount == 0, state.errors.isEmpty,
              buffers <= 18_002 else {
            throw Failure("Accelerated 30 min conversion failed: frames=\(frames), buffers=\(buffers), dropped=\(pump.droppedBufferCount), errors=\(state.errors)")
        }
        print("PASS: accelerated 30 min / 168,750 small callbacks → \(frames) exact mono frames; \(buffers) analyzer buffers, no drops")
        print("This accelerated conversion check does not prove 30 min hardware microphone or recognition stability.")
    }

    private static func checkLiveStream(filePath: String) async throws {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults, .fastResults],
                                           attributeOptions: [.audioTimeRange])
        let ownsReservation = try await AssetInventory.reserve(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw Failure("Prepare local English models in the app before checking the live stream")
        }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: filePath))
            let state = CallbackState()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(AudioPump.analyzerBufferLimit))
            let pump = try AudioPump(source: file.processingFormat, target: target, continuation: continuation,
                                     onLevel: { _ in }, onProblem: { state.report($0) })
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: target)
            let began = ProcessInfo.processInfo.systemUptime
            let results = Task {
                var source: [String] = []
                var timeline = CaptionTimeline()
                var partials = 0
                var firstPartial: Double?
                var deliveryLags: [Double] = []
                for try await result in transcriber.results {
                    let audioEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    if audioEnd.isFinite {
                        deliveryLags.append(max(0, ProcessInfo.processInfo.systemUptime - began - audioEnd))
                    }
                    timeline.accept(source: String(result.text.characters),
                                    audioStart: CMTimeGetSeconds(result.range.start),
                                    audioEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                                    isFinal: result.isFinal)
                    if result.isFinal { source.append(String(result.text.characters)) }
                    else {
                        partials += 1
                        if firstPartial == nil { firstPartial = ProcessInfo.processInfo.systemUptime - began }
                    }
                }
                return (source.joined(separator: " "), timeline.segments.map(\.source), partials, firstPartial, deliveryLags)
            }
            // This is the production lifecycle: live analysis in its own task,
            // then close the producer, finalize, and drain results.
            let analysis = Task {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else { await analyzer.cancelAndFinishNow() }
            }
            let chunkFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                    throw Failure("Could not allocate streaming fixture buffer")
                }
                try file.read(into: buffer, frameCount: chunkFrames)
                let invocation = TapInvocation(block: pump.makeTapBlock(), buffer: buffer)
                await withCheckedContinuation { done in
                    DispatchQueue.global(qos: .userInitiated).async {
                        invocation.invoke()
                        done.resume()
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let drainBegan = ProcessInfo.processInfo.systemUptime
            await pump.finish()
            try await analysis.value
            let (source, retained, partials, firstPartial, deliveryLags) = try await results.value
            let drainSeconds = ProcessInfo.processInfo.systemUptime - drainBegan
            let normalize: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            guard !source.isEmpty, partials > 0, state.errors.isEmpty,
                  normalize(source) == normalize(retained.joined(separator: " ")) else {
                throw Failure("Live stream check failed: source=\(source), retained=\(retained), errors=\(state.errors)")
            }
            let translator = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                                target: Locale.Language(identifier: "ko"), preferredStrategy: .lowLatency)
            let translated = try await translator.translate(source)
            guard !translated.targetText.isEmpty else { throw Failure("Live stream translation was empty") }
            print("PASS: paced audio stream → actual local recognition → caption timeline → Korean translation")
            print("EN: \(source)")
            print("KO: \(translated.targetText)")
            print("Partial events: \(partials); first English partial after \(firstPartial ?? -1)s of fixture streaming")
            let orderedLags = deliveryLags.sorted()
            if !orderedLags.isEmpty {
                let median = orderedLags[orderedLags.count / 2]
                let percentile95 = orderedLags[min(orderedLags.count - 1, Int(Double(orderedLags.count) * 0.95))]
                print(String(format: "Fixture ASR delivery lag p50/p95: %.3f / %.3f s; shutdown drain: %.3f s; converted/dropped buffers: %d / %d",
                             median, percentile95, drainSeconds, pump.bufferCount, pump.droppedBufferCount))
            }
            print("This fixture check does not measure hardware microphone latency.")
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
        } catch {
            if ownsReservation { await AssetInventory.release(reservedLocale: locale) }
            throw error
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
