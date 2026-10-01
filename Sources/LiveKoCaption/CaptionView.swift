import AppKit
import CaptionCore
import SwiftUI
import Translation

enum CaptionPalette {
    static let background = Color(red: 0.040, green: 0.054, blue: 0.076)
    static let panel = Color(red: 0.065, green: 0.083, blue: 0.111)
    static let ink = Color(red: 0.94, green: 0.96, blue: 0.99)
    static let secondary = Color(red: 0.56, green: 0.61, blue: 0.68)
    static let draft = Color(red: 0.59, green: 0.63, blue: 0.69)
    static let blue = Color(red: 0.39, green: 0.68, blue: 1.0)
    static let green = Color(red: 0.36, green: 0.82, blue: 0.64)
    static let border = Color.white.opacity(0.075)
}

struct CaptionView: View {
    @Bindable var model: CaptionModel
    let windows: CaptionWindowCoordinator
    @ViewState private var presentationMode = false
    @ViewState private var confirmsNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            CaptionHeader(model: model, windows: windows, presentationMode: $presentationMode)
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            HStack(spacing: 0) {
                if !presentationMode {
                    CaptionSidebar(model: model) { confirmsNewSession = true }.frame(width: 280)
                    Rectangle().fill(CaptionPalette.border).frame(width: 1)
                }
                CaptionArea(model: model)
            }.frame(maxHeight: .infinity)
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            CaptionFooter(model: model)
        }
        .background(CaptionPalette.background)
        .foregroundStyle(CaptionPalette.ink)
        .preferredColorScheme(.dark)
        .tint(CaptionPalette.blue)
        .frame(minWidth: 950, minHeight: 660)
        .background(CaptionWindowAttachment(windows: windows, model: model))
        .task {
            async let localCheck: Void = LocalModelStore.shared.refresh()
            await model.checkReadiness()
            await localCheck
            if model.polishEnabled { await model.prepareLocalModel() }
        }
        .translationTask(model.translationConfiguration) { session in
            await model.prepareModels(using: session)
        }
        .onAppear {
            CaptionAppDelegate.model = model
            CaptionUISoakRunner.start(model: model)
        }
        .onChange(of: model.phase) { oldPhase, newPhase in
            if oldPhase == .starting && newPhase == .listening { windows.showCompact() }
        }
        .alert("새 대화를 시작할까요?", isPresented: $confirmsNewSession) {
            Button("취소", role: .cancel) {}
            Button("저장 후 새 대화") {
                if model.exportTranscript() { model.newSession() }
            }
            Button("저장하지 않고 새 대화", role: .destructive) { model.newSession() }
        } message: { Text("새 대화를 시작하면 현재 기록이 지워집니다. 원문과 자막을 먼저 저장할 수 있습니다.") }
    }
}

// Keep frequently changing observation scopes out of the window's root layout.
// An input-level tick must not re-evaluate captions, controls or the sidebar.
private struct CaptionHeader: View {
    @Bindable var model: CaptionModel
    let windows: CaptionWindowCoordinator
    @Binding var presentationMode: Bool
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(CaptionPalette.blue)
                .frame(width: 43, height: 43)
                .background(CaptionPalette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("라이브 자막").font(.system(size: 19, weight: .semibold))
                Text(model.directionLabel).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CaptionPalette.secondary)
            }
            Spacer()
            if model.isPreview {
                Label("예시 대화 · 미리보기", systemImage: "eye")
                    .font(.system(size: 12)).foregroundStyle(CaptionPalette.blue)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(CaptionPalette.blue.opacity(0.08), in: Capsule())
            } else {
                Circle().fill(model.isListening ? CaptionPalette.green : CaptionPalette.secondary)
                    .frame(width: 7, height: 7)
                Text(model.isPreparingLocalModel ? "문장 보완 준비 중" :
                    model.phase == .idle && model.hasContent && !model.hasPendingTranslations ? "일시정지" : model.statusText)
                    .font(.system(size: 12)).foregroundStyle(CaptionPalette.secondary)
            }
            if presentationMode {
                CaptionSessionButton(model: model, compact: true)
            }
            Button { windows.showCompact() } label: {
                Label("간략 보기", systemImage: "pip")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 32)
            }.buttonStyle(.plain)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .help("작은 떠 있는 자막 창으로 전환 · ⌘2")
            Button { presentationMode.toggle() } label: {
                Image(systemName: presentationMode ? "sidebar.left" : "rectangle.expand.vertical")
                    .frame(width: 32, height: 32)
            }.buttonStyle(.plain)
                .accessibilityLabel(presentationMode ? "조작 패널 보기" : "자막만 보기")
                .help(presentationMode ? "조작 패널 보기" : "자막만 보기")
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 32)
            }.buttonStyle(.plain).accessibilityLabel("전체 화면 전환").help("전체 화면")
        }.padding(.horizontal, 24).padding(.top, 23).padding(.bottom, 20)
    }

}

