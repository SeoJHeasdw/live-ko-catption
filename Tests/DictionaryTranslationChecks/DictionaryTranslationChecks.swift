import CaptionCore
import CryptoKit
import Darwin
import Foundation

private struct Fixture: Codable, Sendable {
    let id: String
    let source: String
    let direction: String
    let dictionaryIDs: [String]
    let meaningExpectation: String
    let referenceExpectation: String
}

private struct TermPair: Codable {
    let source: String
    let target: String
}

private struct NativeStatistics: Codable {
    let ttft_ms: Double?
    let total_ms: Double
    let prompt_tokens: Int
    let output_tokens: Int
    let cancelled: Bool
    let timed_out: Bool
    let truncated: Bool

    init(_ value: LocalTranslationStatistics) {
        ttft_ms = value.ttft_ms; total_ms = value.total_ms
        prompt_tokens = value.prompt_tokens; output_tokens = value.output_tokens
        cancelled = value.cancelled; timed_out = value.timed_out; truncated = value.truncated
    }
}

private struct Attempt: Codable {
    let fixture: Fixture
    let condition: String
    let selectedDictionaryNames: [String]
    let referencePairs: [TermPair]
    let prompt: String
    var text: String?
    var guardAccepted: Bool?
    var statistics: NativeStatistics?
    var wall_ms: Double = 0
    var nativeStatus: Int32?
    var error: String?
}

private struct Manifest: Decodable {
    let model: String
    let quantization: String
    let repository: String
    let revision: String
    let filename: String
    let byteCount: UInt64
    let sha256: String?
    let sha256Constant: String?
    let installedRelativePath: String
}

private struct ModelVerification: Codable {
    let name: String
    let quantization: String
    let repository: String
    let revision: String
    let path: String
    let expectedByteCount: UInt64
    let actualByteCount: UInt64
    let expectedSHA256: String
    let actualSHA256: String
    let digestSource: String
}

private struct PreviousPromptEvidence: Codable {
    let generatedAt: String
    let reason: String
    let attempts: [Attempt]
}

private struct Report: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let platform: String
    let model: ModelVerification
    let runtimePath: String
    let timeoutMilliseconds: Int32
    let fixtureSHA256: String
    let conditions: [String]
    let limitations: [String]
    var attempts: [Attempt] = []
    var infrastructureError: String?
    var previousPromptEvidence: PreviousPromptEvidence?
}

private struct Options {
    var model: String?
    var runtime = ".build/local-runtime/libcaption_local_translation.dylib"
    var manifest = "Resources/local-model-manifest.json"
    var output = "docs/qa/raw/dictionary-translation-20261002.json"
    var timeout: Int32 = 6_000

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw CheckError.invalidArguments }
            let key = arguments[index], value = arguments[index + 1]
            switch key {
            case "--model": model = value
            case "--runtime": runtime = value
            case "--manifest": manifest = value
            case "--output": output = value
            case "--timeout-ms":
                guard let number = Int32(value), number > 0, number <= 60_000 else { throw CheckError.invalidArguments }
                timeout = number
            default: throw CheckError.invalidArguments
            }
            index += 2
        }
    }
}

private enum CheckError: Error {
    case invalidArguments, invalidManifest, modelNotInstalled, modelSizeMismatch, modelDigestMismatch
    case runtimeUnavailable, missingDictionary, invalidFixture
}

