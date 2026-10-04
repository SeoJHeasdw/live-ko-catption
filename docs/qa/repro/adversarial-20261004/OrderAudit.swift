@preconcurrency import AVFoundation
import Foundation
import Speech

final class CopyGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var copies = 0
    func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let index = lock.withLock { copies += 1; return copies }
        if index == 1 { entered.signal(); release.wait() }
        return AudioPump.copy(input)
    }
}

@main struct OrderAudit {
    static func main() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let first = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        let second = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        first.frameLength = 1600; second.frameLength = 1600
        for index in 0..<1600 { first.int16ChannelData![0][index] = 1000; second.int16ChannelData![0][index] = -1000 }
        let gate = CopyGate()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let pump = try AudioPump(source: format, target: format, continuation: continuation,
            onLevel: { _ in }, onProblem: { print($0) }, copyBuffer: { gate.copy($0) })
        let reader = Task.detached { () -> [Int16] in
            var samples: [Int16] = []
            for await input in stream { samples.append(input.buffer.int16ChannelData![0][0]) }
            return samples
        }
        let earlierCallback = Task.detached { pump.enqueue(first) }
        await withCheckedContinuation { done in
            DispatchQueue.global().async { gate.entered.wait(); done.resume() }
        }
        pump.enqueue(second)
        gate.release.signal()
        await earlierCallback.value
        await pump.finish()
        print("Producer arrival first +1000, second -1000; analyzer order=", await reader.value)
    }
}