private struct CaptionSidebar: View {
    @Bindable var model: CaptionModel
    var requestNewSession: () -> Void
    @ViewState private var showsTranslationSettings = false
    @ViewState private var showsDisplaySettings = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    directionSettings
                    microphoneSettings
                    if !model.assetsReady && !model.isChecking { setupCard }
                    Divider().overlay(CaptionPalette.border)
                    DisclosureGroup(isExpanded: $showsTranslationSettings) {
                        translationSettings.padding(.top, 12)
                    } label: {
                        HStack {
                            Label("번역 설정", systemImage: "character.bubble")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            if model.polishEnabled {
                                Text("보완 켜짐").font(.system(size: 10)).foregroundStyle(CaptionPalette.blue)
                            }
                        }
                    }
                    DisclosureGroup(isExpanded: $showsDisplaySettings) {
                        displaySettings.padding(.top, 12)
                    } label: {
                        Label("자막 표시", systemImage: "textformat.size")
                            .font(.system(size: 12, weight: .medium))
                    }
                }.padding(22)
            }.scrollIndicators(.automatic)
            sessionControls
        }.background(CaptionPalette.panel)
    }

    private var directionSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("번역 방향")
            Picker("번역 방향", selection: $model.selectedDirection) {
                Text("영어 → 한국어").tag(CaptionDirection.englishToKorean)
                Text("한국어 → 영어").tag(CaptionDirection.koreanToEnglish)
            }.pickerStyle(.radioGroup).labelsHidden().font(.system(size: 13))
                .disabled(!model.canChangeSessionSettings)
            if model.hasContent {
                Text("방향 변경은 새 대화에서 가능합니다.")
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
            }
        }
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("마이크")
                Spacer()
                Button { model.refreshDevices() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("마이크 목록 새로고침")
                    .help("마이크 목록 새로고침").disabled(model.phase != .idle)
            }
            Picker("마이크", selection: $model.selectedDeviceUID) {
                Text("시스템 기본 마이크").tag("")
                ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                if !model.selectedDeviceUID.isEmpty && !model.devices.contains(where: { $0.uid == model.selectedDeviceUID }) {
                    Text("저장된 마이크 · 연결 안 됨").tag(model.selectedDeviceUID)
                }
            }.labelsHidden().pickerStyle(.menu).disabled(model.phase != .idle)
                .frame(maxWidth: .infinity, alignment: .leading)
            CaptionAudioMeter(model: model)
            Text(model.isListening ? "입력 중 · 마이크 가까이에서 말해 주세요." : "시작하면 입력 크기가 표시됩니다.")
                .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
        }
    }

    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("최근 구절 함께 번역", isOn: $model.contextCorrectionEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(model.phase != .idle)
                Text("이어지는 문맥에 맞춰 최근 자막을 수정합니다.")
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
            }
            Divider().overlay(CaptionPalette.border)
            LocalPolishControls(model: model, store: LocalModelStore.shared)
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("원문 함께 보기", isOn: $model.showEnglish)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help("\(model.sourceDisplayName) 원문을 자막 아래에 표시합니다.")
            HStack {
                Text("글자 크기").font(.system(size: 12))
                Spacer()
                Text("\(Int(model.fontSize)) pt")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(CaptionPalette.secondary)
            }
            Slider(value: $model.fontSize, in: 24...52, step: 1)
                .accessibilityLabel("자막 글자 크기")
                .accessibilityValue("\(Int(model.fontSize))포인트")
        }
    }

    private var sessionControls: some View {
        VStack(spacing: 12) {
            CaptionSessionButton(model: model)
            if !model.canStart && !model.canStop {
                Text(model.isPreview ? "예시 대화가 표시되어 있습니다." :
                    model.isPreparingLocalModel ? "문장 보완 모델 준비 중" : model.statusText)
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { model.exportTranscript() } label: {
                    Label("기록 저장", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }.disabled(!model.hasContent).help("원문과 번역을 텍스트 파일로 저장 · ⌘S")
                Button {
                    if model.hasContent { requestNewSession() } else { model.newSession() }
                } label: {
                    Label("새 대화", systemImage: "plus.bubble").frame(maxWidth: .infinity)
                }.disabled(model.phase != .idle || model.isPreparing || model.isPreparingLocalModel)
            }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 11))
            Text("기록은 자동 저장되지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
        }.padding(18)
            .frame(maxWidth: .infinity)
            .background(CaptionPalette.panel)
            .overlay(alignment: .top) { Rectangle().fill(CaptionPalette.border).frame(height: 1) }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("언어 모델 준비", systemImage: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(model.isPreparing ? model.preparationMessage :
                "첫 사용 시 다운로드가 필요합니다. 준비 후에는 오프라인으로 사용할 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
            if model.isPreparing {
                if let progress = model.preparationProgress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else { ProgressView().controlSize(.small) }
            } else {
                Button("언어 모델 준비") { model.requestPreparation() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(13).background(CaptionPalette.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(CaptionPalette.secondary)
    }
}

private struct CaptionSessionButton: View {
    let model: CaptionModel
    var compact = false
    @SwiftUI.FocusState private var isFocused: Bool

    private var title: String {
        switch model.phase {
        case .starting: return "시작 취소"
        case .listening: return "일시정지"
        case .stopping: return "정리 중…"
        case .idle: return model.hasContent ? "자막 재개" : "자막 시작"
        }
    }

    var body: some View {
        Button {
            Task {
                if model.canStop { await model.stop() }
                else if model.canStart { await model.start() }
            }
        } label: {
            HStack(spacing: 8) {
                if model.phase == .stopping { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: model.phase == .starting ? "xmark" : model.isListening ? "pause.fill" : "play.fill")
                }
                Text(title).font(.system(size: compact ? 12 : 14, weight: .semibold))
                if !compact {
                    Spacer()
                    Text("␣").font(.system(size: 13)).opacity(0.6).accessibilityHidden(true)
                }
            }.frame(maxWidth: compact ? nil : .infinity).frame(height: compact ? 30 : 44)
        }.buttonStyle(CaptionSessionButtonStyle(isRunning: model.canStop))
            .disabled(!model.canStart && !model.canStop)
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? CaptionPalette.blue : .clear, lineWidth: 2)
                    .padding(-3).allowsHitTesting(false)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("\(title) · 스페이스 바")
    }
}

private struct CaptionSessionButtonStyle: ButtonStyle {
    let isRunning: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 14)
            .foregroundStyle(isEnabled && !isRunning ? CaptionPalette.background : CaptionPalette.ink.opacity(isEnabled ? 1 : 0.5))
            .background((isRunning ? Color.white.opacity(0.13) : CaptionPalette.blue)
                .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.18),
                in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LocalPolishControls: View {
    @Bindable var model: CaptionModel
    @Bindable var store: LocalModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("문장 보완").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("실험 기능").font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
            }
            Toggle("로컬 모델 사용", isOn: $model.polishEnabled)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(!store.isInstalled || model.phase != .idle || model.isPreparing || model.isPreview || model.isUISoak)
            Text("빠른 자막을 먼저 표시하고 확정 문장만 보완합니다. 오역이 생길 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
            if store.isInstalled {
                Picker("번역 분야", selection: $model.translationDomain) {
                    Text("일반").tag(TranslationDomain.general)
                    Text("IT").tag(TranslationDomain.it)
                }.pickerStyle(.segmented).font(.system(size: 11))
                    .disabled(!model.polishEnabled || !model.canChangeSessionSettings)
                if model.isPreparingLocalModel { ProgressView().controlSize(.small) }
                if model.polishEnabled {
                    Text(model.localPolishMessage)
                        .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
                }
            } else if store.isDownloading || store.isVerifying {
                if let progress = store.progress { ProgressView(value: progress).progressViewStyle(.linear) }
                else { ProgressView().controlSize(.small) }
                Text(store.message).font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
                if store.isDownloading {
                    Button("다운로드 취소") { store.cancelDownload() }.controlSize(.small)
                }
            } else {
                Button("모델 다운로드 · 1.47 GB") { store.requestDownload() }
                    .controlSize(.small).disabled(model.phase != .idle || model.isPreparing || model.isPreview || model.isUISoak)
                if !store.message.isEmpty {
                    Text(store.message).font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
                        .lineSpacing(3)
                }
            }
        }
    }
}

