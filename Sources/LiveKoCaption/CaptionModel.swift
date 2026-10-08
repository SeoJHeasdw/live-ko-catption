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
    private var storedDictionaryIDs: Set<String>
    private let preferencesDefaults: UserDefaults
    private var storedPolishEnabled: Bool
    var polishEnabled: Bool {
        get { storedPolishEnabled }
        set {
            guard newValue != storedPolishEnabled, phase == .idle, !isPreparing,
                  !isPreview, !isUISoak, !isSwitchingDirection, !hasPendingTranslations else { return }
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
            timeline.direction = newValue
            preferencesDefaults.set(newValue.rawValue, forKey: CaptionDirection.preferenceKey)
            // Disable Start immediately, before the newly scheduled check gets
            // an actor turn. A previous pair's suspended check cannot re-enable it.
            readinessID = nil
            assetsReady = false
            isChecking = true
            translationConfiguration = nil
            refreshDictionaryStatus()
            message = nil
            Task { [weak self] in await self?.checkReadiness() }
        }
    }
    var selectedDictionaryIDs: Set<String> {
        get { storedDictionaryIDs }
        set {
            guard newValue != storedDictionaryIDs, canChangeSessionSettings else { return }
            storedDictionaryIDs = newValue
            preferencesDefaults.set(newValue.sorted(), forKey: CaptionDictionary.preferenceKey)
            refreshDictionaryStatus()
        }
    }
    private(set) var dictionaries = BuiltInDictionaries.all
    var selectedDictionaries: [CaptionDictionary] { dictionaries.filter { storedDictionaryIDs.contains($0.id) } }
    var dictionarySelectionLabel: String {
        let names = selectedDictionaries.map(\.name)
        return names.isEmpty ? "선택 없음 · 일반 번역" : names.joined(separator: " · ")
    }
    private(set) var dictionaryConflictMessage = ""
    private var dictionaryFiles: [String: URL] = [:]
    private var englishCorrections = CaptionGlossary.empty
    private var koreanCorrections = CaptionGlossary.empty
    /// Kept at its original path so existing personal terms survive migration.
    private(set) var glossary = CaptionGlossary.empty
    private(set) var glossaryMessage = ""
    let glossaryURL: URL
    static let defaultGlossaryURL = URL.applicationSupportDirectory
        .appendingPathComponent("Live Korean Captions/Glossary/glossary.txt")
    static let glossaryTemplate = """
        # Live Korean Captions 용어집
        # 한 줄에 용어 하나:  영어 = 한국어 | 잘못 들리는 표기, 잘못 들리는 표기
        # "= 한국어"를 빼면 이름을 번역하지 않고 그대로 둡니다. "| ..."는 뺄 수 있습니다.
        # 이 사전을 선택한 대화에 적용하고, 자막을 시작할 때마다 다시 읽습니다.
        # 이름과 선택적인 분야 설명: # 이름: 내 사전 / # 문맥: 짧은 분야 설명
        # "잘못 들리는 표기"는 음성 인식 원문에서 그 용어로 고쳐 씁니다. 적은 표기만 고칩니다.
        #
        # 예시 (앞의 "# "를 지우면 적용됩니다):
        # OpenShift | open shift
        # recall = 재현율
        # service mesh = 서비스 메시 | service mash

        """
    var devices: [AudioInputDevice] = []
    private struct DeviceQuery {
        let id = UUID()
        let task: Task<[AudioInputDevice], any Error>
    }
    private var deviceQuery: DeviceQuery?
    var selectedDeviceUID: String {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: "inputDeviceUID") }
    }
    /// The input is what this Mac plays rather than a microphone.
    var usesSystemAudio: Bool { selectedDeviceUID == AudioInputDevice.systemAudioUID }
    /// Computer sound is selected and nothing has played recently. Silence
    /// is normal there, so this is a hint and never an input error.
    private(set) var isWaitingForSystemAudio = false
    var showEnglish: Bool {
        didSet { UserDefaults.standard.set(showEnglish, forKey: "showEnglish") }
    }
    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    /// The small caption window also stays above slideshows and other
    /// presentations that cover ordinary floating windows.
    var compactStaysAbovePresentations: Bool {
        didSet { UserDefaults.standard.set(compactStaysAbovePresentations, forKey: "compactStaysAbovePresentations") }
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
            timeline.direction = .englishToKorean
            storedDictionaryIDs = []
            dictionaries = BuiltInDictionaries.all
            dictionaryFiles = [:]
            glossary = .empty
            glossaryMessage = "화면 검사에서는 개인 사전을 읽지 않습니다."
            refreshDictionaryStatus()
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
        let text = timeline.exportText(createdAt: sessionCreatedAt)
        guard !inputWarnings.isEmpty else { return text }
        return text + "\n입력 관련 알림 · 누락 가능성\n" + inputWarnings.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }
    private var startAssetsReady: Bool { assetsReady && phase == .idle && !isChecking && !isPreparing && !isPreparingLocalModel && (!polishEnabled || localPolishReady) && !isPreview && !hasPendingTranslations }
    var canStart: Bool { !isSwitchingDirection && startAssetsReady }
    /// The direction can flip inside a conversation: while listening, or while
    /// paused with nothing left to translate. Earlier captions keep their own.
    var canSwitchDirection: Bool {
        !isPreview && !isUISoak && !isPreparing && !isPreparingLocalModel && !isSwitchingDirection &&
            (phase == .listening || (phase == .idle && !isChecking && !hasPendingTranslations))
    }
    private(set) var isSwitchingDirection = false
    /// True when the latest start began an empty conversation. Resuming a paused
    /// conversation or restarting for a direction switch keeps the window the
    /// person is already using.
    private(set) var latestStartBeganConversation = false
    var canChangeSessionSettings: Bool {
        phase == .idle && !isPreparing && !isPreparingLocalModel && !isSwitchingDirection && !isPreview && !isUISoak && !hasContent && !hasPendingTranslations
    }
    var isBusy: Bool { phase == .starting || phase == .stopping || isPreparing || isPreparingLocalModel || isSwitchingDirection }
    var isListening: Bool { phase == .listening }
    var canStop: Bool { phase == .listening || phase == .starting }
    /// Stop ends the conversation: it halts input while listening, or closes a
    /// paused conversation that still has captions. Nothing is cleared until
    /// the person chooses to save or start a new conversation.
    var canEndConversation: Bool {
        guard !isPreview, !isUISoak, !isSwitchingDirection else { return false }
        return canStop || (phase == .idle && hasContent && !isPreparing && !isPreparingLocalModel)
    }
    var hasPendingTranslations: Bool { queuedTranslations > 0 || workerTask != nil || polishWorker != nil }
    var statusText: String {
        if isUISoak { return "화면 안정성 검사 · 합성 자막" }
        if isPreview { return "화면 미리보기" }
        if isSwitchingDirection { return "번역 방향 전환 중" }
        if isPreparing { return "처음 한 번 준비 중" }
        if isChecking { return "사용 가능 여부 확인 중" }
        switch phase {
        case .idle: return hasPendingTranslations ? "남은 원문 번역 중" : (assetsReady ? "준비됨" : "언어 모델 준비 필요")
        case .starting: return "시작 중"
        case .listening:
            if isWaitingForSystemAudio { return "컴퓨터 소리를 기다리는 중" }
            return usesSystemAudio ? "컴퓨터 소리에서 \(sourceDisplayName)를 듣고 있습니다" : "\(sourceDisplayName)를 듣고 있습니다"
        case .stopping: return "마지막 문장 정리 중"
        }
    }

    init(preview: Bool = false, translationOverride: (@MainActor (String, Bool) async throws -> String)? = nil,
         microphoneAccessOverride: (@MainActor () async -> Bool)? = nil,
         readinessOverride: (@MainActor (CaptionDirection) async throws -> Bool)? = nil,
         preferencesDefaults: UserDefaults = .standard,
         polishOverride: (@MainActor (LocalTranslationRequest) async throws -> String)? = nil,
         polishTimeoutSeconds: Double = 1.8,
         localEngine: LocalTranslationEngine? = nil,
         glossaryURL: URL = CaptionModel.defaultGlossaryURL) {
        self.glossaryURL = glossaryURL
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
        if preview { storedDictionaryIDs = [] }
        else if let saved = preferencesDefaults.stringArray(forKey: CaptionDictionary.preferenceKey) {
            storedDictionaryIDs = Set(saved)
        } else {
            let legacy = TranslationDomain(rawValue: preferencesDefaults.string(forKey: TranslationDomain.preferenceKey) ?? "") ?? .general
            switch legacy {
            case .general: storedDictionaryIDs = []
            case .it: storedDictionaryIDs = [BuiltInDictionaries.aiID]
            case .custom: storedDictionaryIDs = [BuiltInDictionaries.aiID, CaptionDictionary.localID(fileName: glossaryURL.lastPathComponent)]
            }
        }
        selectedDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? ""
        showEnglish = UserDefaults.standard.object(forKey: "showEnglish") as? Bool ?? true
        let savedFontSize = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 35
        fontSize = savedFontSize.isFinite ? min(52, max(24, savedFontSize)) : 35
        contextCorrectionEnabled = UserDefaults.standard.object(forKey: "contextCorrectionEnabled") as? Bool ?? true
        compactStaysAbovePresentations = UserDefaults.standard.object(forKey: "compactStaysAbovePresentations") as? Bool ?? true
        isPreview = preview
        timeline.direction = storedDirection
        reloadGlossary()
        if translationOverride == nil { refreshDevices(reportFailure: false) }
        if preview { loadPreview() }
    }

    /// Read local files only between runs. Pending translation uses its current
    /// dictionary snapshot, and previews never expose personal dictionary names.
    func reloadGlossary() {
        guard (phase == .idle || phase == .starting), !hasPendingTranslations else { return }
        if isPreview || isUISoak {
            dictionaries = BuiltInDictionaries.all
            glossary = .empty
            glossaryMessage = "미리보기에서는 개인 사전을 읽지 않습니다."
            refreshDictionaryStatus()
            return
        }
        let directory = glossaryURL.deletingLastPathComponent()
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "txt" }.sorted {
                let aSelected = storedDictionaryIDs.contains(CaptionDictionary.localID(fileName: $0.lastPathComponent))
                let bSelected = storedDictionaryIDs.contains(CaptionDictionary.localID(fileName: $1.lastPathComponent))
                return aSelected == bSelected ? $0.lastPathComponent < $1.lastPathComponent : aSelected
            }
        var personal: [CaptionDictionary] = []
        var unread = 0
        dictionaryFiles = [:]
        glossary = .empty
        for file in files {
            if personal.count == 32 { break }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber,
                  bytes.intValue <= 262_144, let data = try? Data(contentsOf: file),
                  data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { unread += 1; continue }
            let dictionary = CaptionDictionary.local(fileName: file.lastPathComponent, text: text)
            personal.append(dictionary)
            dictionaryFiles[dictionary.id] = file
            if file == glossaryURL { glossary = dictionary.glossary }
        }
        dictionaries = BuiltInDictionaries.all + personal.sorted { $0.id < $1.id }
        let terms = personal.reduce(0) { $0 + $1.glossary.entries.count }
        glossaryMessage = personal.isEmpty ? "개인 용어사전을 추가할 수 있습니다."
            : "개인 사전 \(personal.count)개 · 용어 \(terms)개를 읽었습니다."
        if unread > 0 { glossaryMessage += " 파일 \(unread)개는 읽지 못했습니다. UTF-8 형식과 크기를 확인하세요." }
        if files.count > 32 { glossaryMessage += " 개인 사전은 32개까지 읽습니다." }
        let validationWarnings = personal.flatMap(\.validationWarnings)
        if !validationWarnings.isEmpty {
            glossaryMessage += " 사전 필드 \(validationWarnings.count)개를 제외했습니다. " +
                Array(Set(validationWarnings)).sorted().joined(separator: " ")
        }
        refreshDictionaryStatus()
    }

    private func refreshDictionaryStatus() {
        let selected = selectedDictionaries
        englishCorrections = DictionaryTerms.corrections(dictionaries: selected, direction: .englishToKorean)
        koreanCorrections = DictionaryTerms.corrections(dictionaries: selected, direction: .koreanToEnglish)
        let conflicts = DictionaryTerms(dictionaries: selected, direction: selectedDirection).conflicts
        let missing = storedDictionaryIDs.subtracting(Set(dictionaries.map(\.id))).count
        dictionaryConflictMessage = conflicts.isEmpty ? "" :
            "번역이 다른 용어는 참고에서 제외합니다: " + conflicts.prefix(4).map(\.source).joined(separator: ", ")
        if conflicts.count > 4 { dictionaryConflictMessage += " 외 \(conflicts.count - 4)개" }
        if missing > 0 {
            dictionaryConflictMessage += (dictionaryConflictMessage.isEmpty ? "" : "\n") + "선택한 사전 \(missing)개를 찾지 못했습니다."
        }
    }

    func setDictionary(_ id: String, enabled: Bool) {
        var ids = selectedDictionaryIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        selectedDictionaryIDs = ids
    }

    func openDictionaryFile(_ id: String) {
        if let file = dictionaryFiles[id] { NSWorkspace.shared.open(file) }
    }

    @discardableResult
    func createDictionary(named name: String) throws -> URL {
        guard canChangeSessionSettings else { throw CaptionError.message("새 대화에서 용어사전을 추가하세요.") }
        guard dictionaries.filter(\.isPersonal).count < 32 else { throw CaptionError.message("개인 용어사전은 32개까지 추가할 수 있습니다.") }
        let name = String(name.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(60))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CaptionError.message("용어사전 이름을 입력하세요.") }
        guard CaptionDictionary(id: "validation", name: name, glossary: .empty).validationWarnings.isEmpty else {
            throw CaptionError.message("용어사전 이름에 사용할 수 없는 문자나 너무 긴 결합 문자가 있습니다.")
        }
        let file = glossaryURL.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("# 이름: \(name)\n# 문맥: \n" + Self.glossaryTemplate).utf8).write(to: file, options: .atomic)
        reloadGlossary()
        setDictionary(CaptionDictionary.localID(fileName: file.lastPathComponent), enabled: true)
        return file
    }

    func addDictionary() {
        guard canChangeSessionSettings else { return }
        let alert = NSAlert()
        alert.messageText = "용어사전 추가"
        alert.informativeText = "이름을 정하면 이 Mac에 사전 파일을 만들고 편집기로 엽니다. 회사 내부 용어도 여기에 적을 수 있습니다."
        let field = NSTextField(string: "")
        field.placeholderString = "예: 내 IBM 용어"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { NSWorkspace.shared.open(try createDictionary(named: field.stringValue)) }
        catch { glossaryMessage = error.localizedDescription }
    }

    func refreshDevices(reportFailure: Bool = true) {
        guard phase == .idle, !isPreview, !isUISoak, deviceQuery == nil else { return }
        // Reserve this model's query before scheduling a task so repeated
        // settings events cannot queue additional hardware lookups.
        let query = beginDeviceQuery()
        Task { [weak self] in
            do {
                let values = try await query.task.value
                guard let self, self.deviceQuery?.id == query.id else { return }
                self.deviceQuery = nil
                self.devices = values
            } catch {
                guard let self, self.deviceQuery?.id == query.id else { return }
                self.deviceQuery = nil
                if reportFailure, self.phase == .idle { self.message = error.localizedDescription }
            }
        }
    }

    private func beginDeviceQuery() -> DeviceQuery {
        if let deviceQuery { return deviceQuery }
        let query = DeviceQuery(task: Task { try await AudioInputDevice.available() })
        deviceQuery = query
        return query
    }

    private func currentDevices() async throws -> [AudioInputDevice] {
        let query = beginDeviceQuery()
        defer { if deviceQuery?.id == query.id { deviceQuery = nil } }
        let values = try await query.task.value
        if deviceQuery?.id == query.id { devices = values }
        return values
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

    /// Whether a direction can be recognized and translated with what is
    /// already installed. This never downloads anything.
    private func hasInstalledAssets(for direction: CaptionDirection) async -> Bool {
        if let readinessOverride { return (try? await readinessOverride(direction)) ?? false }
        guard SpeechTranscriber.isAvailable, let locale = try? await reserveSpeechLocale(for: direction) else { return false }
        let speech = await AssetInventory.status(forModules: [makeTranscriber(locale: locale)])
        let translation = await LanguageAvailability(preferredStrategy: .lowLatency)
            .status(from: Locale.Language(identifier: direction.sourceLanguageCode),
                    to: Locale.Language(identifier: direction.targetLanguageCode))
        return speech == .installed && translation == .installed
    }

    /// Flips the direction without starting a new conversation. A running
    /// session first finishes its last sentence, then listens again in the
    /// other language. Recorded captions keep the direction they were made in.
    func switchDirection() async {
        guard canSwitchDirection else { return }
        isSwitchingDirection = true
        defer { isSwitchingDirection = false }
        let next: CaptionDirection = selectedDirection == .englishToKorean ? .koreanToEnglish : .englishToKorean
        let installed: Bool
        do {
            installed = try await OperationDeadline.run(seconds: 15, name: "번역 방향 확인") {
                await self.hasInstalledAssets(for: next)
            }
        } catch {
            message = "번역 방향을 확인하지 못해 현재 언어를 유지합니다: \(error.localizedDescription)"
            return
        }
        guard installed else {
            message = "\(next.label) 언어 모델이 아직 준비되지 않아 방향을 바꾸지 못했습니다. 새 대화에서 그 방향을 선택해 한 번 준비해 주세요."
            return
        }
        let resume = phase == .listening
        if resume { await stop() }
        guard phase == .idle, !hasPendingTranslations else { return }
        storedDirection = next
        refreshDictionaryStatus()
        timeline.direction = next
        preferencesDefaults.set(next.rawValue, forKey: CaptionDirection.preferenceKey)
        readinessID = nil
        translationConfiguration = nil
        isChecking = false
        assetsReady = true
        if resume { await start(allowDirectionSwitch: true) }
    }

    private func readinessIsCurrent(_ token: UUID, direction: CaptionDirection) -> Bool {
        readinessID == token && selectedDirection == direction && !Task.isCancelled
    }

    func requestPreparation() {
        guard !isPreparing && !isSwitchingDirection && phase == .idle && !isPreview else { return }
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
        await start(allowDirectionSwitch: false)
    }

    /// Only the owner of a direction transition can resume its new language.
    /// Public controls remain closed throughout that transition, including
    /// async asset checks and the restarted input's startup awaits.
    private func start(allowDirectionSwitch: Bool) async {
        guard startAssetsReady, !isSwitchingDirection || allowDirectionSwitch else { return }
        latestStartBeganConversation = !allowDirectionSwitch && !hasContent
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
        reloadGlossary()
        let requestedDeviceUID = selectedDeviceUID
        let usesSystemAudio = requestedDeviceUID == AudioInputDevice.systemAudioUID
        do {
            let inputDevices = try await currentDevices()
            try checkStarting(token)
            guard requestedDeviceUID.isEmpty || usesSystemAudio || inputDevices.contains(where: { $0.uid == requestedDeviceUID }) else {
                throw CaptionError.message("선택한 마이크가 연결되지 않았습니다. 다시 연결하거나 입력 장치를 직접 선택해 주세요.")
            }
            // Computer sound opens no microphone. macOS asks for its own
            // system audio permission when the tap first delivers audio.
            let allowed: Bool
            if usesSystemAudio { allowed = true }
            else if let microphoneAccessOverride { allowed = await microphoneAccessOverride() }
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
            let deviceID = inputDevices.first(where: { $0.uid == requestedDeviceUID })?.id
            let stream = try await audioCapture.start(deviceID: deviceID,
                systemAudio: usesSystemAudio ? .init() : nil, target: format,
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
                }, onSourceActivity: { [weak self] active in
                    guard let self, self.runID == token else { return }
                    self.isWaitingForSystemAudio = usesSystemAudio && !active
                })
            try checkStarting(token)
            // The pump's frame clock starts after HAL device construction.
            // Waiting for startup is not accepted audio or caption duration.
            runUptime = audioCapture.timeOrigin ?? ProcessInfo.processInfo.systemUptime
            startedAt = Date()
            runHasAudio = true
            isWaitingForSystemAudio = usesSystemAudio
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
        isWaitingForSystemAudio = false
        phase = .idle
    }

    func newSession() {
        guard phase == .idle && !isPreparing && !isSwitchingDirection else { return }
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
        timeline.direction = storedDirection
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
        guard !isPreview, !isSwitchingDirection, phase == .idle || phase == .listening else { return }
        guard let _ = translationSession else {
            translationSession = TranslationSessionLease(installedSource: sourceLanguage, target: targetLanguage,
                                                    preferredStrategy: .lowLatency)
            enqueueFailedTranslations()
            return
        }
        enqueueFailedTranslations()
    }

    private func enqueueFailedTranslations() {
        // The open translation session serves the current direction only.
        for segment in segments where segment.translationError != nil && segment.direction == selectedDirection {
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
        // Only spellings the user listed are corrected, before any translation.
        let corrections = selectedDirection == .englishToKorean ? englishCorrections : koreanCorrections
        let corrected = corrections.correctionResult(source, direction: selectedDirection)
        if corrected.exceededByteLimit {
            let warning = "개인 사전 교정 결과가 너무 커서 인식한 원문을 그대로 유지했습니다."
            if !inputWarnings.contains(warning) { inputWarnings.append(warning) }
            message = warning
        }
        let source = corrected.text
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
                            direction: selectedDirection, dictionaries: selectedDictionaries)
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
            direction: selectedDirection, dictionaries: selectedDictionaries)
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
            direction: selectedDirection, dictionaries: selectedDictionaries)
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
                localPolishMessage = "문맥 다듬기 사용 중 · \(dictionarySelectionLabel)"
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
