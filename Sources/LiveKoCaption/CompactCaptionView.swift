import AppKit
import SwiftUI

struct CompactCaptionView: View {
    let model: CaptionModel
    let windows: CaptionWindowCoordinator
    @ViewState private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                CompactCaptionHeader(model: model, windows: windows, isHovered: isHovered)
                    .frame(height: 30)
                CompactCaptionText(model: model, availableHeight: geometry.size.height - 72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 18)
        }
        .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color.white.opacity(isHovered ? 0.25 : 0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10)).rotationEffect(.degrees(-45))
                .foregroundStyle(.white.opacity(isHovered ? 0.45 : 0.18))
                .padding(8).allowsHitTesting(false).accessibilityHidden(true)
        }
        .overlay { CompactWindowResizeEdges() }
        .onHover { isHovered = $0 }
        .preferredColorScheme(.dark)
        .frame(minWidth: 420, minHeight: 144)
    }
}

private struct CompactCaptionHeader: View {
    let model: CaptionModel
    let windows: CaptionWindowCoordinator
    let isHovered: Bool
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var controlsVisible: Bool {
        isHovered || controlActiveState == .key || voiceOverEnabled || !model.isListening || model.message != nil
    }

    private var statusText: String {
        if model.isPreview { return "예시 대화 · 미리보기" }
        if model.isUISoak { return "합성 자막 · 화면 검사" }
        if model.isPreparingLocalModel { return "문장 보완 준비 중" }
        if model.phase == .idle && model.hasContent && !model.hasPendingTranslations { return "일시정지" }
        return model.statusText
    }

    private var controlTitle: String {
        switch model.phase {
        case .starting: return "시작 취소"
        case .listening: return "일시정지"
        case .stopping: return "마지막 자막 정리 중"
        case .idle: return model.hasContent ? "자막 재개" : "자막 시작"
        }
    }

    private var controlSymbol: String {
        model.phase == .starting ? "xmark" : model.canStop ? "pause.fill" : "play.fill"
    }

    private var controlHelp: String {
        switch model.phase {
        case .starting: return "마이크와 음성 인식 준비를 취소합니다."
        case .listening: return "마이크 입력을 일시정지하고 마지막 자막을 정리합니다. 대화 기록은 유지됩니다."
        case .stopping: return "마지막 음성의 자막을 정리하고 있습니다. 완료되면 다시 시작할 수 있습니다."
        case .idle: return model.hasContent ? "현재 대화에 이어서 마이크 자막을 재개합니다." : "선택한 번역 방향으로 마이크 자막을 시작합니다."
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            CompactWindowDragArea()
                .overlay(alignment: .leading) {
                    HStack(spacing: 7) {
                        Circle().fill(model.isListening ? CaptionPalette.green : CaptionPalette.secondary)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(statusText)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1).foregroundStyle(.white.opacity(0.72))
                    }.allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("자막 상태")
                        .accessibilityValue(statusText)
                }
                .help("\(statusText) · 이 영역을 드래그해 자막 창을 옮길 수 있습니다.")
            if model.message != nil {
                control("자막 알림 확인", symbol: "exclamationmark.circle.fill", shortcut: nil,
                    help: "\(model.message ?? "자막 알림 확인") 상세 창에서 알림을 확인합니다.",
                    shortcutHint: "⌘1", tint: .orange) { windows.showDetailed() }
                    .accessibilityValue(model.message ?? "")
            }
            HStack(spacing: 5) {
                control("상세 보기", symbol: "arrow.up.left.and.arrow.down.right", shortcut: nil,
                    help: "원문, 기록 저장과 설정이 있는 상세 창으로 돌아갑니다. 자막은 계속 진행됩니다.",
                    shortcutHint: "⌘1") { windows.showDetailed() }
                control(controlTitle, symbol: controlSymbol, shortcut: .space,
                    help: controlHelp, shortcutHint: "스페이스 바") {
                    Task { await windows.pauseOrResume() }
                }.disabled(!model.canStart && !model.canStop)
                control("일시정지하고 상세 보기", symbol: "stop.fill", shortcut: nil,
                    help: "상세 창으로 돌아가며 마이크 입력을 일시정지합니다. 대화 기록은 유지됩니다.",
                    shortcutHint: "⌘.") {
                    Task { await windows.stopAndShowDetailed() }
                }
            }
            // Keep the hit regions stable as the pointer crosses the header.
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
        }
    }

    private func control(_ title: String, symbol: String, shortcut: KeyEquivalent?, help: String,
                         shortcutHint: String? = nil, tint: Color = .white,
                         action: @escaping () -> Void) -> some View {
        CompactCaptionControl(title: title, symbol: symbol, help: help, tint: tint, action: action)
            .help(shortcutHint.map { "\(title) · \($0)\n\(help)" } ?? "\(title)\n\(help)")
            .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: []) })
    }
}

