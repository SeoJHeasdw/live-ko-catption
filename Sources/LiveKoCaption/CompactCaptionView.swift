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

    private var controlsVisible: Bool {
        isHovered || !model.isListening || model.message != nil
    }

    var body: some View {
        HStack(spacing: 10) {
            CompactWindowDragArea()
                .overlay(alignment: .leading) {
                    HStack(spacing: 7) {
                        Circle().fill(model.isListening ? CaptionPalette.green : CaptionPalette.secondary)
                            .frame(width: 5, height: 5)
                        Text(model.isPreview ? "예시 대화 · 화면 미리보기" :
                            model.isUISoak ? "합성 자막 · 화면 검사" :
                            model.phase == .idle && model.assetsReady ? "듣기 멈춤" : model.statusText)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1).foregroundStyle(.white.opacity(0.50))
                    }.allowsHitTesting(false)
                }
                .help("이 영역을 드래그해 자막 창을 옮길 수 있습니다.")
            if model.message != nil {
                Button { windows.showDetailed() } label: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }.buttonStyle(.plain).help(model.message ?? "자막 알림 확인")
                    .accessibilityLabel("자막 알림 · 자세히 보기")
            }
            HStack(spacing: 5) {
                control("자세히 보기", symbol: "plus", shortcut: nil) { windows.showDetailed() }
                control(model.phase == .starting ? "시작 취소" : model.canStop ? "일시정지" : "자막 재개",
                    symbol: model.canStop ? "pause.fill" : "play.fill", shortcut: .space) {
                    Task { await windows.pauseOrResume() }
                }.disabled(!model.canStart && !model.canStop)
                control("중지하고 자세히 보기", symbol: "stop.fill", shortcut: nil) {
                    Task { await windows.stopAndShowDetailed() }
                }
            }
            // Keep the hit regions stable as the pointer crosses the header.
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
        }
    }

    private func control(_ title: String, symbol: String, shortcut: KeyEquivalent?,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86)).frame(width: 30, height: 28)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: []) })
    }
}

private struct CompactCaptionText: View {
    let model: CaptionModel
    let availableHeight: CGFloat

    var body: some View {
        let fontSize = min(model.fontSize, max(24, Double(availableHeight - 14) / 2.5))
        let lineHeight = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: fontSize))
        NativeCompactCaption(segments: model.recentDisplaySegments(limit: 2), fontSize: fontSize)
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
