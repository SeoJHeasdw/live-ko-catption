import CaptionCore
import CryptoKit
import Darwin
import Foundation
@preconcurrency import Translation

private struct Fixture: Codable, Sendable {
    let id: String
    let source: String
    let direction: String
    let domain: String
    let previousSentence: String?
    let goldenMeaning: String
    let requiredTerms: [String]?
    let expectedNumbers: [String]?
    let ambiguityNote: String?

    var captionDirection: CaptionDirection { CaptionDirection(rawValue: direction)! }
    var translationDomain: TranslationDomain { TranslationDomain(rawValue: domain)! }
}

private struct Statistics: Codable, Sendable {
    let ttft_ms: Double?
    let total_ms: Double
    let prefill_ms: Double
    let decode_ms: Double
    let prompt_tokens: Int
    let output_tokens: Int
    let cancelled: Bool
    let timed_out: Bool
    let truncated: Bool

    init(_ native: LocalTranslationStatistics) {
        ttft_ms = native.ttft_ms; total_ms = native.total_ms
        prefill_ms = native.prefill_ms; decode_ms = native.decode_ms
        prompt_tokens = native.prompt_tokens; output_tokens = native.output_tokens
        cancelled = native.cancelled; timed_out = native.timed_out; truncated = native.truncated
    }
}

private struct LocalAttempt: Codable, Sendable {
    var text: String?
    var guardAccepted: Bool?
    var native: Statistics?
    var wall_ms: Double
    var nativeStatus: Int32?
    var error: String?
    var metProduct1500msBudget: Bool? {
        guard let native, text != nil else { return false }
        return native.total_ms <= 1_500
    }
}

private struct AppleAttempt: Codable, Sendable {
    var text: String?
    var wall_ms: Double
    var error: String?
}

private struct FixtureResult: Codable, Sendable {
    var fixture: Fixture
    var appleSourceOnly: AppleAttempt
    var localSourceOnly: LocalAttempt
    var localWithPreviousSentence: LocalAttempt?
    var guardBaseline: String
    var sourceOnlyPrompt: String
    var withContextPrompt: String?
}

private struct Percentiles: Codable {
    var count: Int
    var p50: Double?
    var p95: Double?
    var p99: Double?
    var maximum: Double?

    init(_ samples: [Double]) {
        let sorted = samples.filter(\.isFinite).sorted()
        count = sorted.count
        func percentile(_ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            return sorted[min(sorted.count - 1, max(0, Int(ceil(fraction * Double(sorted.count))) - 1))]
        }
        p50 = percentile(0.5); p95 = percentile(0.95); p99 = percentile(0.99); maximum = sorted.last
    }
}

private struct TimingSummary: Codable {
    let attempts: Int
    let successful: Int
    let acceptedByGuard: Int
    let completedWithinProductBudget: Int
    let timedOut: Int
    let nativeTTFT_ms: Percentiles
    let nativeTotal_ms: Percentiles
    let wall_ms: Percentiles

    init(_ attempts: [LocalAttempt]) {
        self.attempts = attempts.count
        successful = attempts.filter { $0.text != nil }.count
        acceptedByGuard = attempts.filter { $0.guardAccepted == true }.count
        completedWithinProductBudget = attempts.filter { $0.metProduct1500msBudget == true }.count
        timedOut = attempts.filter { $0.native?.timed_out == true || $0.nativeStatus == 2 }.count
        nativeTTFT_ms = Percentiles(attempts.compactMap { $0.native?.ttft_ms })
        nativeTotal_ms = Percentiles(attempts.compactMap { $0.native?.total_ms })
        wall_ms = Percentiles(attempts.map(\.wall_ms))
    }
}

private struct LifecycleChecks: Codable {
    var busyRejected = false
    var cancellationObserved = false
    var cancellationReturn_ms: Double = 0
    var recoverySucceeded = false
    var lateCancellationOfCompletedTaskDidNotCancelNextRequest = false
    var details: [String] = []
    var allPassed: Bool {
        busyRejected && cancellationObserved && recoverySucceeded && lateCancellationOfCompletedTaskDidNotCancelNextRequest
    }
}

private struct Telemetry: Codable, Sendable {
    let residentRSSBytes: UInt64?
    let peakProcessRSSBytes: Int64?
    let processCPUSeconds: Double?
    let thermalState: String

