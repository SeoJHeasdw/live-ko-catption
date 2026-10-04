import CaptionCore
import Foundation

@MainActor final class Gate {
    var check: CheckedContinuation<Bool, any Error>?
    var permission: CheckedContinuation<Bool, Never>?
    var microphoneCalls = 0
    func readiness() async throws -> Bool { try await withCheckedThrowingContinuation { check = $0 } }
    func mic() async -> Bool {
        microphoneCalls += 1
        return await withCheckedContinuation { permission = $0 }
    }
}

@main @MainActor struct Probe {
    static func main() async throws {
        let name = "caption.adversarial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = Gate()
        let model = CaptionModel(translationOverride: { source, _ in "번역: \(source)" }, microphoneAccessOverride: { await gate.mic() }, readinessOverride: { _ in try await gate.readiness() }, preferencesDefaults: defaults)
        model.isChecking = false
        model.assetsReady = true
        model.contextCorrectionEnabled = false
        model.selectedDeviceUID = ""
        model.receive(source: "Previous conversation sentence.", audioStart: 0, audioEnd: 1, isFinal: true)
        while model.hasPendingTranslations { try await Task.sleep(for: .milliseconds(10)) }
        let switching = Task { await model.switchDirection() }
        while gate.check == nil { await Task.yield() }
        print("SWITCH_WAIT: switching=\(model.isSwitchingDirection), canStart=\(model.canStart), direction=\(model.selectedDirection)")
        // Once admission is fixed, finish the held readiness request instead
        // of waiting forever for a microphone request that must not happen.
        if !model.canStart {
            gate.check?.resume(returning: true)
            await switching.value
            print("START_BLOCKED_DURING_SWITCH: direction=\(model.selectedDirection)")
            return
        }
        let starting = Task { await model.start() }
        while gate.permission == nil { await Task.yield() }
        print("START_DURING_SWITCH: micCalls=\(gate.microphoneCalls), starting=\(model.phase == .starting), direction=\(model.selectedDirection)")
        gate.check?.resume(returning: true)
        await switching.value
        print("SWITCH_FINISHED: direction=\(model.selectedDirection), switching=\(model.isSwitchingDirection)")
        gate.permission?.resume(returning: false)
        await starting.value
    }
}
