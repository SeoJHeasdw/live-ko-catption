import AppKit
import CaptionCore
import SwiftUI
import Translation

enum CaptionPalette {
    static let background = Color(red: 0.040, green: 0.054, blue: 0.076)
    static let panel = Color(red: 0.065, green: 0.083, blue: 0.111)
    static let ink = Color(red: 0.94, green: 0.96, blue: 0.99)
    static let secondary = Color(red: 0.68, green: 0.72, blue: 0.78)
    static let draft = Color(red: 0.59, green: 0.63, blue: 0.69)
    static let blue = Color(red: 0.39, green: 0.68, blue: 1.0)
    static let green = Color(red: 0.36, green: 0.82, blue: 0.64)
    static let border = Color.white.opacity(0.075)
}

struct CaptionView: View {
    @Bindable var model: CaptionModel
    let windows: CaptionWindowCoordinator
    @ViewState private var confirmsNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            CaptionHeader(model: model, windows: windows) { confirmsNewSession = true }
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            CaptionArea(model: model).frame(maxHeight: .infinity)
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            CaptionFooter(model: model)
        }
        .background(CaptionPalette.background)
        .foregroundStyle(CaptionPalette.ink)
        .preferredColorScheme(.dark)
        .tint(CaptionPalette.blue)
        .frame(minWidth: 860, minHeight: 560)
        .ignoresSafeArea(.container, edges: .top)
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

enum CaptionType {
    static let body = Font.system(size: 15)
    static let supporting = Font.system(size: 14)
    static let section = Font.system(size: 15, weight: .semibold)
    static let title = Font.system(size: 18, weight: .semibold)
}

// Input-level observation belongs to the meter in Settings, never this layout.
private struct CaptionHeader: View {
    @Bindable var model: CaptionModel
    let windows: CaptionWindowCoordinator
    var requestNewSession: () -> Void
    @ViewState private var showsSettings = false

    var body: some View {
        HStack(spacing: 12) {
            Label("라이브 자막", systemImage: "captions.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CaptionPalette.ink)
            directionControl.frame(width: 184)
            Spacer(minLength: 8)
            if model.isPreview {
                Label("예시 대화 · 미리보기", systemImage: "eye")
                    .font(CaptionType.supporting).foregroundStyle(CaptionPalette.blue)
            }
            HStack(spacing: 4) {
                CaptionIconButton("새 대화", symbol: "plus.bubble",
                    help: "현재 기록을 저장하거나 지운 뒤 새 대화를 시작합니다.") {
                    if model.hasContent { requestNewSession() } else { model.newSession() }
                }.disabled(model.phase != .idle || model.isPreparing || model.isPreparingLocalModel)
                CaptionIconButton("기록 저장", symbol: "square.and.arrow.down",
                    help: "전체 원문과 번역을 텍스트 파일로 저장합니다. 기록은 자동 저장되지 않습니다. · ⌘S") {
                    model.exportTranscript()
                }.disabled(!model.hasContent)
                CaptionIconButton("간략 보기", symbol: "pip",
                    help: "다른 앱 위에 떠 있는 작은 자막 창으로 전환합니다. · ⌘2") { windows.showCompact() }
                CaptionIconButton("전체 화면", symbol: "arrow.up.left.and.arrow.down.right",
                    help: "전체 화면을 켜거나 끕니다.") { windows.detailWindow?.toggleFullScreen(nil) }
                CaptionIconButton("설정", symbol: "gearshape",
                    help: "원문 표시, 글자 크기, 문장 다듬기와 마이크 설정을 엽니다.") { showsSettings.toggle() }
                    .sheet(isPresented: $showsSettings) {
                        CaptionSettingsPopover(model: model) { showsSettings = false }
                    }
            }
        }.padding(.leading, 88).padding(.trailing, 20).frame(height: 54)
    }

    @ViewBuilder private var directionControl: some View {
        if model.canChangeSessionSettings {
            Picker("번역 방향", selection: $model.selectedDirection) {
                Text("영어 → 한국어").tag(CaptionDirection.englishToKorean)
                Text("한국어 → 영어").tag(CaptionDirection.koreanToEnglish)
            }.pickerStyle(.menu).labelsHidden().font(CaptionType.body)
                .help("시작 전에 말할 언어와 자막 언어를 선택합니다.")
        } else {
            HStack(spacing: 8) {
                Text(model.directionLabel).font(CaptionType.body)
                Image(systemName: "lock").font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
            }.frame(maxWidth: .infinity).frame(height: 32)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("번역 방향").accessibilityValue(model.directionLabel)
                .help(model.hasContent ? "방향을 바꾸려면 현재 기록을 저장하고 새 대화를 시작하세요." :
                    "준비하거나 자막을 진행하는 동안에는 번역 방향을 유지합니다.")
        }
    }
}

private struct CaptionIconButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @ViewState private var isHovered = false
    @SwiftUI.FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(CaptionPalette.ink.opacity(isEnabled ? 1 : 0.4))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(isEnabled && isHovered ? 0.10 : 0),
                    in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? CaptionPalette.blue : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .help(help).accessibilityLabel(title).accessibilityHint(help)
    }
}