@main
private struct DictionaryTranslationChecks {
    static func main() async {
        do { try await run(Options(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            FileHandle.standardError.write(Data("Dictionary translation comparison failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: options.manifest)))
        guard manifest.filename == "Hy-MT2-1.8B-Q6_K.gguf", manifest.quantization == "Q6_K" else { throw CheckError.invalidManifest }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let modelURL = options.model.map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent(manifest.installedRelativePath)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw CheckError.modelNotInstalled }
        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              modelURL.lastPathComponent == manifest.filename, bytes == manifest.byteCount else { throw CheckError.modelSizeMismatch }
        let (expectedDigest, digestSource) = try expectedSHA256(manifest)
        print("Verifying installed pinned model size and streaming SHA-256 before loading.")
        let actualDigest = try digest(modelURL)
        guard actualDigest == expectedDigest else { throw CheckError.modelDigestMismatch }
        let runtimeURL = URL(fileURLWithPath: options.runtime)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else { throw CheckError.runtimeUnavailable }
        let fixtureData = try JSONEncoder().encode(fixtures)
        let verification = ModelVerification(name: manifest.model, quantization: manifest.quantization,
            repository: manifest.repository, revision: manifest.revision, path: modelURL.path,
            expectedByteCount: manifest.byteCount, actualByteCount: bytes,
            expectedSHA256: expectedDigest, actualSHA256: actualDigest, digestSource: digestSource)
        var report = Report(schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
            platform: ProcessInfo.processInfo.operatingSystemVersionString, model: verification,
            runtimePath: runtimeURL.path, timeoutMilliseconds: options.timeout,
            fixtureSHA256: hex(SHA256.hash(data: fixtureData)),
            conditions: ["none: the source and explicit translation direction, with no dictionaries.",
                "contextOnly: the same selected public dictionaries cloned with empty glossaries.",
                "contextAndTerms: the same selected public dictionaries with their current reviewed terms.",
                "One prepared local engine; all attempts are serial. No previous sentence or private glossary is supplied.",
                "No Apple translation, audio capture, network requests, downloads, or application preference changes.",
                "Raw candidates use validateResult=false; the production output guard is recorded separately with source text as its numeric baseline."],
            limitations: ["Ten authored public synthetic sentences are an exploratory comparison, not a representative accuracy benchmark.",
                "Guard acceptance checks output format, script and numbers, not meaning preservation, fluency, or terminology accuracy.",
                "The 6000 ms default is a quality comparison timeout, not evidence that the production 1500 ms budget is met.",
                "Candidate wording and timing may vary across runs; condition order is fixed and there are no repeated samples.",
                "A reviewer must inspect meaningExpectation, referenceExpectation, matched referencePairs, and raw text.",
                "This runner does not establish live microphone accuracy, end-to-end caption latency, or Apple baseline behavior."])
        let outputURL = URL(fileURLWithPath: options.output)
        if let oldData = try? Data(contentsOf: outputURL),
           let old = try? JSONDecoder().decode(Report.self, from: oldData) {
            report.previousPromptEvidence = old.previousPromptEvidence
            let examples = old.attempts.filter {
                $0.prompt.contains("[Subject Areas]") &&
                (($0.fixture.id == "finance-en" && $0.condition != "none") ||
                 (["ibm-ko", "mixed-en"].contains($0.fixture.id) && $0.condition == "contextAndTerms"))
            }
            if !examples.isEmpty {
                report.previousPromptEvidence = PreviousPromptEvidence(generatedAt: old.generatedAt,
                    reason: "Retained raw examples from the earlier Subject Areas prompt: instruction leakage or meaning loss observed in manual review.",
                    attempts: examples)
            }
        }
        let engine = LocalTranslationEngine(runtimeURL: runtimeURL)
        do {
            try await engine.prepare(modelURL: modelURL)
            guard Set(fixtures.map(\.id)).count == fixtures.count else { throw CheckError.invalidFixture }
            for fixture in fixtures {
                guard let direction = CaptionDirection(rawValue: fixture.direction) else { throw CheckError.invalidFixture }
                let selected = fixture.dictionaryIDs.compactMap { id in BuiltInDictionaries.all.first { $0.id == id } }
                guard selected.count == fixture.dictionaryIDs.count else { throw CheckError.missingDictionary }
                let contexts = selected.map { CaptionDictionary(id: $0.id, name: $0.name, context: $0.context, glossary: .empty) }
                for (condition, dictionaries) in [("none", [CaptionDictionary]()), ("contextOnly", contexts), ("contextAndTerms", selected)] {
                    let request = LocalTranslationRequest(source: fixture.source, baseline: fixture.source,
                        direction: direction, dictionaries: dictionaries)
                    guard request.isWithinBudget else { throw CheckError.invalidFixture }
                    var attempt = Attempt(fixture: fixture, condition: condition,
                        selectedDictionaryNames: dictionaries.map(\.name),
                        referencePairs: request.relevantTerms.map { TermPair(source: $0.0, target: $0.1) }, prompt: request.prompt)
                    let began = ProcessInfo.processInfo.systemUptime
                    do {
                        let result = try await engine.translate(request, timeoutMilliseconds: options.timeout, validateResult: false)
                        attempt.text = result.text
                        attempt.guardAccepted = request.accepts(result.text)
                        attempt.statistics = NativeStatistics(result.statistics)
                        attempt.nativeStatus = 0
                    } catch {
                        attempt.error = String(describing: error)
                        if let local = error as? LocalTranslationError, case .native(let status, let json) = local {
                            attempt.nativeStatus = status
                            if let data = json.data(using: .utf8), let statistics = try? JSONDecoder().decode(LocalTranslationStatistics.self, from: data) {
                                attempt.statistics = NativeStatistics(statistics)
                            }
                        }
                        attempt.wall_ms = (ProcessInfo.processInfo.systemUptime - began) * 1_000
                        report.attempts.append(attempt)
                        try save(report, to: outputURL)
                        // A generation timeout is an observed candidate failure.
                        // Other native/session errors invalidate the comparison.
                        if attempt.nativeStatus == 2 { continue }
                        throw error
                    }
                    attempt.wall_ms = (ProcessInfo.processInfo.systemUptime - began) * 1_000
                    report.attempts.append(attempt)
                    try save(report, to: outputURL)
                }
                print("Compared \(fixture.id) under all three dictionary conditions.")
            }
        } catch {
            report.infrastructureError = String(describing: error)
            try save(report, to: outputURL)
            throw error
        }
        print("Saved \(report.attempts.count) raw attempts to \(outputURL.path). Human semantic review is required.")
    }

    private static func expectedSHA256(_ manifest: Manifest) throws -> (String, String) {
        if let value = manifest.sha256, value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
            return (value, "Resources/local-model-manifest.json: sha256")
        }
        guard let constant = manifest.sha256Constant,
              constant == "Sources/LiveKoCaption/LocalModelStore.swift: LocalModelManifest.hyMT2.sha256" else { throw CheckError.invalidManifest }
        let source = try String(contentsOfFile: "Sources/LiveKoCaption/LocalModelStore.swift", encoding: .utf8)
        guard let start = source.range(of: "static let hyMT2 = LocalModelManifest("),
              let end = source.range(of: "\n    )", range: start.upperBound..<source.endIndex) else { throw CheckError.invalidManifest }
        let definition = String(source[start.upperBound..<end.lowerBound])
        let expression = try NSRegularExpression(pattern: #"sha256:\s*"([0-9a-f]{64})""#)
        let ns = definition as NSString
        guard let match = expression.firstMatch(in: definition, range: NSRange(location: 0, length: ns.length)) else { throw CheckError.invalidManifest }
        return (ns.substring(with: match.range(at: 1)), constant)
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func save(_ report: Report, to output: URL) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private static let fixtures: [Fixture] = [
        Fixture(id: "ai-en", source: "We use retrieval-augmented generation to provide relevant documents to a large language model.",
            direction: "englishToKorean", dictionaryIDs: [BuiltInDictionaries.aiID],
            meaningExpectation: "Documents are supplied to the model using RAG; do not claim retraining or improved accuracy.",
            referenceExpectation: "Preserve the meanings of retrieval-augmented generation and large language model."),
        Fixture(id: "ai-ko", source: "검색 증강 생성으로 관련 문서를 대규모 언어 모델에 제공합시다.",
            direction: "koreanToEnglish", dictionaryIDs: [BuiltInDictionaries.aiID],
            meaningExpectation: "A proposal to supply relevant documents to the model using RAG; retain the proposal tone.",
            referenceExpectation: "Use the correct RAG and large language model terminology where matched."),
        Fixture(id: "ibm-en", source: "Let's use IBM watsonx.ai and IBM Db2 in the demo, then review the disaster recovery plan.",
            direction: "englishToKorean", dictionaryIDs: [BuiltInDictionaries.ibmID],
            meaningExpectation: "A proposal to use two named products in a demo and subsequently review a plan.",
            referenceExpectation: "Preserve IBM watsonx.ai and IBM Db2 product names; preserve disaster recovery meaning."),
        Fixture(id: "ibm-ko", source: "데모에서 IBM watsonx.ai와 IBM Db2를 사용한 다음 재해 복구 계획을 검토합시다.",
            direction: "koreanToEnglish", dictionaryIDs: [BuiltInDictionaries.ibmID],
            meaningExpectation: "A proposal, with demo use followed by review of the disaster recovery plan.",
            referenceExpectation: "Preserve IBM watsonx.ai and IBM Db2 product names."),
        Fixture(id: "finance-en", source: "Review the anti-money laundering workflow and credit risk before discussing the liquidity coverage ratio.",
            direction: "englishToKorean", dictionaryIDs: [BuiltInDictionaries.financeID],
            meaningExpectation: "Review the AML workflow and credit risk before discussion of LCR; preserve the order.",
            referenceExpectation: "Keep AML, credit risk and liquidity coverage ratio distinct; do not invent ratios."),
        Fixture(id: "finance-ko", source: "유동성커버리지비율을 논의하기 전에 자금 세탁 방지 업무와 신용위험을 검토합시다.",
            direction: "koreanToEnglish", dictionaryIDs: [BuiltInDictionaries.financeID],
            meaningExpectation: "A proposal to review AML work and credit risk before the LCR discussion.",
            referenceExpectation: "Translate the financial phrases in their banking sense; inspect exact matched references."),
        Fixture(id: "mixed-en", source: "Let's evaluate IBM watsonx.ai and a large language model for reviewing customer onboarding documents.",
            direction: "englishToKorean", dictionaryIDs: [BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID, BuiltInDictionaries.financeID],
            meaningExpectation: "A proposal to evaluate technologies for document review; do not assert an existing deployment.",
            referenceExpectation: "Keep the product name and model term, and use customer onboarding in the banking sense."),
        Fixture(id: "mixed-ko", source: "고객 온보딩 문서 검토에 IBM watsonx.ai와 대규모 언어 모델을 사용할지 평가합시다.",
            direction: "koreanToEnglish", dictionaryIDs: [BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID, BuiltInDictionaries.financeID],
            meaningExpectation: "A proposal to assess whether to use technologies for customer document review.",
            referenceExpectation: "Keep product, AI and customer onboarding terminology while retaining uncertainty."),
        Fixture(id: "ordinary-en", source: "I recall our last meeting, and I have an interest in learning more about your weekend plans.",
            direction: "englishToKorean", dictionaryIDs: [BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID, BuiltInDictionaries.financeID],
            meaningExpectation: "The speaker remembers a meeting and is curious about weekend plans; recall is not an AI metric and interest is not bank interest.",
            referenceExpectation: "Do not introduce 재현율 or 금리/이자; ordinary recall and interest should have no glossary reference."),
        Fixture(id: "ordinary-ko", source: "지난 회의가 기억나고, 당신의 주말 계획을 더 알고 싶습니다.",
            direction: "koreanToEnglish", dictionaryIDs: [BuiltInDictionaries.aiID, BuiltInDictionaries.ibmID, BuiltInDictionaries.financeID],
            meaningExpectation: "Remembering a meeting and wanting to know more about weekend plans, with no financial or AI metric meaning.",
            referenceExpectation: "Keep the ordinary meaning without adding technical or financial content.")
    ]
}
