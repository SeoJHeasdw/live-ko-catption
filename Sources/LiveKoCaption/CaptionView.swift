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
                    CaptionSidebar(model: model) { confirmsNewSession = true }.frame(width: 252)
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
            Button("기록 저장 후 새로 시작") {
                if model.exportTranscript() { model.newSession() }
            }
            Button("현재 자막 지우기", role: .destructive) { model.newSession() }
        } message: { Text("현재 자막은 자동 저장되지 않습니다. 필요한 기록은 먼저 저장해 주세요.") }
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
                Text("한글 라이브 자막").font(.system(size: 19, weight: .semibold))
                Text(model.directionLabel).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CaptionPalette.secondary)
            }
            Spacer()
            if model.isPreview {
                Label("예시 대화 · 화면 미리보기", systemImage: "eye")
                    .font(.system(size: 12)).foregroundStyle(CaptionPalette.blue)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(CaptionPalette.blue.opacity(0.08), in: Capsule())
            } else {
                Circle().fill(model.isListening ? CaptionPalette.green : CaptionPalette.secondary)
                    .frame(width: 7, height: 7)
                Text(model.statusText).font(.system(size: 12)).foregroundStyle(CaptionPalette.secondary)
            }
            if presentationMode {
                Button {
                    Task {
                        if model.canStop { await model.stop() } else { await model.start() }
                    }
                } label: {
                    Label(model.phase == .starting ? "시작 취소" : model.isListening ? "멈추기" : "시작",
                          systemImage: model.canStop ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.canStart && !model.canStop)
                    .keyboardShortcut(.space, modifiers: [])
            }
            Button { windows.showCompact() } label: {
                Label("간략히 보기", systemImage: "pip")
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
        }.padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 23)
    }

}

