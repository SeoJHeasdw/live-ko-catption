@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

/// Plays a synthetic fixture with afplay, taps only that process and mutes it
/// while tapped, then reads it through the production capture, pump and the
/// installed English recognizer. Nothing audible is played, no microphone is
/// opened and no language asset is downloaded.
@main @MainActor
struct SystemAudioChecks {
    static var failures: [String] = []
    static var problems: [String] = []
    static var activity: [Bool] = []
    static var finals: [(text: String, arrived: TimeInterval)] = []
    static func expect(_ condition: Bool, _ message: String) {
        if condition { print("PASS: \(message)") } else { failures.append(message); print("FAIL: \(message)") }
    }

    static func main() async {
        guard CommandLine.arguments.count == 2 else { print("Usage: SystemAudioChecks /absolute/path/to/english-fixture.aiff"); exit(2) }
        do { try await run(CommandLine.arguments[1]) }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        if failures.isEmpty { print("System audio checks passed; the global tap, its macOS permission prompt and real playback apps were not exercised.") }
        else { print("\(failures.count) system audio checks failed."); exit(1) }
    }

    static func run(_ path: String) async throws {
        let locale = Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        var ownsReservation = false
        if !(await AssetInventory.reservedLocales).contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == "en-US" }) {
            ownsReservation = try await AssetInventory.reserve(locale: locale)
        }
        defer { if ownsReservation { Task { await AssetInventory.release(reservedLocale: locale) } } }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
              let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            print("SETUP_REQUIRED: prepare English in the app first; this check never downloads assets."); exit(2)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: target)

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [path]
        try player.run()
        defer { if player.isRunning { player.terminate() } }
        // The audio process object exists once the player has opened an output.
        var processObject = AudioObjectID(kAudioObjectUnknown)
        for _ in 0..<100 where processObject == kAudioObjectUnknown {
            if let found = try? SystemAudioTap.processObject(forPID: player.processIdentifier) { processObject = found }
            else { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard processObject != kAudioObjectUnknown else { throw CaptionError.message("The fixture player never opened audio output.") }
        let tap = try SystemAudioTap(onlyProcesses: [processObject], muteBehavior: .mutedWhenTapped)
        let tapDevice = tap.deviceID

        let capture = AudioCapture()
        let stream = try capture.start(deviceID: nil, systemAudio: tap, target: target,
            onLevel: { _ in },
            onProblem: { problem in Task { @MainActor in problems.append(problem) } },
            onSourceActivity: { activity.append($0) })
        let results = Task { @MainActor in
            for try await result in transcriber.results where result.isFinal {
                finals.append((String(result.text.characters), ProcessInfo.processInfo.systemUptime))
            }
        }
        let analysis = Task {
            if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
        }
        while player.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        let playbackEnded = ProcessInfo.processInfo.systemUptime
        // Capture keeps running. Only filled silence can finalize the last sentence.
        for _ in 0..<120 where !finals.contains(where: { $0.text.localizedCaseInsensitiveContains("confirms the change") }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let finalizedWhileRunning = finals.contains { $0.text.localizedCaseInsensitiveContains("confirms the change") }
        let lastFinalDelay = finals.last.map { $0.arrived - playbackEnded }
        // The quiet report follows 1.5 s without source audio, checked twice a second.
        for _ in 0..<70 where activity.last != false { try await Task.sleep(for: .milliseconds(50)) }
        await capture.stop()
        try await analysis.value
        try await results.value

        let transcript = finals.map(\.text).joined(separator: " ")
        print("Recognized after the tap started: \(transcript)")
        expect(transcript.localizedCaseInsensitiveContains("meeting is on Tuesday"),
            "The tapped fixture reached the recognizer through the production capture path")
        expect(finalizedWhileRunning,
            "The last sentence finalized while capture kept running after playback ended" +
            (lastFinalDelay.map { String(format: " (%.2fs after playback ended)", $0) } ?? ""))
        expect(activity.first == true && activity.last == false,
            "Source activity reported playing, then quiet after playback ended: \(activity)")
        expect(problems.isEmpty, "A quiet source reported no input problem: \(problems)")
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tapDevice, &address, 0, nil, &size, &alive)
        expect(status != noErr || alive == 0, "Stopping removed the private tap device")
    }
}