private struct CaptionAudioMeter: View {
    let model: CaptionModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<26) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Double(index) / 26 < model.audioLevel ? CaptionPalette.green : Color.white.opacity(0.09))
                    .frame(height: 12)
            }
        }.accessibilityLabel("마이크 입력 크기")
            .accessibilityValue("\(Int(model.audioLevel * 100))퍼센트")
    }
}

private struct CaptionArea: View {
    @Bindable var model: CaptionModel
    @ViewState private var followsLatest = true
    private let visibleLimit = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.targetDisplayName) 자막").font(.system(size: 13, weight: .semibold))
                if model.segments.contains(where: { $0.translationError != nil }) {
                    Button("다시 번역") { model.retryFailedTranslations() }
                        .controlSize(.small)
                        .disabled(model.isPreview || (model.phase != .idle && model.phase != .listening))
                        .help("알림을 닫아도 실패한 번역을 다시 시도할 수 있습니다.")
                }
                Spacer()
                Button { followsLatest.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: followsLatest ? "arrow.down.to.line" : "arrow.down")
                        Text(followsLatest ? "자동 따라가기" : "최신 자막으로")
                    }.font(.system(size: 11)).foregroundStyle(followsLatest ? CaptionPalette.blue : CaptionPalette.secondary)
                }.buttonStyle(.plain).disabled(!model.hasContent)
                    .accessibilityLabel("최신 자막 따라가기")
                    .accessibilityValue(followsLatest ? "켜짐" : "꺼짐")
                    .help(followsLatest ? "새 자막을 따라갑니다. 직접 스크롤하면 따라가기가 멈춥니다." : "최신 자막으로 이동하고 자동 따라가기를 켭니다.")
            }.padding(.horizontal, 34).padding(.top, 25).padding(.bottom, 14)
            CaptionMessage(model: model)
            if model.hasContent {
                NativeCaptionTranscript(segments: model.recentDisplaySegments(limit: visibleLimit),
                    fontSize: model.fontSize, showEnglish: model.showEnglish,
                    isIdle: model.phase == .idle && !model.isPreview, followsLatest: $followsLatest,
                    accessibilityLabel: "\(model.targetDisplayName) 실시간 자막과 \(model.sourceDisplayName) 원문")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("회색은 수정 중 · 밝은 자막은 확정")
                        .help("확정은 현재 원문의 번역이 완료됐다는 뜻입니다. 번역의 의미 정확성을 보증하지 않습니다.")
                    Spacer()
                    if model.displayHistoryCount > visibleLimit {
                        Text("최근 100개 표시 · 전체 기록은 저장 가능")
                    }
                }.font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
                    .padding(.horizontal, 34).padding(.vertical, 10)
            } else {
                CaptionEmptyState(model: model)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CaptionEmptyState: View {
    let model: CaptionModel

    private var title: String {
        if model.isPreparing { return "언어 모델 준비 중" }
        if model.isChecking { return "사용 준비 확인 중" }
        if model.isPreparingLocalModel { return "문장 보완 준비 중" }
        switch model.phase {
        case .starting: return "마이크 연결 중"
        case .listening: return "\(model.sourceDisplayName)로 말해 주세요"
        case .stopping: return "마지막 자막 정리 중"
        case .idle: return "대화를 자막으로 읽으세요"
        }
    }

    private var detail: String {
        if model.isPreparing { return "다운로드가 끝나면 자막을 시작할 수 있습니다." }
        if model.isChecking { return "선택한 언어의 음성 인식과 번역을 확인하고 있습니다." }
        if model.isPreparingLocalModel { return "로컬 모델을 불러오고 있습니다. 준비가 끝나면 시작할 수 있습니다." }
        switch model.phase {
        case .starting: return "마이크 접근 권한을 요청하면 허용해 주세요."
        case .listening: return "말씀하신 내용이 \(model.targetDisplayName) 자막으로 여기에 나타납니다."
        case .stopping: return "남은 원문과 번역을 정리하고 있습니다."
        case .idle:
            return model.assetsReady ? "번역 방향과 마이크를 확인한 뒤 ‘자막 시작’을 누르세요." :
                "번역 방향을 선택하고 왼쪽에서 언어 모델을 준비하세요."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: model.isListening ? "waveform" : "captions.bubble")
                .font(.system(size: 38, weight: .light)).foregroundStyle(CaptionPalette.blue)
                .frame(width: 80, height: 80)
                .background(CaptionPalette.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(CaptionPalette.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
            Label(model.directionLabel, systemImage: "character.bubble")
                .font(.system(size: 12)).foregroundStyle(CaptionPalette.secondary).padding(.top, 4)
            Spacer()
        }.frame(maxWidth: .infinity).padding(.horizontal, 36).padding(.bottom, 40)
    }
}

private struct CaptionMessage: View {
    @Bindable var model: CaptionModel
    var body: some View {
        if let message = model.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).font(.system(size: 12)).lineSpacing(4)
                Spacer()
                if model.segments.contains(where: { $0.translationError != nil }) {
                    Button("다시 번역") { model.retryFailedTranslations() }
                        .controlSize(.small)
                        .disabled(model.isPreview || (model.phase != .idle && model.phase != .listening))
                }
                Button { model.message = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("알림 닫기")
            }.padding(13).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 34).padding(.bottom, 12)
        }
    }
}

