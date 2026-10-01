import AppKit
import CaptionCore
import SwiftUI

/// The caller supplies a fixed viewport. Native text layout can grow inside it,
/// but its document height never becomes a SwiftUI or window-size preference.
struct NativeCompactCaption: NSViewRepresentable {
    var segments: [CaptionSegment]
    var fontSize: Double
    var targetLanguageName = "한국어"

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
        text.setAccessibilityLabel("간략 실시간 번역 자막")
        scroll.documentView = text
        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ view: CompactCaptionScrollView, context: Context) {
        context.coordinator.submit(.init(segments: Array(segments.suffix(2)),
            fontSize: fontSize.isFinite ? min(52, max(24, fontSize)) : 35,
            targetLanguageName: targetLanguageName))
    }

    static func dismantleNSView(_ view: CompactCaptionScrollView, coordinator: Coordinator) {
        view.viewportDidResize = nil
        coordinator.cancel()
    }

    struct Snapshot: Equatable {
        var segments: [CaptionSegment]
        var fontSize: Double
        var targetLanguageName: String
    }

    @MainActor
    final class Coordinator {
        private weak var scroll: CompactCaptionScrollView?
        private weak var text: CompactCaptionTextView?
        private var rendered: Snapshot?
        private var pending: Snapshot?
        private var renderTask: Task<Void, Never>?
        private var needsTailScroll = false
        private var renderedRows: [RenderRow] = []
        private var lastRender: TimeInterval = 0
        /// Native updates never run more often than this, but a caption that
        /// arrives after a quiet interval is not held back by a fixed delay.
        static let renderInterval: TimeInterval = 1.0 / 30

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
            let delay = lastRender + Self.renderInterval - ProcessInfo.processInfo.systemUptime
            renderTask = Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
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
            lastRender = ProcessInfo.processInfo.systemUptime
            var shouldScroll = needsTailScroll
            if let next = pending {
                pending = nil
                let selection = text.selectedRange()
                let rows = Self.rows(next)
                shouldScroll = shouldScroll || rendered?.fontSize != next.fontSize ||
                    rows.map(\.text) != renderedRows.map(\.text) ||
                    rows.map { $0.state == .final } != renderedRows.map { $0.state == .final }
                var commonRows = 0
                if rendered?.fontSize == next.fontSize {
                    while commonRows < min(rows.count, renderedRows.count),
                          rows[commonRows] == renderedRows[commonRows],
                          (commonRows < rows.count - 1) == (commonRows < renderedRows.count - 1) {
                        commonRows += 1
                    }
                }
                let offset = renderedRows.prefix(commonRows).enumerated().reduce(0) { total, item in
                    total + item.element.text.utf16.count + (item.offset < renderedRows.count - 1 ? 1 : 0)
                }
                let replacement = Self.attributedText(rows, from: commonRows, fontSize: next.fontSize)
                if offset < storage.length || replacement.length > 0 {
                    // Retain the readable earlier row rather than replacing the
                    // whole document for every revision of the next phrase.
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: offset, length: storage.length - offset),
                        with: replacement)
                    storage.endEditing()
                }
                renderedRows = rows
                rendered = next
                if selection.location != NSNotFound {
                    let location = min(selection.location, storage.length)
                    text.setSelectedRange(NSRange(location: location,
                        length: min(selection.length, storage.length - location)))
                }
            }
            needsTailScroll = false
            guard shouldScroll else { return }
            // Finish native wrapping before moving to the newest words. This
            // also runs after a resize when no new caption revision arrives.
            scroll.layoutSubtreeIfNeeded()
            if let layout = text.layoutManager, let container = text.textContainer {
                layout.ensureLayout(for: container)
                let lastCharacter = (text.string as NSString).rangeOfCharacter(
                    from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
                if lastCharacter.location != NSNotFound, scroll.contentView.bounds.height > 0,
                   layout.numberOfGlyphs > 0 {
                    let lastGlyph = layout.glyphIndexForCharacter(at: lastCharacter.location)
                    let lastLine = layout.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
                    let origin = text.textContainerOrigin
                    let height = scroll.contentView.bounds.height
                    let minimumTop = max(0, lastLine.maxY + origin.y - height)
                    let firstGlyph = min(layout.glyphIndex(
                        for: NSPoint(x: 0, y: max(0, minimumTop - origin.y)), in: container), layout.numberOfGlyphs - 1)
                    var lineRange = NSRange()
                    let firstLine = layout.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: &lineRange)
                    var top = max(0, firstLine.minY + origin.y)
                    if top < minimumTop - 0.5, NSMaxRange(lineRange) < layout.numberOfGlyphs {
                        top = layout.lineFragmentRect(forGlyphAt: NSMaxRange(lineRange), effectiveRange: nil).minY + origin.y
                    }
                    // Native bottom padding lets the viewport begin on a whole
                    // line while the newest line remains completely visible.
                    // Document sizing stays inside this fixed scroll viewport.
                    let naturalHeight = layout.usedRect(for: container).maxY + origin.y + text.textContainerInset.height
                    text.setFrameSize(NSSize(width: text.frame.width, height: max(naturalHeight, top + height)))
                    var bounds = scroll.contentView.bounds
                    bounds.origin.y = top
                    scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    return
                }
            }
            text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }

        private enum RowState: Equatable { case final, provisional, error }
        private struct RenderRow: Equatable {
            var id: UUID?
            var text: String
            var state: RowState
        }

        private static func rows(_ snapshot: Snapshot) -> [RenderRow] {
            var rows: [RenderRow] = []
            for segment in snapshot.segments {
                if segment.translationError != nil {
                    rows.append(.init(id: segment.id, text: "번역 실패 · 상세 보기에서 원문을 확인해 주세요.", state: .error))
                } else if let translation = segment.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !translation.isEmpty {
                    rows.append(.init(id: segment.id, text: translation,
                        state: segment.isFinal ? .final : .provisional))
                }
                // An untranslated phrase retains the previous readable caption.
            }
            if rows.isEmpty {
                rows.append(.init(id: nil, text: snapshot.segments.isEmpty
                    ? "말하면 \(snapshot.targetLanguageName) 자막이 여기에 표시됩니다."
                    : "\(snapshot.targetLanguageName) 자막을 준비하고 있습니다…", state: .provisional))
            }
            return rows
        }

        private static func attributedText(_ rows: [RenderRow], from start: Int, fontSize: Double) -> NSAttributedString {
            let ink = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1)
            let draft = NSColor(calibratedRed: 0.59, green: 0.63, blue: 0.69, alpha: 1)
            let error = NSColor(calibratedRed: 1, green: 0.69, blue: 0.38, alpha: 1)
            let result = NSMutableAttributedString(string: "")
            for index in start..<rows.count {
                let row = rows[index]
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                paragraph.paragraphSpacing = 0
                paragraph.lineBreakStrategy = .hangulWordPriority
                result.append(NSAttributedString(string: row.text + (index < rows.count - 1 ? "\n" : ""),
                    attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: row.state == .final ? .medium : .regular),
                        .foregroundColor: row.state == .final ? ink : row.state == .error ? error : draft,
                        .paragraphStyle: paragraph]))
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