private struct CompactCaptionControl: View {
    let title: String
    let symbol: String
    let help: String
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false
    @SwiftUI.FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint.opacity(isEnabled ? 0.92 : 0.35)).frame(width: 32, height: 28)
                .background(.white.opacity(isEnabled && isHovered ? 0.18 : 0.09),
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isFocused ? CaptionPalette.blue : .clear, lineWidth: 2)
                    .padding(-2).allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .accessibilityLabel(title)
            .accessibilityHint(help)
    }
}

private struct CompactCaptionText: View {
    let model: CaptionModel
    let availableHeight: CGFloat

    var body: some View {
        let fontSize = min(model.fontSize, max(24, Double(availableHeight - 14) / 2.5))
        let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: fontSize))
        NativeCompactCaption(segments: model.recentDisplaySegments(limit: 2), fontSize: fontSize,
            targetLanguageName: model.targetDisplayName)
            .frame(height: min(availableHeight, ceil(lineHeight * 2 + 13)))
    }
}

private struct CompactWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// Borderless panels need explicit edge hit regions. The center passes through
/// to caption selection and buttons; resizing never drives a text intrinsic size.
private struct CompactWindowResizeEdges: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {}

    final class ResizeView: NSView {
        private let edge: CGFloat = 7
        private var startFrame = NSRect.zero
        private var startPoint = NSPoint.zero
        private var activeEdges: Edges = []
        private struct Edges: OptionSet {
            let rawValue: Int
            static let left = Edges(rawValue: 1)
            static let right = Edges(rawValue: 2)
            static let bottom = Edges(rawValue: 4)
            static let top = Edges(rawValue: 8)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) && !edges(at: local).isEmpty ? self : nil
        }
        private func edges(at point: NSPoint) -> Edges {
            var result: Edges = []
            if point.x <= edge { result.insert(.left) }
            if point.x >= bounds.width - edge { result.insert(.right) }
            if point.y <= edge { result.insert(.bottom) }
            if point.y >= bounds.height - edge { result.insert(.top) }
            return result
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startFrame = window.frame
            startPoint = window.convertPoint(toScreen: event.locationInWindow)
            activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, !activeEdges.isEmpty else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - startPoint.x, dy = point.y - startPoint.y
            var frame = startFrame
            if activeEdges.contains(.left) {
                frame.size.width = max(window.minSize.width, startFrame.width - dx)
                frame.origin.x = startFrame.maxX - frame.width
            } else if activeEdges.contains(.right) {
                frame.size.width = max(window.minSize.width, startFrame.width + dx)
            }
            if activeEdges.contains(.bottom) {
                frame.size.height = max(window.minSize.height, startFrame.height - dy)
                frame.origin.y = startFrame.maxY - frame.height
            } else if activeEdges.contains(.top) {
                frame.size.height = max(window.minSize.height, startFrame.height + dy)
            }
            window.setFrame(frame, display: true)
        }
        override func mouseUp(with event: NSEvent) {
            activeEdges = []
            window?.saveFrame(usingName: "CompactCaptionPanel")
        }
        override func resetCursorRects() {
            let w = bounds.width, h = bounds.height, e = edge
            let regions: [(NSRect, NSCursor.FrameResizePosition)] = [
                (NSRect(x: e, y: 0, width: w - 2 * e, height: e), .bottom),
                (NSRect(x: e, y: h - e, width: w - 2 * e, height: e), .top),
                (NSRect(x: 0, y: e, width: e, height: h - 2 * e), .left),
                (NSRect(x: w - e, y: e, width: e, height: h - 2 * e), .right),
                (NSRect(x: 0, y: 0, width: e, height: e), .bottomLeft),
                (NSRect(x: w - e, y: 0, width: e, height: e), .bottomRight),
                (NSRect(x: 0, y: h - e, width: e, height: e), .topLeft),
                (NSRect(x: w - e, y: h - e, width: e, height: e), .topRight)
            ]
            for (rect, position) in regions {
                addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
            }
        }
    }
}