private enum CaptionSettingsTab: String, CaseIterable {
    case captions = "자막"
    case translation = "번역"
    case microphone = "마이크"
}

private struct CaptionSettingsTabButton: View {
    let item: CaptionSettingsTab
    @Binding var selected: CaptionSettingsTab
    @ViewState private var isHovered = false
    @SwiftUI.FocusState private var isFocused: Bool

    var body: some View {
        Button { selected = item } label: {
            Text(item.rawValue).font(.system(size: 15, weight: selected == item ? .semibold : .regular))
                .foregroundStyle(selected == item ? CaptionPalette.blue : CaptionPalette.ink)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(selected == item ? CaptionPalette.blue.opacity(0.15) :
                    Color.white.opacity(isHovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).focused($isFocused).onHover { isHovered = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? CaptionPalette.blue : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .help("\(item.rawValue) 설정을 표시합니다.")
            .accessibilityLabel("\(item.rawValue) 설정")
            .accessibilityValue(selected == item ? "선택됨" : "선택 안 됨")
    }
}

private struct CaptionSettingsPopover: View {
    @Bindable var model: CaptionModel
    var dismiss: () -> Void
    @ViewState private var tab = CaptionSettingsTab.captions

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("설정").font(CaptionType.title)
                Spacer()
                CaptionIconButton("설정 닫기", symbol: "xmark", help: "설정 팝업을 닫습니다. · Esc", action: dismiss)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            HStack(spacing: 4) {
                ForEach(CaptionSettingsTab.allCases, id: \.self) { item in
                    CaptionSettingsTabButton(item: item, selected: $tab)
                }
            }.padding(4).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .captions: captionSettings
                    case .translation: translationSettings
                    case .microphone: microphoneSettings
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.id(tab).frame(width: 452, height: tab == .captions ? 220 : tab == .translation ? 300 : 280)
            Text("언어 모델을 준비한 뒤에는 이 Mac에서 처리합니다.")
                .font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
        }.font(CaptionType.body).controlSize(.large).padding(24).frame(width: 500)
            .background(CaptionPalette.panel).foregroundStyle(CaptionPalette.ink)
            .tint(CaptionPalette.blue).preferredColorScheme(.dark)
            .onAppear { model.refreshDevices() }
            .onChange(of: tab) { _, newTab in
                if newTab == .microphone { model.refreshDevices() }
            }
    }

    private var captionSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("원문 함께 보기", isOn: $model.showEnglish).toggleStyle(.checkbox)
                    .help("\(model.sourceDisplayName) 원문을 번역 자막 아래에 표시하거나 숨깁니다.")
                explanation("현재 대화의 \(model.sourceDisplayName) 원문을 자막 아래에 표시합니다.")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("자막 글자 크기").font(CaptionType.section)
                    Spacer()
                    Text("\(Int(model.fontSize)) pt").monospacedDigit().foregroundStyle(CaptionPalette.secondary)
                }
                Slider(value: $model.fontSize, in: 24...52, step: 1)
                    .accessibilityLabel("자막 글자 크기").accessibilityValue("\(Int(model.fontSize))포인트")
                    .help("번역 자막과 그 아래 원문의 글자 크기를 함께 조절합니다.")
                explanation("원문 크기도 자막에 맞춰 함께 조절됩니다.")
            }
        }
    }

    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("최근 구절 함께 번역", isOn: $model.contextCorrectionEnabled)
                    .toggleStyle(.checkbox).disabled(model.phase != .idle)
                    .help("이어지는 문맥에 맞춰 최근 구절을 다시 번역합니다. 듣는 중에는 변경할 수 없습니다.")
                explanation("이어지는 문맥에 맞춰 최근 자막을 수정합니다.")
            }
            Divider().overlay(CaptionPalette.border)
            LocalPolishControls(model: model, store: LocalModelStore.shared)
        }
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("입력 마이크").font(CaptionType.section)
                Picker("입력 마이크", selection: $model.selectedDeviceUID) {
                    Text("자동 선택 (시스템 기본)").tag("")
                    ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                    if !model.selectedDeviceUID.isEmpty && !model.devices.contains(where: { $0.uid == model.selectedDeviceUID }) {
                        Text("저장된 마이크 · 연결 안 됨").tag(model.selectedDeviceUID)
                    }
                }.labelsHidden().pickerStyle(.menu).controlSize(.large)
                    .disabled(model.phase != .idle)
                    .help("자동 선택은 시작할 때 시스템 기본 마이크를 사용합니다. 원하는 장치를 직접 지정할 수도 있습니다.")
                explanation(model.selectedDeviceUID.isEmpty ? "시작할 때 시스템 기본 마이크를 자동으로 사용합니다." :
                    "선택한 마이크를 사용합니다. 변경하려면 먼저 일시정지하세요.")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("입력 크기").font(CaptionType.section)
                CaptionAudioMeter(model: model)
                explanation(model.isListening ? "마이크 가까이에서 말해 주세요." : "자막을 시작하면 입력 크기가 표시됩니다.")
            }
            Button { model.refreshDevices() } label: {
                Label("목록 새로고침", systemImage: "arrow.clockwise")
            }.buttonStyle(.bordered).controlSize(.large).disabled(model.phase != .idle)
                .help("연결된 마이크 목록을 다시 확인합니다. 설정을 열거나 자막을 시작할 때도 갱신됩니다.")
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CaptionSessionButton: View {
    let model: CaptionModel
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
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("␣").font(CaptionType.supporting).opacity(0.6).accessibilityHidden(true)
            }.frame(maxWidth: .infinity).frame(height: 40)
        }.buttonStyle(CaptionSessionButtonStyle(isRunning: model.canStop))
            .disabled(!model.canStart && !model.canStop)
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? CaptionPalette.blue : .clear, lineWidth: 2)
                    .padding(-3).allowsHitTesting(false)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("\(title) · 대화 기록은 유지됩니다. · 스페이스 바")
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
                Text("문장 다듬기").font(CaptionType.section)
                Spacer()
                Text("실험 기능").font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
            }
            Toggle("작은 로컬 모델 사용", isOn: $model.polishEnabled)
                .toggleStyle(.checkbox).font(CaptionType.body)
                .disabled(!store.isInstalled || model.phase != .idle || model.isPreparing || model.hasPendingTranslations || model.isPreview || model.isUISoak)
                .help("빠른 자막을 표시한 뒤 확정 문장만 로컬 모델로 다듬습니다. 변경하려면 먼저 일시정지하세요.")
            Text("빠른 자막을 먼저 표시하고 확정 문장만 보완합니다. 오역이 생길 수 있습니다.")
                .font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
            if store.isInstalled {
                Picker("번역 분야", selection: $model.translationDomain) {
                    Text("일반").tag(TranslationDomain.general)
                    Text("IT").tag(TranslationDomain.it)
                }.pickerStyle(.segmented).controlSize(.large)
                    .disabled(!model.polishEnabled || !model.canChangeSessionSettings)
                    .help("새 대화에서 일반 또는 IT 분야를 선택합니다. IT 분야는 관련 용어를 참고합니다.")
                if model.isPreparingLocalModel { ProgressView().controlSize(.small) }
                if model.polishEnabled {
                    Text(model.localPolishMessage)
                        .font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
                }
            } else if store.isDownloading || store.isVerifying {
                if let progress = store.progress { ProgressView(value: progress).progressViewStyle(.linear) }
                else { ProgressView().controlSize(.small) }
                Text(store.message).font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
                if store.isDownloading {
                    Button("다운로드 취소") { store.cancelDownload() }.controlSize(.large).help("진행 중인 모델 다운로드를 취소합니다.")
                }
            } else {
                Button("모델 다운로드 · 1.47 GB") { store.requestDownload() }
                    .controlSize(.large).disabled(model.phase != .idle || model.isPreparing || model.isPreview || model.isUISoak)
                    .help("선택적 문장 다듬기에 필요한 모델을 한 번 내려받습니다. 약 1.47 GB의 저장 공간과 인터넷 연결이 필요합니다.")
                if !store.message.isEmpty {
                    Text(store.message).font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
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
                Text("\(model.targetDisplayName) 자막").font(CaptionType.section)
                    .help("회색 자막은 수정 중이며 밝은 자막은 현재 원문에 대한 번역이 완료된 상태입니다.")
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
                    }.font(CaptionType.supporting).foregroundStyle(followsLatest ? CaptionPalette.blue : CaptionPalette.secondary)
                }.buttonStyle(.plain).disabled(!model.hasContent)
                    .accessibilityLabel("최신 자막 따라가기")
                    .accessibilityValue(followsLatest ? "켜짐" : "꺼짐")
                    .help(followsLatest ? "새 자막을 따라갑니다. 직접 스크롤하면 따라가기가 멈춥니다." : "최신 자막으로 이동하고 자동 따라가기를 켭니다.")
            }.padding(.horizontal, 34).padding(.top, 12).padding(.bottom, 8)
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
                }.font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
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
        if model.isPreparing { return model.preparationMessage.isEmpty ? "다운로드가 끝나면 자막을 시작할 수 있습니다." : model.preparationMessage }
        if model.isChecking { return "선택한 언어의 음성 인식과 번역을 확인하고 있습니다." }
        if model.isPreparingLocalModel { return "로컬 모델을 불러오고 있습니다. 준비가 끝나면 시작할 수 있습니다." }
        switch model.phase {
        case .starting: return "마이크 접근 권한을 요청하면 허용해 주세요."
        case .listening: return "말씀하신 내용이 \(model.targetDisplayName) 자막으로 여기에 나타납니다."
        case .stopping: return "남은 원문과 번역을 정리하고 있습니다."
        case .idle:
            return model.assetsReady ? "위에서 번역 방향을 선택하고 ‘자막 시작’을 누르세요." :
                "번역 방향을 선택하고 언어 모델을 한 번 준비하세요."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: model.isListening ? "waveform" : "captions.bubble")
                .font(.system(size: 30, weight: .light)).foregroundStyle(CaptionPalette.blue)
                .frame(width: 64, height: 64)
                .background(CaptionPalette.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(CaptionType.body).foregroundStyle(CaptionPalette.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
            if !model.assetsReady && !model.isChecking && !model.isPreparing {
                Button("언어 모델 준비") { model.requestPreparation() }
                    .font(CaptionType.section).padding(.horizontal, 16).frame(height: 40)
                    .buttonStyle(CaptionSessionButtonStyle(isRunning: false))
                    .disabled(model.phase != .idle || model.isPreview || model.isUISoak)
                    .help("선택한 언어의 음성 인식과 번역 모델을 준비합니다. 첫 다운로드에는 인터넷 연결이 필요합니다.")
            }
            if model.isPreparing, let progress = model.preparationProgress {
                VStack(spacing: 8) {
                    ProgressView(value: progress).progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(CaptionType.supporting).monospacedDigit().foregroundStyle(CaptionPalette.secondary)
                }.frame(width: 280).accessibilityLabel("언어 모델 다운로드")
                    .accessibilityValue("\(Int(progress * 100))퍼센트")
            } else if model.isChecking || model.isPreparing || model.isPreparingLocalModel || model.phase == .starting || model.phase == .stopping {
                ProgressView().controlSize(.regular).accessibilityLabel(title)
            }
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
                Text(message).font(CaptionType.body).lineSpacing(4)
                Spacer()
                if model.segments.contains(where: { $0.translationError != nil }) {
                    Button("다시 번역") { model.retryFailedTranslations() }
                        .controlSize(.small)
                        .disabled(model.isPreview || (model.phase != .idle && model.phase != .listening))
                        .help("실패한 원문만 다시 번역합니다. 대화 기록은 유지됩니다.")
                }
                CaptionIconButton("알림 닫기", symbol: "xmark", help: "알림을 닫습니다. 실패한 원문과 번역 기록은 유지됩니다.") {
                    model.message = nil
                }
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

    private var statusText: String {
        if model.isPreview { return "예시 대화" }
        if model.isPreparingLocalModel { return "문장 다듬기 준비 중" }
        if model.phase == .idle && model.hasContent && !model.hasPendingTranslations { return "일시정지" }
        return model.statusText
    }

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(model.isListening ? CaptionPalette.green : CaptionPalette.secondary)
                .frame(width: 7, height: 7).accessibilityHidden(true)
            Text(statusText).font(CaptionType.supporting)
            if !model.isPreview && !model.isUISoak {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.elapsed(at: context.date)).monospacedDigit()
                        .accessibilityLabel("대화 시간").accessibilityValue(model.elapsed(at: context.date))
                }
            }
            Spacer()
            if !model.isUISoak && !model.isPreview && model.queuedTranslations > 0 {
                Text("번역 대기 \(model.queuedTranslations)개")
            }
            if hasTiming {
                CaptionIconButton("처리 시간", symbol: "clock",
                    help: "최근 음성 인식과 번역의 처리 시간을 확인합니다.") { showsTiming.toggle() }
                    .popover(isPresented: $showsTiming, arrowEdge: .top) {
                        timingDetails.padding(22).frame(width: 340).preferredColorScheme(.dark)
                    }
            }
            CaptionSessionButton(model: model).frame(width: 166)
        }.font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary)
            .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var timingDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("최근 처리 시간").font(CaptionType.title)
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
                .font(CaptionType.supporting).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
        }.font(CaptionType.body)
    }
}