    static func read() -> Self {
        var usage = rusage()
        let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Self(residentRSSBytes: status == KERN_SUCCESS ? UInt64(info.resident_size) : nil,
                    peakProcessRSSBytes: hasUsage ? Int64(usage.ru_maxrss) : nil,
                    processCPUSeconds: hasUsage ? seconds(usage.ru_utime) + seconds(usage.ru_stime) : nil,
                    thermalState: thermal)
    }
}

private struct SoakSample: Codable, Sendable {
    let index: Int
    let fixtureID: String
    let elapsedSeconds: Double
    let local: LocalAttempt
    let telemetry: Telemetry
}

private struct SoakReport: Codable {
    let requestedSeconds: Double
    let elapsedSeconds: Double
    let intervalSeconds: Double
    let timeoutMilliseconds: Int32
    let scheduling: String
    let maximumConcurrentNativeRequests: Int
    let queuedCatchUpRequests: Int
    let timing: TimingSummary
    let telemetryBefore: Telemetry
    let telemetryAfter: Telemetry
    let samples: [SoakSample]
}

private struct ModelManifest: Decodable {
    let model: String
    let quantization: String
    let repository: String
    let revision: String
    let filename: String
    let byteCount: UInt64
    let sha256: String
}

private struct ModelMetadata: Codable {
    let model: String
    let quantization: String
    let repository: String
    let expectedRevision: String
    let expectedSHA256: String
    let expectedByteCount: UInt64
    let actualByteCount: UInt64
    let modelPath: String
    let provenanceVerification: String
}

private struct Report: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let platform: String
    let machine: String
    let physicalMemoryBytes: UInt64
    let processors: Int
    let model: ModelMetadata
    let runtimePath: String
    let fixturesSHA256: String
    let conditions: [String]
    let qualityTimeoutMilliseconds: Int32
    let productTimeoutMilliseconds: Int32
    let coldLoad_ms: Double
    let firstTranslationAfterLoad: LocalAttempt
    let applePreparation_ms: [String: Double]
    let appleReadiness: [String: String]
    let fixtureResults: [FixtureResult]
    let sourceOnlySummary: TimingSummary
    let withContextSummary: TimingSummary
    let lifecycle: LifecycleChecks
    var soak: SoakReport?
    let limitations: [String]
}

private struct Options {
    var model = ".build/local-model/Hy-MT2-1.8B-Q6_K.gguf"
    var runtime = ".build/local-runtime/libcaption_local_translation.dylib"
    var fixtures = "Tests/LocalPolishChecks/fixtures.json"
    var manifest = "Resources/local-model-manifest.json"
    var output = ".build/local-polish-checks/summary.json"
    var timeout: Int32 = 3_000
    var soakTimeout: Int32 = 1_500
    var soakSeconds: Double = 0
    var intervalSeconds: Double = 2

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard index + 1 < arguments.count else { throw CheckError.invalidArguments }
            let value = arguments[index + 1]
            switch key {
            case "--model": model = value
            case "--runtime": runtime = value
            case "--fixtures": fixtures = value
            case "--manifest": manifest = value
            case "--output": output = value
            case "--timeout-ms": guard let number = Int32(value), number >= 1, number <= 120_000 else { throw CheckError.invalidArguments }; timeout = number
            case "--soak-timeout-ms": guard let number = Int32(value), number >= 1, number <= 120_000 else { throw CheckError.invalidArguments }; soakTimeout = number
            case "--soak-seconds": guard let number = Double(value), number.isFinite, number >= 0, number <= 43_200 else { throw CheckError.invalidArguments }; soakSeconds = number
            case "--interval-seconds": guard let number = Double(value), number.isFinite, number >= 1, number <= 60 else { throw CheckError.invalidArguments }; intervalSeconds = number
            default: throw CheckError.invalidArguments
            }
            index += 2
        }
    }
}

private enum CheckError: Error { case invalidArguments, invalidFixture, modelSizeMismatch }

