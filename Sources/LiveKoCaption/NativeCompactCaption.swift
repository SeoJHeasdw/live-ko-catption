import AppKit
import CaptionCore
import SwiftUI

/// The caller supplies a fixed viewport. Native text layout can grow inside it,
/// but its document height never becomes a SwiftUI or window-size preference.
struct NativeCompactCaption: NSViewRepresentable {
    var segments: [CaptionSegment]
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CompactCaptionScrollView {
        let scroll = CompactCaptionScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        // Use the same explicit TextKit 1 layout as the stable detail renderer.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0,
            height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let text = CompactCaptionTextView(frame: scroll.contentView.bounds,
            textContainer: container)
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.setAccessibilityLabel("간략 한국어 실시간 자막")
        scroll.documentView = text
        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ view: CompactCaptionScrollView, context: Context) {
        context.coordinator.submit(.init(segments: Array(segments.suffix(2)),
            fontSize: fontSize.isFinite ? min(52, max(24, fontSize)) : 35))
    }

    static func dismantleNSView(_ view: CompactCaptionScrollView, coordinator: Coordinator) {
        view.viewportDidResize = nil
        coordinator.cancel()
    }

    struct Snapshot: Equatable {
        var segments: [CaptionSegment]
        var fontSize: Double
    }

    @MainActor
    final class Coordinator {
        private weak var scroll: CompactCaptionScrollView?
        private weak var text: CompactCaptionTextView?
        private var rendered: Snapshot?
        private var pending: Snapshot?
        private var renderTask: Task<Void, Never>?
        private var needsTailScroll = false

        func attach(scroll: CompactCaptionScrollView, text: CompactCaptionTextView) {
            self.scroll = scroll
            self.text = text
            scroll.viewportDidResize = { [weak self] in
                self?.needsTailScroll = true
                self?.scheduleRender()
            }
        }

        func submit(_ snapshot: Snapshot) {
            pending = snapshot == rendered ? nil : snapshot
            scheduleRender()
        }

        private func scheduleRender() {
            guard (pending != nil || needsTailScroll), renderTask == nil else { return }
            // Keep only the latest revision and one trailing update. A burst of
            // partial results or a live resize cannot build a queue of UI work.
            renderTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.renderTask = nil
                self.renderLatest()
            }
        }

        func cancel() {
            renderTask?.cancel()
            renderTask = nil
            pending = nil
            needsTailScroll = false
        }

        private func renderLatest() {
            guard let scroll, let text, let storage = text.textStorage else { return }
            if let next = pending {
                pending = nil
                let selection = text.selectedRange()
                storage.setAttributedString(Self.attributedText(next))
                rendered = next
                if selection.location != NSNotFound {
                    let location = min(selection.location, storage.length)
                    text.setSelectedRange(NSRange(location: location,
                        length: min(selection.length, storage.length - location)))
                }
            }
            needsTailScroll = false
            // Finish native wrapping before moving to the newest words. This
            // also runs after a resize when no new caption revision arrives.
            scroll.layoutSubtreeIfNeeded()
            if let layout = text.layoutManager, let container = text.textContainer {
                layout.ensureLayout(for: container)
            }
            text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }

        private static func attributedText(_ snapshot: Snapshot) -> NSAttributedString {
            let ink = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1)
            let draft = NSColor(calibratedRed: 0.59, green: 0.63, blue: 0.69, alpha: 1)
            let error = NSColor(calibratedRed: 1, green: 0.69, blue: 0.38, alpha: 1)
            var rows: [(String, NSColor, NSFont.Weight)] = []
            for segment in snapshot.segments {
                if segment.translationError != nil {
                    rows.append(("번역 실패 · 자세히 보기에서 원문을 확인해 주세요.", error, .regular))
                } else if let translation = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !translation.isEmpty {
                    rows.append((translation, segment.isFinal ? ink : draft,
                        segment.isFinal ? .medium : .regular))
                }
                // A new untranslated phrase must not displace the previous
                // readable caption with an unnecessary waiting placeholder.
            }
            if rows.isEmpty {
                rows.append((snapshot.segments.isEmpty
                    ? "영어를 들으면 한국어 자막이 여기에 표시됩니다."
                    : "한국어 자막을 준비하고 있습니다…", draft, .regular))
            }
            let result = NSMutableAttributedString(string: "")
            for (index, row) in rows.enumerated() {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                paragraph.paragraphSpacing = 0
                result.append(NSAttributedString(string: row.0 + (index < rows.count - 1 ? "\n" : ""),
                    attributes: [.font: NSFont.systemFont(ofSize: snapshot.fontSize, weight: row.2),
                        .foregroundColor: row.1, .paragraphStyle: paragraph]))
            }
            return result
        }
    }
}

@MainActor
final class CompactCaptionScrollView: NSScrollView {
    var viewportDidResize: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // This viewport always follows live captions. History browsing belongs
        // to the detail window, while native text selection remains available.
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { viewportDidResize?() }
    }
}

/// The subclass gives synthetic QA a passive, direct view of rendered text.
/// Inspection never observes layout or triggers model/window updates.
@MainActor
final class CompactCaptionTextView: NSTextView {
    var renderedCaptionText: String { string }
}
