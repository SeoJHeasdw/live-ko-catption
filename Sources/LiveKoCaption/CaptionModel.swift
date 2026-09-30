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
    var isPreview = false
    var isChecking = true
    var isPreparing = false
    var assetsReady = false
    var preparationMessage = ""
    var preparationProgress: Double?
    var message: String?
    var audioLevel: Double = 0
    var translationMilliseconds: Double?
    var speechDelaySeconds: Double?
    var startedAt = Date()
    private var sessionCreatedAt = Date()
    var translationConfiguration: TranslationSession.Configuration?
    private(set) var timeline = CaptionTimeline()
    private(set) var queuedTranslations = 0
    private var capture: AudioCapture?
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var translationSession: TranslationSession?
    private var draftJobs: [UUID: TranslationJob] = [:]
    private var finalJobs: [TranslationJob] = []
    private var lastDraftTranslation: TimeInterval = 0
    private var runID: UUID?
    private var runUptime: TimeInterval = 0
    private var audioOffset: Double = 0
    private var accumulatedDuration: TimeInterval = 0
    private let speechLocale = Locale(identifier: "en-US")
    private let sourceLanguage = Locale.Language(identifier: "en")
    private let targetLanguage = Locale.Language(identifier: "ko")

    var segments: [CaptionSegment] { timeline.segments }
    var hasContent: Bool { !segments.isEmpty }
    var canStart: Bool { assetsReady && phase == .idle && !isPreparing && !isPreview }
    var isBusy: Bool { phase == .starting || phase == .stopping || isPreparing }
    var isListening: Bool { phase == .listening }
    var statusText: String {
        if isPreview { return "화면 미리보기" }
        if isPreparing { return "처음 한 번 준비 중" }
        if isChecking { return "사용 가능 여부 확인 중" }
        switch phase {
        case .idle: return assetsReady ? "준비됨" : "언어 모델 준비 필요"
        case .starting: return "시작 중"
        case .listening: return "영어를 듣고 있습니다"
        case .stopping: return "마지막 문장 정리 중"
        }
    }

    init(preview: Bool = false) {
        selectedDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
        showEnglish = UserDefaults.standard.object(forKey: "showEnglish") as? Bool ?? true
        fontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 35
        isPreview = preview
        refreshDevices()
        if preview { loadPreview() }
    }

    func refreshDevices() {
        do { devices = try AudioInputDevice.all() }
        catch { message = error.localizedDescription }
        if !selectedDeviceUID.isEmpty && !devices.contains(where: { $0.uid == selectedDeviceUID }) {
            selectedDeviceUID = ""
        }
    }

    func checkReadiness() async {
        guard !isPreview else { return }
        isChecking = true
        defer { isChecking = false }
        guard SpeechTranscriber.isAvailable else {
            message = "이 Mac에서는 로컬 음성 인식을 사용할 수 없습니다. Apple Silicon과 macOS 26.4 이상이 필요합니다."
            return
        }
        let transcriber = makeTranscriber()
        do { try await reserveSpeechLocale() }
        catch { message = "영어 음성 인식을 준비할 수 없습니다: \(error.localizedDescription)"; return }
        let speechStatus = await AssetInventory.status(forModules: [transcriber])
        let translationStatus = await LanguageAvailability(preferredStrategy: .lowLatency)
            .status(from: sourceLanguage, to: targetLanguage)
        if speechStatus == .unsupported || translationStatus == .unsupported {
            message = "이 Mac에서 영어 음성 인식 또는 영어→한국어 번역을 지원하지 않습니다."
            return
        }
        assetsReady = speechStatus == .installed && translationStatus == .installed
    }

    func requestPreparation() {
        guard !isPreparing && phase == .idle && !isPreview else { return }
        message = nil
        isPreparing = true
        preparationMessage = "영어·한국어 번역 모델 준비"
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
        guard isPreparing else { return }
        defer { isPreparing = false; preparationProgress = nil }
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            preparationMessage = "영어 음성 인식 모델 다운로드"
            let transcriber = makeTranscriber()
            try await reserveSpeechLocale()
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
        let requestedDeviceUID = selectedDeviceUID
        refreshDevices()
        do {
            guard requestedDeviceUID.isEmpty || devices.contains(where: { $0.uid == requestedDeviceUID }) else {
                throw CaptionError.message("선택한 마이크가 연결되지 않았습니다. 다시 연결하거나 입력 장치를 직접 선택해 주세요.")
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else {
                throw CaptionError.message("마이크 접근이 필요합니다. 시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 이 앱을 허용해 주세요.")
            }
            try await reserveSpeechLocale()
            let transcriber = makeTranscriber()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CaptionError.message("음성 인식에 사용할 음성 형식을 찾지 못했습니다.")
            }
            let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage,
                                             preferredStrategy: .lowLatency)
            try await session.prepareTranslation()
            translationSession = session
            let recognizer = SpeechAnalyzer(modules: [transcriber],
                                            options: .init(priority: .userInitiated, modelRetention: .whileInUse))
            analyzer = recognizer
            try await recognizer.prepareToAnalyze(in: format)
            let token = UUID()
            runID = token
            // Include previously recorded silence as well as recognized speech.
            // A pause/resume must not move new captions back to an earlier time.
            audioOffset = max(accumulatedDuration, timeline.endTime)
            runUptime = ProcessInfo.processInfo.systemUptime
            startedAt = Date()
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.runID == token else { break }
                        self.receive(result)
                    }
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
                              self.phase == .listening || self.phase == .starting else { return }
                        self.message = problem
                        await self.stop(aborting: true)
                    }
                })
            // Analyze the live stream in its own task. Do not await a streaming
            // analysis operation before allowing the user to stop the stream.
            analysisTask = Task { [weak self] in
                do {
                    if let end = try await recognizer.analyzeSequence(stream) {
                        try await recognizer.finalizeAndFinish(through: end)
                    } else { await recognizer.cancelAndFinishNow() }
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
            message = error.localizedDescription
            await capture?.stop()
            capture = nil
            await analyzer?.cancelAndFinishNow()
            analysisTask?.cancel()
            analysisTask = nil
            analyzer = nil
            resultTask?.cancel()
            resultTask = nil
            runID = nil
            translationSession = nil
            phase = .idle
        }
    }

    func stop(aborting: Bool = false) async {
        guard phase == .listening || phase == .starting else { return }
        phase = .stopping
        accumulatedDuration += Date().timeIntervalSince(startedAt)
        await capture?.stop()
        capture = nil
        if aborting {
            analysisTask?.cancel()
            resultTask?.cancel()
            await analyzer?.cancelAndFinishNow()
        }
        await analysisTask?.value
        analysisTask = nil
        await resultTask?.value
        resultTask = nil
        analyzer = nil
        // The worker drains ASR-final jobs before ending this recording.
        scheduleWorker()
        await workerTask?.value
        workerTask = nil
        translationSession = nil
        runID = nil
        audioLevel = 0
        phase = .idle
    }

    func newSession() {
        guard phase == .idle && !isPreparing else { return }
        timeline = CaptionTimeline()
        finalJobs.removeAll(); draftJobs.removeAll()
        translationMilliseconds = nil; speechDelaySeconds = nil
        accumulatedDuration = 0
        startedAt = Date()
        sessionCreatedAt = startedAt
        message = nil
    }

    func elapsed(at date: Date) -> String {
        let seconds = Int(accumulatedDuration + (phase == .listening ? date.timeIntervalSince(startedAt) : 0))
        return String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    @discardableResult
    func exportTranscript() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "한글자막-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.title = "영어 원문과 한국어 자막 저장"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try timeline.exportText(createdAt: sessionCreatedAt).write(to: url, atomically: true, encoding: .utf8)
                return true
            }
            catch { message = "기록을 저장하지 못했습니다: \(error.localizedDescription)" }
        }
        return false
    }

    func retryFailedTranslations() {
        guard let _ = translationSession else {
            translationSession = TranslationSession(installedSource: sourceLanguage, target: targetLanguage,
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

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: speechLocale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    private func reserveSpeechLocale() async throws {
        // Reservations belong to this app. Keep its single English subscription
        // across sessions so offline assets are not unsubscribed after every pause.
        // Model retention while running is independently scoped to whileInUse.
        try await AssetInventory.reserve(locale: speechLocale)
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        guard start.isFinite, end.isFinite else { return }
        speechDelaySeconds = max(0, ProcessInfo.processInfo.systemUptime - runUptime - end)
        if let job = timeline.accept(source: String(result.text.characters),
                                     audioStart: start + audioOffset,
                                     audioEnd: end + audioOffset, isFinal: result.isFinal) {
            enqueue(job)
        }
    }

    private func enqueue(_ job: TranslationJob) {
        if job.isSourceFinal {
            draftJobs.removeValue(forKey: job.segmentID)
            finalJobs.removeAll { $0.segmentID == job.segmentID }
            finalJobs.append(job)
        } else { draftJobs[job.segmentID] = job }
        queuedTranslations = finalJobs.count + draftJobs.count
        scheduleWorker()
    }

    private func scheduleWorker() {
        guard workerTask == nil, translationSession != nil else { return }
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.drainTranslations()
            self.workerTask = nil
        }
    }

    private func drainTranslations() async {
        while !Task.isCancelled, let session = translationSession {
            let job: TranslationJob
            if !finalJobs.isEmpty {
                job = finalJobs.removeFirst()
            } else if let draft = draftJobs.values.min(by: { $0.segmentID.uuidString < $1.segmentID.uuidString }) {
                let wait = 0.55 - (ProcessInfo.processInfo.systemUptime - lastDraftTranslation)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue // A final result may have arrived while sleeping.
                }
                draftJobs.removeValue(forKey: draft.segmentID)
                job = draft
                lastDraftTranslation = ProcessInfo.processInfo.systemUptime
            } else { break }
            queuedTranslations = finalJobs.count + draftJobs.count
            guard timeline.needsTranslation(job) else { continue }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                let response = try await session.translate(job.source)
                guard !Task.isCancelled else { return }
                guard !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CaptionError.message("번역 결과가 비어 있습니다.")
                }
                if timeline.apply(translation: response.targetText, for: job) {
                    translationMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
                }
            } catch {
                if !Task.isCancelled {
                    timeline.fail(job, message: error.localizedDescription)
                    message = "일부 자막을 번역하지 못했습니다. 다시 번역하거나 원문을 확인해 주세요."
                }
            }
        }
        queuedTranslations = 0
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