@main
private struct LocalPolishChecks {
    @MainActor
    static func main() async {
        do { try await run(Options(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data("Local polish checks failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run(_ options: Options) async throws {
        let modelURL = URL(fileURLWithPath: options.model)
        let runtimeURL = URL(fileURLWithPath: options.runtime)
        let outputURL = URL(fileURLWithPath: options.output)
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: options.fixtures))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: fixtureData)
        guard !fixtures.isEmpty, Set(fixtures.map(\.id)).count == fixtures.count,
              fixtures.allSatisfy({ CaptionDirection(rawValue: $0.direction) != nil && TranslationDomain(rawValue: $0.domain) != nil }) else {
            throw CheckError.invalidFixture
        }
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: URL(fileURLWithPath: options.manifest)))
        let bytes = (try FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard bytes == manifest.byteCount else { throw CheckError.modelSizeMismatch }
        let engine = LocalTranslationEngine(runtimeURL: runtimeURL)
        let loadStart = uptime()
        try await engine.prepare(modelURL: modelURL)
        let coldLoad = elapsed(loadStart)
        let warmup = await local(engine, request: LocalTranslationRequest(source: "Hello.", baseline: "안녕하세요.", direction: .englishToKorean), timeout: options.timeout)
        print("Loaded local model in \(Int(coldLoad)) ms. Measuring \(fixtures.count) synthetic text fixtures.")

        var leases: [CaptionDirection: TranslationSessionLease] = [:]
        var appleReadiness: [String: String] = [:]
        var preparation: [String: Double] = [:]
        for direction in CaptionDirection.allCases {
            let source = Locale.Language(identifier: direction.sourceLanguageCode)
            let target = Locale.Language(identifier: direction.targetLanguageCode)
            let status = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
            guard status == .installed else {
                appleReadiness[direction.rawValue] = "Unavailable: installed models required; no download requested by this check."
                continue
            }
            let lease = TranslationSessionLease(installedSource: source, target: target, preferredStrategy: .lowLatency)
            let began = uptime()
            do {
                try await OperationDeadline.run(seconds: 15, name: "Installed Apple translation preparation", onTimeout: { lease.retire() }) {
                    try await lease.prepareTranslation()
                }
                leases[direction] = lease
                appleReadiness[direction.rawValue] = "installed"
            } catch {
                lease.retire()
                appleReadiness[direction.rawValue] = "Preparation failed: \(error.localizedDescription)"
            }
            preparation[direction.rawValue] = elapsed(began)
        }
        defer { for lease in leases.values { lease.retire() } }

        var results: [FixtureResult] = []
        for fixture in fixtures {
            let baseline = await apple(leases[fixture.captionDirection], source: fixture.source)
            let baselineText = baseline.text ?? fixture.source
            let plainRequest = request(fixture, baseline: baselineText, includeContext: false)
            let plain = await local(engine, request: plainRequest, timeout: options.timeout)
            let contextual: LocalAttempt?
            if let previous = fixture.previousSentence, !previous.isEmpty {
                contextual = await local(engine, request: request(fixture, baseline: baselineText, includeContext: true), timeout: options.timeout)
            } else { contextual = nil }
            results.append(FixtureResult(fixture: fixture, appleSourceOnly: baseline, localSourceOnly: plain,
                                         localWithPreviousSentence: contextual,
                                         guardBaseline: baseline.text == nil ? "source text (Apple baseline unavailable)" : "Apple source-only translation",
                                         sourceOnlyPrompt: plainRequest.prompt,
                                         withContextPrompt: contextual == nil ? nil : request(fixture, baseline: baselineText, includeContext: true).prompt))
        }
        let lifecycle = await lifecycleChecks(engine, fixture: fixtures[0], timeout: options.timeout)
        let sourceSummary = TimingSummary(results.map(\.localSourceOnly))
        let contextSummary = TimingSummary(results.compactMap(\.localWithPreviousSentence))
        var report = Report(schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
            platform: ProcessInfo.processInfo.operatingSystemVersionString, machine: machineName(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, processors: ProcessInfo.processInfo.processorCount,
            model: ModelMetadata(model: manifest.model, quantization: manifest.quantization, repository: manifest.repository,
                expectedRevision: manifest.revision, expectedSHA256: manifest.sha256, expectedByteCount: manifest.byteCount,
                actualByteCount: bytes, modelPath: modelURL.path,
                provenanceVerification: "Pinned manifest metadata and file size recorded. This driver does not rehash the 1.47 GB model; installation verifies SHA-256 separately."),
            runtimePath: runtimeURL.path,
            fixturesSHA256: SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined(),
            conditions: ["Apple: installed local lowLatency translation, source sentence only, one reusable lease per language direction.",
                "Local source-only: same source plus explicit direction/domain instructions and matching bounded IT terms; no previous sentence.",
                "Local with context: same request plus exactly one previous source sentence, where the fixture supplies one.",
                "The local model translates source directly. Apple output is used only for the production numeric/output guard, not included in the local prompt.",
                "Raw completed local candidates are captured with validateResult=false; guardAccepted is reported separately.",
                "Native measurements include prefill and output generation. The wall measurement includes the Swift/native call. Cold model load and first generation are reported separately."],
            qualityTimeoutMilliseconds: options.timeout, productTimeoutMilliseconds: 1_500,
            coldLoad_ms: coldLoad, firstTranslationAfterLoad: warmup,
            applePreparation_ms: preparation, appleReadiness: appleReadiness, fixtureResults: results,
            sourceOnlySummary: sourceSummary, withContextSummary: contextSummary, lifecycle: lifecycle, soak: nil,
            limitations: ["Authored text fixtures are not a representative translation benchmark or live speech-recognition test.",
                "Guard acceptance is a syntax/number check, not a semantic accuracy score. goldenMeaning and review notes require human semantic review.",
                "Apple source-only and local context-enabled conditions have different information; do not attribute contextual gains solely to the model.",
                "This sequential native-engine soak does not establish live microphone, full application scheduling, end-to-end caption latency, or fan noise.",
                "Peak RSS is process lifetime high-water memory in bytes on macOS; current resident RSS is sampled separately. Thermal state is the OS-reported category.",
                "Samples that time out have no usable completed caption and are included in timeout counts. Timing distributions include available native statistics from failures."])
        try save(report, to: outputURL)
        print("Fixture measurements saved to \(outputURL.path). Lifecycle checks: \(lifecycle.allPassed ? "passed" : "FAILED").")
        if options.soakSeconds > 0 {
            report.soak = try await soak(engine, results: results, options: options, outputURL: outputURL)
            try save(report, to: outputURL)
            print("Soak complete: \(Int(report.soak!.elapsedSeconds)) seconds, \(report.soak!.samples.count) native requests. Saved \(outputURL.path).")
        }
        if !lifecycle.allPassed { exit(1) }
    }

    private static func request(_ fixture: Fixture, baseline: String, includeContext: Bool) -> LocalTranslationRequest {
        LocalTranslationRequest(source: fixture.source, baseline: baseline, direction: fixture.captionDirection,
                                domain: fixture.translationDomain, previousSentence: includeContext ? fixture.previousSentence ?? "" : "")
    }

    @MainActor
    private static func apple(_ lease: TranslationSessionLease?, source: String) async -> AppleAttempt {
        let began = uptime()
        guard let lease, !lease.isRetired else {
            return AppleAttempt(text: nil, wall_ms: elapsed(began), error: "Installed Apple model/session unavailable; no download requested.")
        }
        do {
            let text = try await OperationDeadline.run(seconds: 15, name: "Apple source-only translation", onTimeout: { lease.retire() }) {
                try await lease.translate(source)
            }
            return AppleAttempt(text: text, wall_ms: elapsed(began), error: nil)
        } catch { return AppleAttempt(text: nil, wall_ms: elapsed(began), error: error.localizedDescription) }
    }

    private static func local(_ engine: LocalTranslationEngine, request: LocalTranslationRequest, timeout: Int32) async -> LocalAttempt {
        let began = uptime()
        do {
            let result = try await engine.translate(request, timeoutMilliseconds: timeout, validateResult: false)
            return LocalAttempt(text: result.text, guardAccepted: request.accepts(result.text), native: Statistics(result.statistics),
                                wall_ms: elapsed(began), nativeStatus: 0, error: nil)
        } catch {
            var native: Statistics?
            var status: Int32?
            if case .native(let code, let json) = error as? LocalTranslationError {
                status = code
                if let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode(LocalTranslationStatistics.self, from: data) {
                    native = Statistics(decoded)
                }
            }
            return LocalAttempt(text: nil, guardAccepted: nil, native: native, wall_ms: elapsed(began), nativeStatus: status,
                                error: error.localizedDescription)
        }
    }

    private static func lifecycleChecks(_ engine: LocalTranslationEngine, fixture: Fixture, timeout: Int32) async -> LifecycleChecks {
        var checks = LifecycleChecks()
        let source = String(repeating: "The API is slow, but we must not drop requests. ", count: 17)
        let long = LocalTranslationRequest(source: source, baseline: "", direction: .englishToKorean, domain: .it)
        let holder = Task { try await engine.translate(long, timeoutMilliseconds: max(timeout, 3_000), validateResult: false) }
        try? await Task.sleep(for: .milliseconds(30))
        do { _ = try await engine.translate(long, timeoutMilliseconds: timeout, validateResult: false) }
        catch LocalTranslationError.busy { checks.busyRejected = true }
        catch { checks.details.append("Busy probe returned \(error)") }
        let began = uptime()
        holder.cancel()
        do { _ = try await holder.value; checks.details.append("Canceled active request completed without cancellation.") }
        catch is CancellationError { checks.cancellationObserved = true }
        catch { checks.details.append("Cancellation returned \(error)") }
        checks.cancellationReturn_ms = elapsed(began)
        let short = request(fixture, baseline: "", includeContext: false)
        let completedTask = Task { try await engine.translate(short, timeoutMilliseconds: max(timeout, 3_000), validateResult: false) }
        do { _ = try await completedTask.value; checks.recoverySucceeded = true }
        catch { checks.details.append("Recovery failed: \(error)") }
        let next = Task { try await engine.translate(short, timeoutMilliseconds: max(timeout, 3_000), validateResult: false) }
        try? await Task.sleep(for: .milliseconds(30))
        completedTask.cancel()
        do { _ = try await next.value; checks.lateCancellationOfCompletedTaskDidNotCancelNextRequest = true }
        catch { checks.details.append("Next request after stale completed-task cancellation failed: \(error)") }
        return checks
    }

    private static func soak(_ engine: LocalTranslationEngine, results: [FixtureResult], options: Options,
                             outputURL: URL) async throws -> SoakReport {
        let began = uptime()
        let before = Telemetry.read()
        let logURL = outputURL.deletingPathExtension().appendingPathExtension("soak.jsonl")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        var samples: [SoakSample] = []
        var nextStart = began
        var nextHeartbeat = began
        print("Starting \(Int(options.soakSeconds))-second native-model soak at \(options.intervalSeconds)-second cadence. \(logURL.path)")
        while uptime() - began < options.soakSeconds {
            try Task.checkCancellation()
            let wait = nextStart - uptime()
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            if uptime() - began >= options.soakSeconds { break }
            let start = uptime()
            let result = results[samples.count % results.count]
            let input = request(result.fixture, baseline: result.appleSourceOnly.text ?? result.fixture.source, includeContext: true)
            let attempt = await local(engine, request: input, timeout: options.soakTimeout)
            let sample = SoakSample(index: samples.count, fixtureID: result.fixture.id, elapsedSeconds: uptime() - began,
                                    local: attempt, telemetry: Telemetry.read())
            samples.append(sample)
            // Start-to-start cadence, with no accumulated catch-up work after a
            // slow request. The next iteration cannot overlap the active one.
            nextStart = max(start + options.intervalSeconds, uptime())
            if uptime() >= nextHeartbeat {
                struct Heartbeat: Encodable {
                    let elapsedSeconds: Double
                    let requests: Int
                    let timedOut: Int
                    let nativeTotal_ms: Percentiles
                    let telemetry: Telemetry
                }
                let summary = TimingSummary(samples.map(\.local))
                let heartbeat = Heartbeat(elapsedSeconds: uptime() - began, requests: samples.count, timedOut: summary.timedOut,
                                          nativeTotal_ms: summary.nativeTotal_ms, telemetry: sample.telemetry)
                let data = try JSONEncoder().encode(heartbeat)
                try log.write(contentsOf: data + Data("\n".utf8))
                try log.synchronize()
                nextHeartbeat = uptime() + 30
                print("Soak \(Int(uptime() - began))s: \(samples.count) requests; \(summary.timedOut) timeouts; thermal \(sample.telemetry.thermalState).")
            }
        }
        return SoakReport(requestedSeconds: options.soakSeconds, elapsedSeconds: uptime() - began,
                          intervalSeconds: options.intervalSeconds, timeoutMilliseconds: options.soakTimeout,
                          scheduling: "Sequential fixed start-to-start cadence; slow requests discard missed schedule ticks; no catch-up queue.",
                          maximumConcurrentNativeRequests: 1, queuedCatchUpRequests: 0,
                          timing: TimingSummary(samples.map(\.local)), telemetryBefore: before, telemetryAfter: Telemetry.read(), samples: samples)
    }

    private static func save(_ report: Report, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: file, options: .atomic)
    }

    private static func machineName() -> String {
        var value = utsname()
        uname(&value)
        return withUnsafeBytes(of: value.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func elapsed(_ began: TimeInterval) -> Double { (uptime() - began) * 1_000 }
}
