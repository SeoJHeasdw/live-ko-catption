import AppKit
import CaptionCore
import SwiftUI
import Translation

private enum CaptionPalette {
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
    @ViewState private var presentationMode = false
    @ViewState private var followsLatest = true
    @ViewState private var confirmsNewSession = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            HStack(spacing: 0) {
                if !presentationMode {
                    sidebar.frame(width: 252)
                    Rectangle().fill(CaptionPalette.border).frame(width: 1)
                }
                captionArea
            }
            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            footer
        }
        .background(CaptionPalette.background)
        .foregroundStyle(CaptionPalette.ink)
        .preferredColorScheme(.dark)
        .tint(CaptionPalette.blue)
        .frame(minWidth: 950, minHeight: 660)
        .task { await model.checkReadiness() }
        .translationTask(model.translationConfiguration) { session in
            await model.prepareModels(using: session)
        }
        .onAppear { CaptionAppDelegate.model = model }
        .alert("새 대화를 시작할까요?", isPresented: $confirmsNewSession) {
            Button("취소", role: .cancel) {}
            Button("기록 저장 후 새로 시작") {
                if model.exportTranscript() { model.newSession() }
            }
            Button("현재 자막 지우기", role: .destructive) { model.newSession() }
        } message: { Text("현재 자막은 자동 저장되지 않습니다. 필요한 기록은 먼저 저장해 주세요.") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(CaptionPalette.blue)
                .frame(width: 43, height: 43)
                .background(CaptionPalette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("한글 라이브 자막").font(.system(size: 19, weight: .semibold))
                Text("EN  →  KO").font(.system(size: 11, weight: .medium, design: .monospaced))
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
                        if model.isListening { await model.stop() } else { await model.start() }
                    }
                } label: {
                    Label(model.isListening ? "멈추기" : "시작",
                          systemImage: model.isListening ? "pause.fill" : "play.fill")
                }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.canStart && !model.isListening)
                    .keyboardShortcut(.space, modifiers: [])
            }
            Button { presentationMode.toggle() } label: {
                Image(systemName: presentationMode ? "sidebar.left" : "rectangle.expand.vertical")
                    .frame(width: 32, height: 32)
            }.buttonStyle(.plain).help(presentationMode ? "조작 패널 보기" : "자막만 보기")
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 32)
            }.buttonStyle(.plain).help("전체 화면")
        }.padding(.horizontal, 26).padding(.top, 28).padding(.bottom, 23)
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("오디오 입력")
                HStack {
                    Image(systemName: "mic.fill").foregroundStyle(CaptionPalette.blue)
                    Text("마이크").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("마이크 목록 새로고침").disabled(model.phase != .idle)
                }
                Picker("입력 장치", selection: $model.selectedDeviceUID) {
                    Text("시스템 기본 마이크").tag("")
                    ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                }.labelsHidden().pickerStyle(.menu).disabled(model.phase != .idle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    ForEach(0..<26) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Double(index) / 26 < model.audioLevel ? CaptionPalette.green : Color.white.opacity(0.09))
                            .frame(height: 12)
                    }
                }.accessibilityLabel("마이크 입력 크기").accessibilityValue("\(Int(model.audioLevel * 100))퍼센트")
                Text(model.isListening ? "영어 화자 가까이에 마이크를 두세요." : "시작하면 마이크 입력을 확인할 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
            }
            if !model.assetsReady && !model.isChecking {
                setupCard
            }
            Button {
                Task {
                    if model.isListening { await model.stop() } else { await model.start() }
                }
            } label: {
                HStack(spacing: 9) {
                    if model.isBusy && !model.isPreparing { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.isListening ? "pause.fill" : "play.fill") }
                    Text(model.isListening ? "잠시 멈추기" : "자막 시작")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("␣").font(.system(size: 14)).opacity(0.55)
                }.padding(.horizontal, 16).frame(height: 47)
            }.buttonStyle(.plain)
                .background(model.isListening ? Color.white.opacity(0.11) : CaptionPalette.blue.opacity(model.canStart ? 0.88 : 0.18),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(model.canStart ? CaptionPalette.background : CaptionPalette.ink.opacity(model.isListening ? 1 : 0.55))
                .disabled(!model.canStart && !model.isListening)
                .keyboardShortcut(.space, modifiers: [])

            Rectangle().fill(CaptionPalette.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("자막 보기")
                Toggle("영어 원문 함께 보기", isOn: $model.showEnglish).toggleStyle(.checkbox)
                    .font(.system(size: 12))
                HStack {
                    Text("글자 크기").font(.system(size: 12))
                    Spacer()
                    Text("\(Int(model.fontSize))").font(.system(size: 11, design: .monospaced)).foregroundStyle(CaptionPalette.secondary)
                }
                Slider(value: $model.fontSize, in: 24...52, step: 1)
                HStack(spacing: 7) {
                    Circle().fill(CaptionPalette.draft).frame(width: 6, height: 6)
                    Text("회색 자막은 말이 이어지면서 바뀝니다.")
                        .font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary).lineSpacing(4)
                }
            }
            Spacer(minLength: 12)
            VStack(spacing: 12) {
                Button { model.exportTranscript() } label: {
                    Label("원문·자막 저장", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!model.hasContent)
                Button {
                    if model.hasContent { confirmsNewSession = true } else { model.newSession() }
                } label: {
                    Label("새 대화", systemImage: "plus.bubble")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(model.phase != .idle || model.isPreparing)
            }.foregroundStyle(CaptionPalette.secondary)
                }.padding(.horizontal, 23).padding(.vertical, 27)
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }.scrollIndicators(.hidden)
        }.background(CaptionPalette.panel)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("처음 한 번 준비", systemImage: "arrow.down.circle")
                .font(.system(size: 12, weight: .semibold))
            Text(model.isPreparing ? model.preparationMessage : "영어 인식·한국어 번역 모델을 받습니다. 준비 후에는 인터넷 없이 사용할 수 있습니다.")
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

    private var captionArea: some View {
        VStack(spacing: 0) {
            HStack {
                Text("한국어 자막").font(.system(size: 12, weight: .medium)).foregroundStyle(CaptionPalette.secondary)
                Spacer()
                Button { followsLatest.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: followsLatest ? "arrow.down.to.line" : "arrow.down")
                        Text(followsLatest ? "최신 자막 따라가는 중" : "최신 자막 따라가기")
                    }.font(.system(size: 11)).foregroundStyle(followsLatest ? CaptionPalette.blue : CaptionPalette.secondary)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 34).padding(.top, 25).padding(.bottom, 14)
            if let message = model.message {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(message).font(.system(size: 12)).lineSpacing(4)
                    Spacer()
                    if model.segments.contains(where: { $0.translationError != nil }) {
                        Button("다시 번역") { model.retryFailedTranslations() }.controlSize(.small)
                    }
                    Button { model.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(13).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 34).padding(.bottom, 12)
            }
            if model.hasContent {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(model.segments) { segment in
                                captionRow(segment)
                            }
                            Color.clear.frame(height: 10).id("caption-end")
                        }.padding(.horizontal, 34).padding(.top, 13).padding(.bottom, 25)
                    }
                    .onChange(of: model.segments) {
                        if followsLatest { proxy.scrollTo("caption-end", anchor: .bottom) }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { followsLatest = false }
                    }
                }
            } else {
                VStack(spacing: 17) {
                    Spacer()
                    Image(systemName: "waveform").font(.system(size: 39, weight: .light))
                        .foregroundStyle(CaptionPalette.blue.opacity(0.55))
                    Text("영어를 듣고, 한글로 함께 읽습니다.")
                        .font(.system(size: 23, weight: .medium))
                    Text(model.assetsReady ? "마이크를 선택하고 ‘자막 시작’을 눌러 주세요." : "왼쪽에서 언어 모델을 준비한 뒤 시작해 주세요.")
                        .font(.system(size: 13)).foregroundStyle(CaptionPalette.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity).padding(.bottom, 40)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func captionRow(_ segment: CaptionSegment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(String(format: "%02d:%02d", Int(segment.audioStart) / 60, Int(segment.audioStart) % 60))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                if !segment.isFinal {
                    Text(segment.translationError == nil ? "이어지는 중" : "번역 확인 필요")
                        .font(.system(size: 10))
                }
            }.foregroundStyle(CaptionPalette.secondary.opacity(0.8))
            Text(segment.translation ?? "한국어 자막을 준비하고 있습니다…")
                .font(.system(size: model.fontSize, weight: segment.isFinal ? .medium : .regular))
                .foregroundStyle(segment.isFinal ? CaptionPalette.ink : CaptionPalette.draft)
                .lineSpacing(8).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if model.showEnglish {
                Text(segment.source).font(.system(size: 14))
                    .foregroundStyle(CaptionPalette.secondary.opacity(segment.isFinal ? 0.9 : 0.7))
                    .lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).id(segment.id)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Label("이 Mac에서 처리", systemImage: "desktopcomputer")
                .foregroundStyle(CaptionPalette.green.opacity(0.9))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.elapsed(at: context.date)).monospacedDigit().foregroundStyle(CaptionPalette.secondary)
            }
            Spacer()
            if let delay = model.speechDelaySeconds {
                Text("인식 지연 약 \(delay, specifier: "%.1f")초")
                    .help("오디오의 끝 시점부터 인식 결과가 도착할 때까지의 추정 시간입니다. 번역 지연과는 별개입니다.")
            }
            if let elapsed = model.translationMilliseconds {
                Text("최근 번역 \(elapsed / 1000, specifier: "%.2f")초")
                    .help("마지막 번역 호출에 걸린 시간입니다. 전체 자막 지연은 아닙니다.")
            }
            if model.queuedTranslations > 0 { Text("번역 대기 \(model.queuedTranslations)개") }
        }.font(.system(size: 11)).foregroundStyle(CaptionPalette.secondary)
            .padding(.horizontal, 26).frame(height: 41)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CaptionPalette.secondary)
    }
}