private struct CaptionFooter: View {
    let model: CaptionModel
    @ViewState private var showsTiming = false

    private var hasTiming: Bool {
        !model.isPreview && !model.isUISoak &&
            (model.captionDelaySeconds != nil || model.speechDelaySeconds != nil || model.translationMilliseconds != nil)
    }

    var body: some View {
        HStack(spacing: 18) {
            Label("이 Mac에서 처리", systemImage: "desktopcomputer")
                .foregroundStyle(CaptionPalette.green.opacity(0.9))
            if model.isUISoak {
                Text("합성 자막 · 화면 검사")
            } else if !model.isPreview {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.elapsed(at: context.date)).monospacedDigit()
                        .accessibilityLabel("대화 시간")
                        .accessibilityValue(model.elapsed(at: context.date))
                }
            }
            Spacer()
            if !model.isUISoak && !model.isPreview {
                if model.queuedTranslations > 0 { Text("번역 대기 \(model.queuedTranslations)개") }
                else if model.hasPendingTranslations { Text("번역 중") }
            }
            if hasTiming {
                Button { showsTiming.toggle() } label: {
                    Label("처리 시간", systemImage: "info.circle")
                }.buttonStyle(.plain).help("최근 인식·번역의 처리 시간 보기")
                    .popover(isPresented: $showsTiming, arrowEdge: .top) {
                        timingDetails.padding(18).frame(width: 300)
                            .preferredColorScheme(.dark)
                    }
            }
        }.font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
            .padding(.horizontal, 24).frame(height: 40)
    }

    private var timingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("최근 처리 시간").font(.system(size: 13, weight: .semibold))
            if let delay = model.captionDelaySeconds {
                HStack {
                    Text("자막 도착")
                    Spacer()
                    Text("약 \(delay, specifier: "%.1f")초").monospacedDigit()
                }
            }
            if let delay = model.speechDelaySeconds {
                HStack {
                    Text("음성 인식")
                    Spacer()
                    Text("약 \(delay, specifier: "%.1f")초").monospacedDigit()
                }
            }
            if let elapsed = model.translationMilliseconds {
                HStack {
                    Text("번역 호출")
                    Spacer()
                    Text("\(elapsed / 1000, specifier: "%.2f")초").monospacedDigit()
                }
            }
            Divider()
            Text("자막 도착은 음성 구간 끝부터 \(model.targetDisplayName) 번역 반영까지의 추정치입니다. 음성 인식은 해당 결과의 도착까지, 번역 호출은 마지막 번역 작업의 시간입니다. 마이크 하드웨어 지연은 포함하지 않습니다.")
                .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
        }.font(.system(size: 12))
    }
}