private struct CaptionSidebar: View {
    @Bindable var model: CaptionModel
    var requestNewSession: () -> Void
    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("번역 방향")
                Picker("번역 방향", selection: $model.selectedDirection) {
                    Text("영어 → 한국어").tag(CaptionDirection.englishToKorean)
                    Text("한국어 → 영어").tag(CaptionDirection.koreanToEnglish)
                }.pickerStyle(.radioGroup).labelsHidden().font(.system(size: 12))
                    .disabled(!model.canChangeSessionSettings)
                if model.hasContent {
                    Text("방향을 바꾸려면 기록을 저장한 뒤 새 대화를 시작하세요.")
                        .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
                }
            }
            LocalPolishControls(model: model, store: LocalModelStore.shared)
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("오디오 입력")
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(CaptionPalette.blue)
                    Text("마이크").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel("마이크 목록 새로고침")
                        .help("마이크 목록 새로고침").disabled(model.phase != .idle)
                }
                Picker("입력 장치", selection: $model.selectedDeviceUID) {
                    Text("시스템 기본 마이크").tag("")
                    ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                    if !model.selectedDeviceUID.isEmpty && !model.devices.contains(where: { $0.uid == model.selectedDeviceUID }) {
                        Text("저장된 마이크 · 연결 안 됨").tag(model.selectedDeviceUID)
                    }
                }.labelsHidden().pickerStyle(.menu).disabled(model.phase != .idle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CaptionAudioMeter(model: model)
                Text(model.isListening ? "\(model.sourceDisplayName) 화자 가까이에 마이크를 두세요." : "시작하면 마이크 입력을 확인할 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
            }
            if !model.assetsReady && !model.isChecking {
                setupCard
            }
            Button {
                Task {
                    if model.canStop { await model.stop() } else { await model.start() }
                }
            } label: {
                HStack(spacing: 9) {
                    if model.isBusy && !model.isPreparing { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isListening ? "pause.fill" : "play.fill") }
                    Text(model.phase == .starting ? "시작 취소" : model.isListening ? "잠시 멈추기" : "자막 시작")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("␣").font(.system(size: 14)).opacity(0.55)
                }.padding(.horizontal, 16).frame(height: 47)
            }.buttonStyle(.plain)
                .background(model.canStop ? Color.white.opacity(0.11) : CaptionPalette.blue.opacity(model.canStart ? 0.88 : 0.18),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(model.canStart ? CaptionPalette.background : CaptionPalette.ink.opacity(model.canStop ? 1 : 0.55))
                .disabled(!model.canStart && !model.canStop)
                .keyboardShortcut(.space, modifiers: [])

            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("자막 보기")
                Toggle("\(model.sourceDisplayName) 원문 함께 보기", isOn: $model.showEnglish).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Toggle("최근 구절을 문맥으로 함께 번역", isOn: $model.contextCorrectionEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(model.phase != .idle)
                    .help("최근 인접한 구절을 제한된 묶음으로 번역합니다. 이어지는 말에 따라 최근 자막이 회색으로 돌아가 수정될 수 있습니다. 번역의 정확성을 보장하지는 않습니다.")
                HStack {
                    Text("글자 크기").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.fontSize))").font(.system(size: 11, design: .monospaced)).foregroundStyle(CaptionPalette.secondary)
                }
                Slider(value: $model.fontSize, in: 24...52, step: 1)
                HStack(spacing: 7) {
                    Circle().fill(CaptionPalette.draft).frame(width: 6, height: 6)
                    Text("회색 자막은 생성·수정 중입니다.")
                        .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
                }
                Text("진한 자막도 번역 의미가 검증된 것은 아닙니다. 숫자·부정·이름·전문 용어는 원문을 함께 확인해 주세요.")
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
            }
            Spacer(minLength: 12)
            VStack(spacing: 12) {
                Button { model.exportTranscript() } label: {
                    Label("원문·자막 저장", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!model.hasContent)
                Button {
                    if model.hasContent { requestNewSession() } else { model.newSession() }
                } label: {
                    Label("새 대화", systemImage: "plus.bubble")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(model.phase != .idle || model.isPreparing)
            }.foregroundStyle(CaptionPalette.secondary)
                }.padding(.horizontal, 23).padding(.vertical, 27)
        }.scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(CaptionPalette.panel)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("처음 한 번 준비", systemImage: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(model.isPreparing ? model.preparationMessage : "\(model.sourceDisplayName) 음성 인식·\(model.targetDisplayName) 번역을 준비합니다. 준비 후에는 인터넷 없이 사용할 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
            if model.isPreparing {
                if let progress = model.preparationProgress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else { ProgressView().controlSize(.small) }
            } else {
                Button("언어 모델 준비") { model.requestPreparation() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(13).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CaptionPalette.secondary)
    }
}

private struct LocalPolishControls: View {
    @Bindable var model: CaptionModel
    @Bindable var store: LocalModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("번역 보완").font(.system(size: 11, weight: .semibold)).foregroundStyle(CaptionPalette.secondary)
            Toggle("작은 모델로 문장 다듬기", isOn: $model.polishEnabled)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .disabled(!store.isInstalled || model.phase != .idle || model.isPreparing || model.isPreview || model.isUISoak)
            if store.isInstalled {
                Picker("분야", selection: $model.translationDomain) {
                    Text("일반").tag(TranslationDomain.general)
                    Text("IT").tag(TranslationDomain.it)
                }.pickerStyle(.segmented).font(.system(size: 11))
                    .disabled(!model.polishEnabled || !model.canChangeSessionSettings)
                if model.isPreparingLocalModel { ProgressView().controlSize(.small) }
                Text(model.polishEnabled ? model.localPolishMessage : "빠른 자막은 그대로, 확정할 문장만 보완합니다.")
                    .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
                Text("시험 기능 · 오역이 생길 수 있어요. 어색하면 보완을 끄고 빠른 번역을 사용하세요.")
                    .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary).lineSpacing(3)
            } else if store.isDownloading || store.isVerifying {
                if let progress = store.progress { ProgressView(value: progress).progressViewStyle(.linear) }
                else { ProgressView().controlSize(.small) }
                Text(store.message).font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
                if store.isDownloading {
                    Button("다운로드 취소") { store.cancelDownload() }.controlSize(.small)
                }
            } else {
                Button("보완 모델 다운로드 · 1.47 GB") { store.requestDownload() }
                    .controlSize(.small).disabled(model.phase != .idle || model.isPreparing)
                Text("처음 한 번 준비 후 이 Mac에서 실행합니다.")
                    .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
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
                Text("\(model.targetDisplayName) 자막").font(.system(size: 12, weight: .medium)).foregroundStyle(CaptionPalette.secondary)
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
                        Text(followsLatest ? "최신 자막 따라가는 중" : "최신 자막 따라가기")
                    }.font(.system(size: 11)).foregroundStyle(followsLatest ? CaptionPalette.blue : CaptionPalette.secondary)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 34).padding(.top, 25).padding(.bottom, 14)
            CaptionMessage(model: model)
            if model.hasContent {
                NativeCaptionTranscript(segments: model.recentDisplaySegments(limit: visibleLimit),
                    fontSize: model.fontSize, showEnglish: model.showEnglish,
                    isIdle: model.phase == .idle && !model.isPreview, followsLatest: $followsLatest,
                    accessibilityLabel: "\(model.targetDisplayName) 실시간 자막과 \(model.sourceDisplayName) 원문")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("화면에는 최근 100개 자막을 표시합니다. 전체 대화는 ‘원문·자막 저장’으로 보관할 수 있습니다.")
                    .font(.system(size: 10)).foregroundStyle(CaptionPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34).padding(.vertical, 8)
            } else {
                VStack(spacing: 17) {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 39, weight: .light))
                        .foregroundStyle(CaptionPalette.blue.opacity(0.55))
                    Text("\(model.sourceDisplayName)를 듣고, \(model.targetDisplayName)로 함께 읽습니다.").font(.system(size: 23, weight: .medium))
                    Text(model.assetsReady ? "마이크를 선택하고 ‘자막 시작’을 눌러 주세요." : "왼쪽에서 언어 모델을 준비한 뒤 시작해 주세요.")
                        .font(.system(size: 13)).foregroundStyle(CaptionPalette.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity).padding(.bottom, 40)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var body: some View {
        HStack(spacing: 18) {
            Label("이 Mac에서 처리", systemImage: "desktopcomputer")
                .foregroundStyle(CaptionPalette.green.opacity(0.9))
            if model.isUISoak {
                Text("화면 안정성 검사 · 합성 입력")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(model.elapsed(at: context.date)).monospacedDigit().foregroundStyle(CaptionPalette.secondary)
                }
            }
            Spacer()
            if !model.isUISoak {
            if let delay = model.captionDelaySeconds {
                Text("자막 도착 약 \(delay, specifier: "%.1f")초")
                    .help("이 자막에 대응하는 음성 구간의 끝부터 현재 한국어 번역이 화면에 반영될 때까지의 추정 시간입니다. 마이크 하드웨어 지연은 포함하지 않습니다.")
            }
            if let delay = model.speechDelaySeconds {
                Text("인식 지연 약 \(delay, specifier: "%.1f")초")
                    .help("오디오의 끝 시점부터 인식 결과가 도착할 때까지의 추정 시간입니다. 번역 지연과는 별개입니다.")
            }
            if let elapsed = model.translationMilliseconds {
                Text("최근 번역 \(elapsed / 1000, specifier: "%.2f")초")
                    .help("마지막 번역 호출에 걸린 시간입니다. 전체 자막 지연은 아닙니다.")
            }
            if model.queuedTranslations > 0 { Text("번역 대기 \(model.queuedTranslations)개") }
            else if model.hasPendingTranslations { Text("번역 중") }
            }
        }.font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
            .padding(.horizontal, 26).frame(height: 41)
    }

}
