import AppKit
@preconcurrency import AVFoundation
import CaptionCore
import CoreMedia
import Foundation
import Observation
import Speech
@preconcurrency import Translation
import UniformTypeIdentifiers

@MainActor @Observable
final class CaptionModel {
    enum Phase { case idle, starting, listening, stopping }
    var phase: Phase = .idle
    private var storedDirection: CaptionDirection
    private var storedDomain: TranslationDomain
    private let preferencesDefaults: UserDefaults
    private var storedPolishEnabled: Bool
    var polishEnabled: Bool {
        get { storedPolishEnabled }
        set {
            guard newValue != storedPolishEnabled, phase == .idle, !isPreparing,
                  !isPreview, !isUISoak, !hasPendingTranslations else { return }
            storedPolishEnabled = newValue
            localPolishReady = false
            preferencesDefaults.set(newValue, forKey: "localPolishEnabled")
            localPreparationID = nil
            if newValue { Task { [weak self] in await self?.prepareLocalModel() } }
            else { localEngine.unload(); isPreparingLocalModel = false; localPolishMessage = "빠른 번역 사용" }
        }
    }
    var isPreparingLocalModel = false
    var localPolishMessage = "문맥 다듬기 꺼짐"
    var localPolishMilliseconds: Double?
    private var localPreparationID: UUID?
    private var localPolishDegraded = false
    private var localPolishReady = false
    private var finalFastBaselines: [UUID: (revision: Int, translation: String)] = [:]
    /// A source-final caption that shows its fast baseline while the optional
    /// local model decides the final wording on a lane of its own.
    private struct PolishItem { let job: TranslationJob; let baseline: String }
    static let polishWaitingLimit = 2
    private var polishWaiting: [PolishItem] = []
    private var activePolish: PolishItem?
    private var polishTask: Task<String, any Error>?
    private var polishWorker: Task<Void, Never>?
    private var polishLaneID: UUID?
    private let localEngine: LocalTranslationEngine
    var selectedDirection: CaptionDirection {
        get { storedDirection }
        set {
            guard newValue != storedDirection, canChangeSessionSettings else { return }
            storedDirection = newValue
            preferencesDefaults.set(newValue.rawValue, forKey: CaptionDirection.preferenceKey)
            // Disable Start immediately, before the newly scheduled check gets
            // an actor turn. A previous pair's suspended check cannot re-enable it.
            readinessID = nil
            assetsReady = false
            isChecking = true
            translationConfiguration = nil
            message = nil
            Task { [weak self] in await self?.checkReadiness() }
        }
    }
    var translationDomain: TranslationDomain {
        get { storedDomain }
        set {
            guard newValue != storedDomain, canChangeSessionSettings else { return }
            storedDomain = newValue
            preferencesDefaults.set(newValue.rawValue, forKey: TranslationDomain.preferenceKey)
        }
    }
    var devices: [AudioInputDevice] = []
    var selectedDeviceUID: String {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: "inputDeviceUID") }
    }
    var showEnglish: Bool {
        didSet { UserDefaults.standard.set(showEnglish, forKey: "showEnglish") }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    var contextCorrectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(contextCorrectionEnabled, forKey: "contextCorrectionEnabled")
            if !contextCorrectionEnabled {
                contextJobs.removeAll()
                contextSession?.retire(); contextTask?.cancel()
                activeContext = nil
                queuedTranslations = translationQueue.count
            }
        }
    }
    var isPreview = false
    var isUISoak = false {
        didSet {
            guard isUISoak else { return }
            // Synthetic English fixtures keep their declared language even if
            // the user last used Korean input. Do not overwrite user preferences.
            storedDirection = .englishToKorean
            storedDomain = .general
            readinessID = nil
        }
    }
    var isChecking = true
    var isPreparing = false
    var assetsReady = false
    var preparationMessage = ""
    var preparationProgress: Double?
    var message: String?
    var audioLevel: Double = 0
    var translationMilliseconds: Double?
    var speechDelaySeconds: Double?
    var captionDelaySeconds: Double?
    var startedAt = Date()
    private var sessionCreatedAt = Date()
    private var inputWarnings: [String] = []
    var translationConfiguration: TranslationSession.Configuration?
    private(set) var timeline = CaptionTimeline()
    private(set) var queuedTranslations = 0
    private var capture: AudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var translationSession: TranslationSessionLease?
    private var activeTranslation: TranslationJob?
    private var translationTask: Task<String, any Error>?
    private var translationQueue = TranslationQueue()
    private var workerID: UUID?
    private var contextJobs: [ContextTranslationJob] = []
    private var contextSession: TranslationSessionLease?
    private var activeContext: ContextTranslationJob?
    private var contextTask: Task<String, any Error>?
    private var contextTimedOut = false
    private let translationOverride: (@MainActor (String, Bool) async throws -> String)?
    private let microphoneAccessOverride: (@MainActor () async -> Bool)?
    private let readinessOverride: (@MainActor (CaptionDirection) async throws -> Bool)?
    private let polishOverride: (@MainActor (LocalTranslationRequest) async throws -> String)?
    private let polishTimeoutSeconds: Double
    private var readinessID: UUID?
    private var runHasAudio = false
    // The recognizer delivers several revisions within a few milliseconds and
    // then stays quiet. Draft admission waits for that burst to settle so the
    // newest revision is translated, with a bounded hold for a steady trickle.
    static let draftSettleSeconds = 0.05
    static let draftHoldLimitSeconds = 0.15
    private var draftHeldSince: TimeInterval?
    private var lastAcceptedSourceUptime: TimeInterval = 0
    private var runID: UUID?
    private var runUptime: TimeInterval = 0
    private var audioOffset: Double = 0
    private var accumulatedDuration: TimeInterval = 0
    private var sourceLanguage: Locale.Language { Locale.Language(identifier: selectedDirection.sourceLanguageCode) }
    private var targetLanguage: Locale.Language { Locale.Language(identifier: selectedDirection.targetLanguageCode) }
    var sourceDisplayName: String { selectedDirection.sourceDisplayName }
    var targetDisplayName: String { selectedDirection.targetDisplayName }
    var directionLabel: String { selectedDirection.label }

    var segments: [CaptionSegment] { timeline.segments }
    var displaySegments: [CaptionSegment] {
        markPendingContext(in: timeline.displaySegments)
    }
    func recentDisplaySegments(limit: Int = 100) -> [CaptionSegment] {
        markPendingContext(in: timeline.recentDisplaySegments(limit: limit))
    }
    /// The small caption window keeps individual phrases readable while the
    /// detail view may reconsider a bounded passage as a context group.
    func recentCompactSegments(limit: Int = 2) -> [CaptionSegment] {
        guard limit > 0 else { return [] }
        let count = min(limit, 100)
        var readable: [CaptionSegment] = []
        for segment in timeline.segments.suffix(100).reversed() {
            if segment.translationError != nil ||
                !(segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                readable.append(segment)
                if readable.count == count { break }
            }
        }
        // Pending newer phrases must not evict the last readable translation.
        // Read directly from this timeline, so an empty new conversation cannot
        // retain a previous conversation's caption or its finalized appearance.
        return readable.isEmpty ? Array(timeline.segments.suffix(count)) : Array(readable.reversed())
    }
    var displayHistoryCount: Int { timeline.displaySegmentCount }
    private func markPendingContext(in segments: [CaptionSegment]) -> [CaptionSegment] {
        let pending = contextJobs.filter { timeline.needsContextTranslation($0) } +
            (activeContext.map { timeline.needsContextTranslation($0) ? [$0] : [] } ?? [])
        let pendingIDs = Set(pending.flatMap { $0.members.map(\.segmentID) })
        return segments.map { segment in
            var display = segment
            display.contextIsPending = pendingIDs.contains(segment.id)
            return display
        }
    }
    var hasContent: Bool { !segments.isEmpty }
    var transcriptText: String {
        let text = timeline.exportText(createdAt: sessionCreatedAt,
            sourceLabel: selectedDirection.sourceExportLabel, targetLabel: selectedDirection.targetExportLabel)
        guard !inputWarnings.isEmpty else { return text }
        return text + "\n입력 관련 알림 · 누락 가능성\n" + inputWarnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }
    var canStart: Bool { assetsReady && phase == .idle && !isChecking && !isPreparing && !isPreparingLocalModel && (!polishEnabled || localPolishReady) && !isPreview && !hasPendingTranslations }
    var canChangeSessionSettings: Bool {
        phase == .idle && !isPreparing && !isPreparingLocalModel && !isPreview && !isUISoak && !hasContent && !hasPendingTranslations
    }
    var isBusy: Bool { phase == .starting || phase == .stopping || isPreparing || isPreparingLocalModel }
    var isListening: Bool { phase == .listening }
    var canStop: Bool { phase == .listening || phase == .starting }
    var hasPendingTranslations: Bool { queuedTranslations > 0 || workerTask != nil || polishWorker != nil }
    var statusText: String {
        if isUISoak { return "화면 안정성 검사 · 합성 자막" }
        if isPreview { return "화면 미리보기" }
        if isPreparing { return "처음 한 번 준비 중" }
        if isChecking { return "사용 가능 여부 확인 중" }
        switch phase {
        case .idle: return hasPendingTranslations ? "남은 원문 번역 중" : (assetsReady ? "준비됨" : "언어 모델 준비 필요")
        case .starting: return "시작 중"
        case .listening: return "\(sourceDisplayName)를 듣고 있습니다"
        case .stopping: return "마지막 문장 정리 중"
        }
    }

    init(preview: Bool = false, translationOverride: (@MainActor (String, Bool) async throws -> String)? = nil,
         microphoneAccessOverride: (@MainActor () async -> Bool)? = nil,
         readinessOverride: (@MainActor (CaptionDirection) async throws -> Bool)? = nil,
         preferencesDefaults: UserDefaults = .standard,
         polishOverride: (@MainActor (LocalTranslationRequest) async throws -> String)? = nil,
         polishTimeoutSeconds: Double = 1.8,
         localEngine: LocalTranslationEngine? = nil) {
        self.translationOverride = translationOverride
        self.microphoneAccessOverride = microphoneAccessOverride
        self.readinessOverride = readinessOverride
        self.polishOverride = polishOverride
        self.polishTimeoutSeconds = polishTimeoutSeconds
        self.localEngine = localEngine ?? LocalTranslationEngine()
        self.preferencesDefaults = preferencesDefaults
        storedPolishEnabled = !preview && translationOverride == nil && preferencesDefaults.bool(forKey: "localPolishEnabled")
        storedDirection = preview ? .englishToKorean :
            CaptionDirection(rawValue: preferencesDefaults.string(forKey: CaptionDirection.preferenceKey) ?? "") ?? .englishToKorean
        storedDomain = preview ? .general :
            TranslationDomain(rawValue: preferencesDefaults.string(forKey: TranslationDomain.preferenceKey) ?? "") ?? .general
        selectedDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
        showEnglish = UserDefaults.standard.object(forKey: "showEnglish") as? Bool ?? true
        let savedFontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 35
        fontSize = savedFontSize.isFinite ? min(52, max(24, savedFontSize)) : 35
        contextCorrectionEnabled = UserDefaults.standard.object(forKey: "contextCorrectionEnabled") as? Bool ?? true
        isPreview = preview
        refreshDevices()
        if preview { loadPreview() }
    }

    func refreshDevices() {
        do { devices = try AudioInputDevice.all() }
        catch { message = error.localizedDescription }
    }

    func checkReadiness() async {
        guard !isPreview, !isUISoak else { return }
        let token = UUID()
        let direction = selectedDirection
        readinessID = token
        isChecking = true
        assetsReady = false
        defer { if readinessID == token { isChecking = false } }
        do {
            if let readinessOverride {
                let ready = try await readinessOverride(direction)
                guard readinessIsCurrent(token, direction: direction) else { return }
                assetsReady = ready
                return
            }
            guard SpeechTranscriber.isAvailable else {
                message = "이 Mac에서는 로컬 음성 인식을 사용할 수 없습니다. Apple Silicon과 macOS 26.4 이상이 필요합니다."
                return
            }
            let locale = try await reserveSpeechLocale(for: direction)
            guard readinessIsCurrent(token, direction: direction) else { return }
            let transcriber = makeTranscriber(locale: locale)
            let speechStatus = await AssetInventory.status(forModules: [transcriber])
            guard readinessIsCurrent(token, direction: direction) else { return }
            let translationStatus = await LanguageAvailability(preferredStrategy: .lowLatency)
                .status(from: Locale.Language(identifier: direction.sourceLanguageCode),
                        to: Locale.Language(identifier: direction.targetLanguageCode))
            guard readinessIsCurrent(token, direction: direction) else { return }
            if speechStatus == .unsupported || translationStatus == .unsupported {
                message = "이 Mac에서 \(direction.sourceDisplayName) 음성 인식 또는 \(direction.label) 번역을 지원하지 않습니다."
                return
            }
            assetsReady = speechStatus == .installed && translationStatus == .installed
        } catch {
            guard readinessIsCurrent(token, direction: direction) else { return }
            message = "\(direction.sourceDisplayName) 음성 인식을 준비할 수 없습니다: \(error.localizedDescription)"
        }
    }

    func prepareLocalModel() async {
        guard polishEnabled, !isPreview, !isUISoak, !isPreparingLocalModel else { return }
        if polishOverride != nil { localPolishReady = true; localPolishMessage = "보완 번역 준비됨"; return }
        let token = UUID()
        localPreparationID = token
        isPreparingLocalModel = true
        localPolishMessage = "문맥 다듬기 모델 준비 중"
        defer { if localPreparationID == token { isPreparingLocalModel = false } }
        await LocalModelStore.shared.refresh()
        guard localPreparationID == token, polishEnabled else { return }
        guard let modelURL = LocalModelStore.shared.modelURL else {
            localEngine.unload()
            storedPolishEnabled = false
            preferencesDefaults.set(false, forKey: "localPolishEnabled")
            localPolishMessage = "문맥 다듬기 모델을 다운로드해 주세요."
            return
        }
        do {
            // Loading and the first Metal graph run before microphone capture.
            // No main-thread model loading or first-caption cold initialization.
            try await localEngine.prepare(modelURL: modelURL)
            guard localPreparationID == token, polishEnabled else { return }
            _ = try await localEngine.translate(LocalTranslationRequest(source: "Hello.",
                direction: .englishToKorean), timeoutMilliseconds: 3_000)
            guard localPreparationID == token, polishEnabled else { return }
            localPolishReady = true
            localPolishMessage = "문맥 다듬기 준비됨 · 로컬 실행"
        } catch {
            guard localPreparationID == token else { return }
            localEngine.unload()
            storedPolishEnabled = false
            preferencesDefaults.set(false, forKey: "localPolishEnabled")
            localPolishMessage = error.localizedDescription
        }
    }

    private func readinessIsCurrent(_ token: UUID, direction: CaptionDirection) -> Bool {
        readinessID == token && selectedDirection == direction && !Task.isCancelled
    }

    func requestPreparation() {
        guard !isPreparing && phase == .idle && !isPreview else { return }
        message = nil
        isPreparing = true
        preparationMessage = "\(directionLabel) 번역 모델 준비"
        preparationProgress = nil
        if var configuration = translationConfiguration {
            configuration.invalidate()
            translationConfiguration = configuration
        } else {
            translationConfiguration = .init(source: sourceLanguage, target: targetLanguage,
                                             preferredStrategy: .lowLatency)
        }
    }

    func prepareModels(using session: TranslationSession) async {
        guard isPreparing, session.sourceLanguage == sourceLanguage, session.targetLanguage == targetLanguage else { return }
        defer { isPreparing = false; preparationProgress = nil }
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            preparationMessage = "\(sourceDisplayName) 음성 인식 모델 다운로드"
            let locale = try await reserveSpeechLocale(for: selectedDirection)
            let transcriber = makeTranscriber(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.preparationProgress = request.progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { progressTask.cancel() }
                try await request.downloadAndInstall()
            }
            await checkReadiness()
            if !assetsReady { throw CaptionError.message("언어 모델 준비를 완료하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.") }
            preparationMessage = "준비 완료"
        } catch {
            message = "언어 모델 준비 실패: \(error.localizedDescription)"
        }
    }

    func start() async {
        guard canStart else { return }
        phase = .starting
        message = nil
        let token = UUID()
        runID = token
        runHasAudio = false
        timeline.resetContext()
        contextTimedOut = false
        localPolishDegraded = false
        finalFastBaselines.removeAll()
        draftHeldSince = nil
        lastAcceptedSourceUptime = 0
        let requestedDeviceUID = selectedDeviceUID
        refreshDevices()
        do {
            guard requestedDeviceUID.isEmpty || devices.contains(where: { $0.uid == requestedDeviceUID }) else {
                throw CaptionError.message("선택한 마이크가 연결되지 않았습니다. 다시 연결하거나 입력 장치를 직접 선택해 주세요.")
            }
            let allowed: Bool
            if let microphoneAccessOverride { allowed = await microphoneAccessOverride() }
            else { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
            try checkStarting(token)
            guard allowed else {
                throw CaptionError.message("마이크 접근이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 이 앱을 허용해 주세요.")
            }
            let locale = try await reserveSpeechLocale(for: selectedDirection)
            try checkStarting(token)
            let transcriber = makeTranscriber(locale: locale)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CaptionError.message("음성 인식에 사용할 음성 형식을 찾지 못했습니다.")
            }
            try checkStarting(token)
            let session = TranslationSessionLease(installedSource: sourceLanguage, target: targetLanguage,
                                             preferredStrategy: .lowLatency)
            translationSession = session
            try await OperationDeadline.run(seconds: 15, name: "번역 모델 준비", onTimeout: { session.retire() }) {
                try await session.prepareTranslation()
            }
            try checkStarting(token)
            let recognizer = SpeechAnalyzer(modules: [transcriber],
                                            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
            analyzer = recognizer
            try await OperationDeadline.run(seconds: 15, name: "음성 인식 준비", onTimeout: {
                Task { await recognizer.cancelAndFinishNow() }
            }) { try await recognizer.prepareToAnalyze(in: format) }
            try checkStarting(token)
            // Include previously recorded silence as well as recognized speech.
            // A pause/resume must not move new captions back to an earlier time.
            audioOffset = max(accumulatedDuration, timeline.endTime)
            runUptime = ProcessInfo.processInfo.systemUptime
            startedAt = Date()
            runHasAudio = true
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.runID == token else { break }
                        self.receive(result)
                    }
                    guard let self, self.runID == token, self.phase == .listening else { return }
                    self.message = "음성 인식 결과가 예상보다 일찍 끝났습니다. 다시 시작해 주세요."
                    Task { await self.stop(aborting: true) }
                } catch {
                    guard let self, self.runID == token,
                          self.phase == .listening || self.phase == .starting else { return }
                    self.message = "음성 인식이 중단됐습니다: \(error.localizedDescription)"
                    // Do not await stop from the result task that stop itself drains.
                    Task { await self.stop(aborting: true) }
                }
            }
            let audioCapture = AudioCapture()
            capture = audioCapture
            let deviceID = devices.first(where: { $0.uid == selectedDeviceUID })?.id
            let stream = try audioCapture.start(deviceID: deviceID, target: format,
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard self?.runID == token else { return }
                        self?.audioLevel = level
                    }
                }, onProblem: { [weak self] problem in
                    Task { @MainActor in
                        guard let self, self.runID == token,
                              self.phase != .idle else { return }
                        await self.receiveAudioProblem(problem)
                    }
                })
            // Analyze the live stream in its own task. Do not await a streaming
            // analysis operation before allowing the user to stop the stream.
            analysisTask = Task { [weak self] in
                do {
                    if let end = try await recognizer.analyzeSequence(stream) {
                        try await recognizer.finalizeAndFinish(through: end)
                    } else { await recognizer.cancelAndFinishNow() }
                    guard let self, self.runID == token, self.phase == .listening else { return }
                    self.message = "마이크 입력이 예상보다 일찍 끝났습니다. 입력 장치를 확인한 뒤 다시 시작해 주세요."
                    Task { await self.stop(aborting: true) }
                } catch {
                    guard let self, self.runID == token,
                          self.phase == .listening || self.phase == .starting else { return }
                    self.message = "음성 분석을 계속할 수 없습니다: \(error.localizedDescription)"
                    Task { await self.stop(aborting: true) }
                }
            }
            phase = .listening
            scheduleWorker()
        } catch {
            // A canceled startup may finish after a new run has already begun.
            guard runID == token else { return }
            message = error.localizedDescription
            await stop(aborting: true)
        }
    }

    private func checkStarting(_ token: UUID) throws {
        try Task.checkCancellation()
        guard runID == token, phase == .starting else { throw CancellationError() }
    }

    func receiveAudioProblem(_ problem: String) async {
        guard phase != .idle else { return }
        message = problem
        if !inputWarnings.contains(problem) { inputWarnings.append(problem) }
        if canStop { await stop(aborting: true) }
    }

    func stop(aborting: Bool = false) async {
        guard phase == .listening || phase == .starting else { return }
        let token = runID
        phase = .stopping
        if runHasAudio {
            accumulatedDuration = max(accumulatedDuration, audioOffset + max(0, ProcessInfo.processInfo.systemUptime - runUptime))
            runHasAudio = false
        }
        let closingCapture = capture
        let closingAnalyzer = analyzer
        let closingAnalysis = analysisTask
        let closingResults = resultTask
        if aborting {
            // Input failure is not a request to finalize a recording. Invalidate
            // all producers before releasing controls; waiting for canceled
            // framework tasks made the Start button unavailable for eight seconds.
            runID = nil
            analysisTask?.cancel()
            resultTask?.cancel()
            workerID = nil
            workerTask?.cancel()
            translationTask?.cancel()
            contextTask?.cancel()
            translationSession?.retire()
            contextSession?.retire()
            if let closingAnalyzer { Task { await closingAnalyzer.cancelAndFinishNow() } }
            do {
                try await OperationDeadline.run(seconds: 0.8, name: "마이크 정지") {
                    await closingCapture?.stop()
                }
            } catch { }
            capture = nil
            finishRun()
            return
        }
        do {
            try await OperationDeadline.run(seconds: 8, name: "마지막 문장 정리", onTimeout: {
                if let closingAnalyzer { Task { await closingAnalyzer.cancelAndFinishNow() } }
            }) {
                await closingCapture?.stop()
                guard self.runID == token, self.phase == .stopping else { throw CancellationError() }
                self.capture = nil
                await closingAnalysis?.value
                await closingResults?.value
                guard self.runID == token, self.phase == .stopping else { throw CancellationError() }
                self.analysisTask = nil; self.resultTask = nil; self.analyzer = nil
                // ASR-final jobs drain within the same overall stop deadline.
                self.scheduleWorker()
                await self.workerTask?.value
                // Refinement finalizes on its own lane and can admit one last
                // context group to the worker.
                await self.polishWorker?.value
                self.scheduleWorker()
                await self.workerTask?.value
            }
        } catch {
            guard runID == token, phase == .stopping else { return }
            message = "마지막 문장 정리 시간이 초과됐습니다. 미완료 원문은 보존했습니다. 다시 번역하거나 새로 시작해 주세요."
        }
        guard runID == token, phase == .stopping else { return }
        finishRun()
    }

    private func finishRun() {
        settlePolishWithBaselines()
        finalFastBaselines.removeAll()
        analysisTask?.cancel(); analysisTask = nil
        resultTask?.cancel(); resultTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        workerID = nil
        workerTask?.cancel(); workerTask = nil
        translationTask?.cancel(); translationTask = nil; activeTranslation = nil
        translationSession?.retire(); translationSession = nil
        contextSession?.retire(); contextSession = nil
        contextTask?.cancel(); contextTask = nil
        activeContext = nil
        contextJobs.removeAll()
        runID = nil
        for segment in segments where segment.translatedRevision != segment.revision {
            timeline.fail(TranslationJob(segmentID: segment.id, revision: segment.revision,
                source: segment.source, isSourceFinal: segment.sourceIsFinal),
                message: "이 구절의 번역이 완료되지 않았습니다. 다시 번역할 수 있습니다.")
        }
        translationQueue.removeAll()
        draftHeldSince = nil
        queuedTranslations = 0
        audioLevel = 0
        phase = .idle
    }

    func newSession() {
        guard phase == .idle && !isPreparing else { return }
        workerID = nil
        workerTask?.cancel(); workerTask = nil
        translationTask?.cancel(); translationTask = nil; activeTranslation = nil
        translationSession?.retire(); translationSession = nil
        contextSession?.retire(); contextSession = nil
        contextTask?.cancel(); contextTask = nil
        activeContext = nil
        polishLaneID = nil
        polishWorker?.cancel(); polishWorker = nil
        polishTask?.cancel(); polishTask = nil
        localEngine.cancelActive()
        activePolish = nil
        polishWaiting.removeAll()
        finalFastBaselines.removeAll()
        localPolishDegraded = false
        localPolishMilliseconds = nil
        contextJobs.removeAll()
        timeline = CaptionTimeline()
        inputWarnings.removeAll()
        translationQueue.removeAll(); queuedTranslations = 0
        draftHeldSince = nil
        lastAcceptedSourceUptime = 0
        translationMilliseconds = nil; speechDelaySeconds = nil; captionDelaySeconds = nil
        accumulatedDuration = 0
        startedAt = Date()
        sessionCreatedAt = startedAt
        message = nil
    }

    func elapsed(at date: Date) -> String {
        let seconds = Int(runHasAudio ? max(accumulatedDuration, audioOffset + max(0, ProcessInfo.processInfo.systemUptime - runUptime)) : accumulatedDuration)
        return String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    @discardableResult
    func exportTranscript() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "자막-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.title = "\(sourceDisplayName) 원문과 \(targetDisplayName) 자막 저장"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try transcriptText.write(to: url, atomically: true, encoding: .utf8)
                return true
            }
            catch { message = "기록을 저장하지 못했습니다: \(error.localizedDescription)" }
        }
        return false
    }

    func retryFailedTranslations() {
        guard !isPreview, phase == .idle || phase == .listening else { return }
        guard let _ = translationSession else {
            translationSession = TranslationSessionLease(installedSource: sourceLanguage, target: targetLanguage,
                                                    preferredStrategy: .lowLatency)
            enqueueFailedTranslations()
            return
        }
        enqueueFailedTranslations()
    }

    private func enqueueFailedTranslations() {
        for segment in segments where segment.translationError != nil {
            enqueue(TranslationJob(segmentID: segment.id, revision: segment.revision,
                                   source: segment.source, isSourceFinal: segment.sourceIsFinal))
        }
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    private func reserveSpeechLocale(for direction: CaptionDirection) async throws -> Locale {
        let requested = Locale(identifier: direction.speechLocaleIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw CaptionError.message("이 Mac에서 \(direction.sourceDisplayName) 로컬 음성 인식을 지원하지 않습니다.")
        }
        // Reserve the exact supported locale. Keep this app's downloaded English
        // and Korean subscriptions across sessions for offline direction changes.
        // Active model retention is independently scoped to whileInUse.
        try await AssetInventory.reserve(locale: locale)
        return locale
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        guard start.isFinite, end.isFinite else { return }
        speechDelaySeconds = max(0, ProcessInfo.processInfo.systemUptime - runUptime - end)
        receive(source: String(result.text.characters), audioStart: start + audioOffset,
            audioEnd: end + audioOffset, isFinal: result.isFinal)
    }

    /// The same production state/scheduler path is exercised by the deterministic
    /// integration checks, with an injected translator and no microphone access.
    func receive(source: String, audioStart: Double, audioEnd: Double, isFinal: Bool) {
        let previousTail = segments.last
        let previousCount = segments.count
        let reusable = isFinal && shouldPolish ? segments.suffix(6).filter {
            !$0.sourceIsFinal && $0.translatedRevision == $0.revision && $0.translation != nil
        } : []
        let acceptedJob = timeline.accept(source: source, audioStart: audioStart, audioEnd: audioEnd, isFinal: isFinal,
                                         requireFinalTranslation: shouldPolish)
        let sourceChanged = acceptedJob != nil || segments.count != previousCount || segments.last != previousTail
        if sourceChanged { lastAcceptedSourceUptime = ProcessInfo.processInfo.systemUptime }
        if let job = acceptedJob {
            if let previous = reusable.first(where: { $0.id == job.segmentID && $0.revision == job.revision && $0.source == job.source }),
               let translation = previous.translation {
                finalFastBaselines[job.segmentID] = (job.revision, translation)
            }
            enqueue(job)
        }
        if isFinal {
            if let activeContext, !timeline.needsContextTranslation(activeContext) {
                contextSession?.retire()
                contextTask?.cancel()
            }
        }
        if sourceChanged || isFinal { enqueueContextIfAvailable() }
    }

    private func enqueueContextIfAvailable() {
        // A following live draft takes priority over reconsidering older text.
        // Do not requeue that optional group after each draft translation.
        guard let last = segments.last, last.sourceIsFinal else {
            contextJobs.removeAll()
            queuedTranslations = translationQueue.count
            return
        }
        guard contextCorrectionEnabled, !contextTimedOut,
              let job = timeline.contextJob(endingAt: last.id) else { return }
        contextJobs.removeAll { !timeline.needsContextTranslation($0) || $0.endingSegmentID == job.endingSegmentID }
        if !contextJobs.contains(job) { contextJobs.append(job) }
        queuedTranslations = translationQueue.count + contextJobs.count
        scheduleWorker()
    }

    private func enqueue(_ job: TranslationJob) {
        if job.isSourceFinal, let activeTranslation, !activeTranslation.isSourceFinal,
           activeTranslation.segmentID != job.segmentID || activeTranslation.revision != job.revision {
            if timeline.needsTranslation(activeTranslation) { translationQueue.enqueue(activeTranslation) }
            translationTask?.cancel()
            translationSession?.retire()
            if translationOverride == nil {
                translationSession = TranslationSessionLease(installedSource: sourceLanguage,
                    target: targetLanguage, preferredStrategy: .lowLatency)
            }
        }
        if activeContext != nil {
            contextSession?.retire(); contextTask?.cancel()
        }
        translationQueue.prune(using: timeline)
        if job.isSourceFinal && translationQueue.finalCount >= 12 && isListening {
            timeline.fail(job, message: "번역 대기가 한도를 넘었습니다. 원문은 보존했습니다.")
            message = "번역이 입력 속도를 따라가지 못해 자막 입력을 멈춥니다. 남은 원문은 다시 번역할 수 있습니다."
            Task { await self.stop() }
            return
        }
        translationQueue.enqueue(job)
        queuedTranslations = translationQueue.count + contextJobs.count
        scheduleWorker()
    }

    private func scheduleWorker() {
        guard workerTask == nil, translationSession != nil || translationOverride != nil else { return }
        let token = UUID()
        workerID = token
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.drainTranslations(token: token)
            guard self.workerID == token else { return }
            self.workerTask = nil
            self.workerID = nil
            if self.phase == .idle {
                self.translationSession?.retire(); self.translationSession = nil
                self.contextSession?.retire(); self.contextSession = nil
            }
        }
    }

    private func drainTranslations(token: UUID) async {
        while !Task.isCancelled, workerID == token {
            let session = translationSession
            guard session != nil || translationOverride != nil else { break }
            translationQueue.prune(using: timeline)
            contextJobs.removeAll { !timeline.needsContextTranslation($0) }
            if translationQueue.count == translationQueue.finalCount {
                draftHeldSince = nil
            } else if !translationQueue.hasFinals {
                let now = ProcessInfo.processInfo.systemUptime
                let heldSince = draftHeldSince ?? now
                draftHeldSince = heldSince
                // Admit the burst's newest revision once the source goes quiet.
                // A final arriving meanwhile is taken first on the next pass.
                let wait = min(Self.draftSettleSeconds - (now - lastAcceptedSourceUptime),
                               Self.draftHoldLimitSeconds - (now - heldSince))
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    continue // A newer revision or a final may have arrived while sleeping.
                }
            }
            guard let job = translationQueue.next(allowDraft: true) else {
                if let contextJob = contextJobs.first, !contextTimedOut, contextCorrectionEnabled {
                    guard segments.last?.sourceIsFinal == true else {
                        contextJobs.removeAll()
                        continue
                    }
                    let quietWait = 0.75 - (ProcessInfo.processInfo.systemUptime - lastAcceptedSourceUptime)
                    if quietWait > 0 {
                        do { try await Task.sleep(for: .seconds(min(quietWait, 0.05))) } catch { return }
                        continue
                    }
                    let useLocal = shouldPolish
                    if useLocal, activePolish != nil || !polishWaiting.isEmpty {
                        // The local engine runs one request at a time.
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                        continue
                    }
                    contextJobs.removeFirst()
                    activeContext = contextJob
                    let contextSession = useLocal ? nil : TranslationSessionLease(installedSource: sourceLanguage,
                        target: targetLanguage, preferredStrategy: .highFidelity)
                    self.contextSession = contextSession
                    queuedTranslations = contextJobs.count
                    do {
                        let override = translationOverride
                        let baseline = contextJob.members.compactMap { member in
                            segments.first(where: { $0.id == member.segmentID && $0.revision == member.revision })?.translation
                        }.joined(separator: " ")
                        let request = LocalTranslationRequest(source: contextJob.source, baseline: baseline,
                            direction: selectedDirection, domain: translationDomain)
                        let engine = localEngine
                        let polisher = polishOverride
                        let task = Task {
                            try await OperationDeadline.run(seconds: useLocal ? self.polishTimeoutSeconds : 4, name: "문맥 보정",
                                onTimeout: { contextSession?.retire(); if useLocal { engine.cancelActive() } }) {
                                if useLocal {
                                    let text: String
                                    if let polisher { text = try await polisher(request) }
                                    else { text = try await engine.translate(request).text }
                                    guard request.accepts(text) else { throw LocalTranslationError.unsafeOutput }
                                    return text
                                }
                                if let override { return try await override(contextJob.source, true) }
                                guard let contextSession else { throw LocalTranslationError.notPrepared }
                                return try await contextSession.translate(contextJob.source)
                            }
                        }
                        contextTask = task
                        let translation = try await task.value
                        guard workerID == token, !Task.isCancelled else { return }
                        if contextCorrectionEnabled { timeline.applyContext(translation: translation, for: contextJob) }
                    } catch {
                        guard workerID == token, !Task.isCancelled else { return }
                        // Context is optional: retain the already translated exact
                        // source revisions and prioritize subsequent live speech.
                        let localTimeout: Bool
                        if case LocalTranslationError.native(2, _) = error { localTimeout = true }
                        else { localTimeout = false }
                        if localTimeout || error is OperationDeadline.Expired || error is TranslationSessionLease.CapacityReached {
                            contextTimedOut = true
                            contextJobs.removeAll()
                            message = "문맥 보정이 지연돼 이번 실행에서는 문장별 번역을 유지합니다. 다시 시작하면 문맥 보정을 다시 시도합니다."
                        }
                    }
                    activeContext = nil
                    contextTask = nil
                    self.contextSession?.retire(); self.contextSession = nil
                    continue
                }
                break
            }
            if !job.isSourceFinal { draftHeldSince = nil }
            queuedTranslations = translationQueue.count + contextJobs.count
            // A sentence already handed to refinement keeps its gray baseline
            // until that lane finalizes it. Do not translate it again.
            guard timeline.needsTranslation(job), !polishOwns(job) else { continue }
            let began = ProcessInfo.processInfo.systemUptime
            activeTranslation = job
            do {
                let override = translationOverride
                let cached = finalFastBaselines.removeValue(forKey: job.segmentID)
                let task = Task {
                    try await OperationDeadline.run(seconds: 6, name: "자막 번역", onTimeout: { session?.retire() }) {
                        if let cached, cached.revision == job.revision { return cached.translation }
                        if let override { return try await override(job.source, false) }
                        guard let session else { throw CancellationError() }
                        return try await session.translate(job.source)
                    }
                }
                translationTask = task
                let translation = try await task.value
                guard !Task.isCancelled, workerID == token else { return }
                guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CaptionError.message("번역 결과가 비어 있습니다.")
                }
                // Refinement never holds this worker. An admitted sentence shows
                // its baseline in gray and the refinement lane finalizes it.
                let refining = admitPolish(baseline: translation, for: job)
                if refining || timeline.apply(translation: translation, for: job) {
                    if message == "일부 자막을 번역하지 못했습니다. 다시 번역하거나 원문을 확인해 주세요.",
                       !segments.contains(where: { $0.translationError != nil }) { message = nil }
                    translationMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    if runHasAudio, let segment = segments.first(where: { $0.id == job.segmentID }) {
                        captionDelaySeconds = max(0, ProcessInfo.processInfo.systemUptime - runUptime - (segment.audioEnd - audioOffset))
                    }
                    if !refining { enqueueContextIfAvailable() }
                }
            } catch {
                guard !Task.isCancelled, workerID == token else { return }
                if error is CancellationError, translationTask?.isCancelled == true {
                    activeTranslation = nil; translationTask = nil
                    continue // A newer final source preempted provisional work.
                }
                if timeline.needsTranslation(job) {
                    timeline.fail(job, message: error.localizedDescription)
                    message = "일부 자막을 번역하지 못했습니다. 다시 번역하거나 원문을 확인해 주세요."
                }
                if error is OperationDeadline.Expired || error is TranslationSessionLease.CapacityReached {
                        // Retired native work stays counted across runs. Stop
                        // admission if the physical-work cap is exhausted.
                        if isListening {
                            message = error is TranslationSessionLease.CapacityReached
                                ? "이전 번역 작업이 아직 정리되지 않아 입력을 멈춥니다. 원문을 저장하고 잠시 후 다시 시도해 주세요. 계속되면 앱을 다시 열어 주세요."
                                : "번역 응답이 지연돼 입력을 멈춥니다. 미완료 원문은 보존했습니다. 다시 번역하거나 새로 시작해 주세요."
                            Task { await self.stop(aborting: true) }
                        }
                        settlePolishWithBaselines()
                        for segment in segments where segment.translatedRevision != segment.revision {
                            timeline.fail(TranslationJob(segmentID: segment.id, revision: segment.revision,
                                source: segment.source, isSourceFinal: segment.sourceIsFinal),
                                message: "번역이 시간 안에 완료되지 않았습니다. 다시 번역할 수 있습니다.")
                        }
                        translationQueue.removeAll()
                        contextJobs.removeAll()
                        activeTranslation = nil; translationTask = nil
                        break
                }
            }
            activeTranslation = nil; translationTask = nil
        }
        queuedTranslations = 0
    }

    private var shouldPolish: Bool { polishEnabled && !localPolishDegraded && !isPreview && !isUISoak }

    private func polishOwns(_ job: TranslationJob) -> Bool {
        ((activePolish.map { [$0] } ?? []) + polishWaiting).contains {
            $0.job.segmentID == job.segmentID && $0.job.revision == job.revision
        }
    }

    /// Shows the fast baseline as a gray preview and hands the exact final
    /// revision to the refinement lane. Returns false when the baseline itself
    /// should finalize the caption.
    private func admitPolish(baseline: String, for job: TranslationJob) -> Bool {
        guard shouldPolish, timeline.isCurrent(job),
              let segment = segments.first(where: { $0.id == job.segmentID }), segment.sourceIsFinal else { return false }
        let finalJob = TranslationJob(segmentID: job.segmentID, revision: job.revision,
            source: job.source, isSourceFinal: true)
        let request = LocalTranslationRequest(source: job.source, baseline: baseline,
            direction: selectedDirection, domain: translationDomain)
        guard request.isWithinBudget, timeline.preview(translation: baseline, for: finalJob) else { return false }
        polishWaiting.append(PolishItem(job: finalJob, baseline: baseline))
        while polishWaiting.count > Self.polishWaitingLimit {
            // The newest sentences are the ones being read. An older sentence
            // the model never reached keeps its fast translation.
            let skipped = polishWaiting.removeFirst()
            timeline.apply(translation: skipped.baseline, for: skipped.job)
            localPolishMessage = "새 문장을 우선해 빠른 번역을 유지했습니다."
        }
        schedulePolish()
        return true
    }

    private func schedulePolish() {
        guard polishWorker == nil, !polishWaiting.isEmpty else { return }
        let token = UUID()
        polishLaneID = token
        polishWorker = Task { [weak self] in
            guard let self else { return }
            await self.drainPolish(lane: token)
            guard self.polishLaneID == token else { return }
            self.polishWorker = nil
            self.polishLaneID = nil
        }
    }

    private func drainPolish(lane token: UUID) async {
        while polishLaneID == token, !Task.isCancelled, !polishWaiting.isEmpty {
            if activeContext != nil, shouldPolish {
                // A context group using the single local engine was preempted
                // by this sentence's source. Wait for it to release the engine.
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                continue
            }
            let item = polishWaiting.removeFirst()
            var refined: String?
            if shouldPolish, timeline.needsTranslation(item.job) {
                activePolish = item
                refined = await refine(item, lane: token)
                guard polishLaneID == token, !Task.isCancelled else { return }
                activePolish = nil
            }
            if timeline.apply(translation: refined ?? item.baseline, for: item.job) { enqueueContextIfAvailable() }
        }
    }

    /// Returns the validated local wording, or nil to keep the fast baseline.
    private func refine(_ item: PolishItem, lane token: UUID) async -> String? {
        // Separate background prompts leaked earlier sentences in actual QA.
        // Adjacent context is translated only as an explicit bounded group by
        // the existing context lane, preserving all member source records.
        let request = LocalTranslationRequest(source: item.job.source, baseline: item.baseline,
            direction: selectedDirection, domain: translationDomain)
        let engine = localEngine
        let polisher = polishOverride
        let started = ProcessInfo.processInfo.systemUptime
        // A just-preempted context request can still hold the engine briefly.
        for attempt in 0..<3 {
            let task = Task {
                try await OperationDeadline.run(seconds: self.polishTimeoutSeconds, name: "문맥 다듬기",
                    onTimeout: { engine.cancelActive() }) {
                    if let polisher { return try await polisher(request) }
                    return try await engine.translate(request).text
                }
            }
            polishTask = task
            do {
                let text = try await task.value
                guard polishLaneID == token, !Task.isCancelled, timeline.isCurrent(item.job) else { return nil }
                polishTask = nil
                guard request.accepts(text) else {
                    localPolishMessage = "이번 구절은 빠른 번역을 유지했습니다."
                    return nil
                }
                localPolishMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                localPolishMessage = "문맥 다듬기 사용 중 · \(translationDomain.label)"
                return text
            } catch {
                guard polishLaneID == token, !Task.isCancelled else { return nil }
                polishTask = nil
                if case LocalTranslationError.busy = error {
                    if attempt < 2, (try? await Task.sleep(for: .milliseconds(30))) != nil,
                       polishLaneID == token { continue }
                    localPolishMessage = "이번 구절은 빠른 번역을 유지했습니다."
                } else if case LocalTranslationError.unsafeOutput = error {
                    localPolishMessage = "이번 구절은 빠른 번역을 유지했습니다."
                } else if !(error is CancellationError) {
                    localPolishDegraded = true
                    localEngine.cancelActive()
                    localPolishMessage = "보완이 지연되거나 실패해 이번 실행은 빠른 번역을 유지합니다."
                    message = localPolishMessage
                }
                return nil
            }
        }
        return nil
    }

    /// Ends the refinement lane and finalizes each still-current sentence with
    /// the fast baseline it already displays. Late local output is ignored.
    private func settlePolishWithBaselines() {
        polishLaneID = nil
        polishWorker?.cancel(); polishWorker = nil
        polishTask?.cancel(); polishTask = nil
        localEngine.cancelActive()
        let items = (activePolish.map { [$0] } ?? []) + polishWaiting
        activePolish = nil
        polishWaiting.removeAll()
        for item in items where timeline.needsTranslation(item.job) {
            timeline.apply(translation: item.baseline, for: item.job)
        }
    }

    private func loadPreview() {
        isChecking = false; assetsReady = true
        let first = timeline.accept(source: "Thanks for joining us today. Let's talk about what comes next.",
                                    audioStart: 0, audioEnd: 6, isFinal: true)!
        timeline.apply(translation: "오늘 함께해 주셔서 감사합니다. 앞으로의 계획을 이야기해 보겠습니다.", for: first)
        let second = timeline.accept(source: "The most important thing is making sure everyone can follow the conversation.",
                                     audioStart: 6, audioEnd: 12, isFinal: true)!
        timeline.apply(translation: "가장 중요한 것은 모두가 대화의 흐름을 따라갈 수 있도록 하는 것입니다.", for: second)
        let draft = timeline.accept(source: "So when we share an idea, we want to give people enough time to", audioStart: 12,
                                    audioEnd: 17, isFinal: false)!
        timeline.apply(translation: "그래서 의견을 나눌 때는 사람들이 충분히 이해할 수 있도록…", for: draft)
    }
}
