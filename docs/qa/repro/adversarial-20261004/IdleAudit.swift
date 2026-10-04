@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

@main struct IdleAudit {
    static func main() async throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: source, target: target, continuation: continuation,
            onLevel: { _ in }, onProblem: { print("problem:", $0) }, startedAtUptime: 100)
        let reader = Task.detached { () -> Int64 in
            var frames: Int64 = 0
            for await input in stream { frames += Int64(input.buffer.frameLength) }
            return frames
        }
        for index in 1...100 {
            let jitter = index.isMultiple(of: 2) ? 0.0 : 0.000001
            pump.enqueueSilenceIfIdle(at: 100 + Double(index) * 0.1 + jitter)
            try await Task.sleep(for: .milliseconds(1))
        }
        print("Never received a real callback; hasReceivedInput=", pump.hasReceivedInput,
              "stalled=", pump.hasStalledInput(at: 110.01))
        await pump.finish()
        let frames = await reader.value
        print("100 timer ticks over 10 sec at only 1 us jitter: frames=", frames,
              "audio seconds=", Double(frames) / target.sampleRate, "expected 10 seconds")

        let (liveStream, liveContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let livePump = try AudioPump(source: source, target: target, continuation: liveContinuation,
            onLevel: { _ in }, onProblem: { print("problem:", $0) })
        let liveReader = Task.detached { () -> Int64 in
            var frames: Int64 = 0
            for await input in liveStream { frames += Int64(input.buffer.frameLength) }
            return frames
        }
        let began = ProcessInfo.processInfo.systemUptime
        let timer = livePump.makeSilenceTimer()
        timer.resume()
        try await Task.sleep(for: .milliseconds(3200))
        timer.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        await livePump.finish()
        let liveFrames = await liveReader.value
        print("Production timer wall elapsed=", elapsed, "audio seconds=", Double(liveFrames) / target.sampleRate)
    }
}
