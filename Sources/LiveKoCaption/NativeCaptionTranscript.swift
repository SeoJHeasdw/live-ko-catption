import AppKit
import CaptionCore
import SwiftUI

/// A fixed viewport with a bounded native document avoids SwiftUI's lazy-row
/// height/scroll-anchor feedback loop. The model retains the complete transcript.
struct NativeCaptionTranscript: NSViewRepresentable {
    var segments: [CaptionSegment]
    var fontSize: Double
    var showEnglish: Bool
    var isIdle: Bool
    @Binding var followsLatest: Bool
    var accessibilityLabel = "한국어 실시간 자막과 영어 원문"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CaptionScrollView {
        let scroll = CaptionScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let verticalScroller = CaptionManualScroller()
        verticalScroller.userDidScroll = { [weak scroll] in scroll?.userDidScroll?() }
        scroll.verticalScroller = verticalScroller

        // Explicitly use the stable TextKit 1 document layout. Neither document
        // height nor intrinsic text size is fed back into the SwiftUI window.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let text = CaptionTextView(frame: scroll.contentView.bounds, textContainer: container)
        text.userDidNavigate = { [weak scroll] in scroll?.userDidScroll?() }
        text.drawsBackground = false
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize.zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 34, height: 14)
        text.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = text
        context.coordinator.attach(scroll: scroll, text: text)
        return scroll
    }

    func updateNSView(_ view: CaptionScrollView, context: Context) {
        let followBinding = $followsLatest
        // This callback only runs for actual user scroll input, never for a
        // programmatic scroll or during updateNSView/layout.
        view.userDidScroll = { followBinding.wrappedValue = false }
        context.coordinator.submit(.init(segments: segments, fontSize: fontSize,
            showEnglish: showEnglish, isIdle: isIdle), followsLatest: followsLatest)
    }

    static func dismantleNSView(_ view: CaptionScrollView, coordinator: Coordinator) {
        view.userDidScroll = nil
        coordinator.cancel()
    }

    struct Snapshot: Equatable {
        var segments: [CaptionSegment]
        var fontSize: Double
        var showEnglish: Bool
        var isIdle: Bool
    }

    @MainActor
    final class Coordinator {
        private weak var scroll: CaptionScrollView?
        private weak var text: NSTextView?
        private var rendered: Snapshot?
        private var pending: Snapshot?
        private var rowLengths: [Int] = []
        private var renderTask: Task<Void, Never>?
        private var followsLatest = true
        private var needsFollowScroll = false
        private var forceFollowScroll = false
        private var lastFollowScroll: TimeInterval = 0

        func attach(scroll: CaptionScrollView, text: NSTextView) {
            self.scroll = scroll
            self.text = text
            if let captionText = text as? CaptionTextView {
                captionText.viewportInspection = { [weak self, weak text] in
                    guard let self, let text else { return (nil, true, nil) }
                    return (self.visibleAnchor()?.address.segmentID, self.followsLatest,
                        self.rowAddress(at: text.selectedRange().location)?.segmentID)
                }
            }
        }

        func submit(_ snapshot: Snapshot, followsLatest: Bool) {
            if followsLatest && !self.followsLatest { needsFollowScroll = true; forceFollowScroll = true }
            self.followsLatest = followsLatest
            pending = snapshot == rendered ? nil : snapshot
            guard (pending != nil || needsFollowScroll), renderTask == nil else { return }
            // Replace pending work rather than retaining every ASR revision.
            // Even a burst of partials creates at most one scheduled UI update.
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
        }

        private func renderLatest() {
            guard let scroll, let text, let storage = text.textStorage else { return }
            let oldOrigin = scroll.contentView.bounds.origin
            let oldSelection = text.selectedRange()
            let viewportAnchor = followsLatest ? nil : visibleAnchor()
            let selectionStart = rowAddress(at: oldSelection.location)
            let selectionEnd = rowAddress(at: oldSelection.location + oldSelection.length)
            if let next = pending {
                pending = nil
                var commonRows = 0
                if let rendered, rendered.fontSize == next.fontSize,
                   rendered.showEnglish == next.showEnglish, rendered.isIdle == next.isIdle {
                    while commonRows < min(rendered.segments.count, next.segments.count),
                          rendered.segments[commonRows] == next.segments[commonRows] {
                        commonRows += 1
                    }
                }
                let offset = rowLengths.prefix(commonRows).reduce(0, +)
                let replacement = NSMutableAttributedString(string: "")
                var newLengths = Array(rowLengths.prefix(commonRows))
                for segment in next.segments.dropFirst(commonRows) {
                    let row = Self.attributedRow(segment, snapshot: next)
                    replacement.append(row)
                    newLengths.append(row.length)
                }
                storage.beginEditing()
                storage.replaceCharacters(in: NSRange(location: offset, length: storage.length - offset),
                    with: replacement)
                storage.endEditing()
                rowLengths = newLengths
                rendered = next
                // Map selection through retained row identities, so evicting a
                // prefix does not clear a selection in an unchanged older row.
                if let selectionStart, let selectionEnd,
                   let start = characterOffset(for: selectionStart),
                   let end = characterOffset(for: selectionEnd), end >= start {
                    text.setSelectedRange(NSRange(location: start, length: end - start))
                } else if oldSelection.location < offset {
                    text.setSelectedRange(NSRange(location: oldSelection.location,
                        length: min(oldSelection.length, max(0, storage.length - oldSelection.location))))
                }
                if !followsLatest {
                    if let viewportAnchor { restore(viewportAnchor, oldOrigin: oldOrigin) }
                    else { restorePixelOrigin(oldOrigin) }
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if followsLatest && (forceFollowScroll || now - lastFollowScroll >= 0.20) {
                text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                lastFollowScroll = now
                needsFollowScroll = false
                forceFollowScroll = false
            } else if followsLatest {
                // A trailing update guarantees the final revision reaches the
                // viewport, even when no more microphone results follow it.
                needsFollowScroll = true
                submit(rendered ?? .init(segments: [], fontSize: 35, showEnglish: true, isIdle: false),
                    followsLatest: true)
            }
        }

        private struct RowAddress {
            var segmentID: UUID
            var characterOffset: Int
        }
        private struct ViewportAnchor {
            var address: RowAddress
            var verticalOffset: CGFloat
        }

        private func rowAddress(at character: Int) -> RowAddress? {
            guard character != NSNotFound, character >= 0, let rendered else { return nil }
            var offset = 0
            for (index, length) in rowLengths.enumerated() {
                if character < offset + length || (index == rowLengths.count - 1 && character == offset + length) {
                    return .init(segmentID: rendered.segments[index].id, characterOffset: character - offset)
                }
                offset += length
            }
            return nil
        }

        private func characterOffset(for address: RowAddress) -> Int? {
            guard let rendered, let index = rendered.segments.firstIndex(where: { $0.id == address.segmentID }) else { return nil }
            return rowLengths.prefix(index).reduce(0, +) + min(address.characterOffset, rowLengths[index])
        }

        private func visibleAnchor() -> ViewportAnchor? {
            guard let scroll, let text, let layout = text.layoutManager, let container = text.textContainer,
                  let storage = text.textStorage, storage.length > 0 else { return nil }
            let origin = scroll.contentView.bounds.origin
            let point = NSPoint(x: container.lineFragmentPadding,
                y: max(0, origin.y - text.textContainerOrigin.y))
            let glyph = min(layout.glyphIndex(for: point, in: container), max(0, layout.numberOfGlyphs - 1))
            guard let address = rowAddress(at: layout.characterIndexForGlyph(at: glyph)) else { return nil }
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return .init(address: address,
                verticalOffset: origin.y - (glyphRect.minY + text.textContainerOrigin.y))
        }

        private func restore(_ anchor: ViewportAnchor, oldOrigin: NSPoint) {
            guard let scroll, let text, let layout = text.layoutManager, let container = text.textContainer,
                  let storage = text.textStorage, storage.length > 0,
                  let offset = characterOffset(for: anchor.address) else {
                restorePixelOrigin(oldOrigin)
                return
            }
            let character = min(offset, storage.length - 1)
            // Let AppKit finish sizing its document, then restore the visible
            // glyph's position. This stays inside the fixed native viewport and
            // never feeds document height back into SwiftUI window geometry.
            text.scrollRangeToVisible(NSRange(location: character, length: 0))
            layout.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            let glyph = layout.glyphIndexForCharacter(at: character)
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            var proposed = scroll.contentView.bounds
            proposed.origin = NSPoint(x: oldOrigin.x,
                y: glyphRect.minY + text.textContainerOrigin.y + anchor.verticalOffset)
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func restorePixelOrigin(_ origin: NSPoint) {
            guard let scroll else { return }
            var proposed = scroll.contentView.bounds
            proposed.origin = origin
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private static func attributedRow(_ segment: CaptionSegment, snapshot: Snapshot) -> NSAttributedString {
            let text = NSMutableAttributedString(string: "")
            let secondary = NSColor(calibratedRed: 0.56, green: 0.61, blue: 0.68, alpha: 1)
            let draft = NSColor(calibratedRed: 0.59, green: 0.63, blue: 0.69, alpha: 1)
            let ink = NSColor(calibratedRed: 0.94, green: 0.96, blue: 0.99, alpha: 1)
            let time = max(0, Int(segment.audioStart))
            var label = String(format: "%02d:%02d", time / 60, time % 60)
            if !segment.isFinal { label += "  ·  " + captionState(segment, isIdle: snapshot.isIdle) }
            if segment.contextSegmentCount > 1 { label += "  ·  문맥 묶음" }
            let metadataStyle = NSMutableParagraphStyle()
            metadataStyle.paragraphSpacing = 10
            text.append(NSAttributedString(string: label + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: secondary, .paragraphStyle: metadataStyle
            ]))
            let translation = segment.translation ?? (segment.translationError == nil
                ? "자막을 준비하고 있습니다…" : "번역하지 못했습니다. 원문을 확인해 주세요.")
            let captionStyle = NSMutableParagraphStyle()
            captionStyle.lineSpacing = 8
            captionStyle.paragraphSpacing = snapshot.showEnglish || segment.translationError != nil ? 10 : 28
            text.append(NSAttributedString(string: translation + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: snapshot.fontSize, weight: segment.isFinal ? .medium : .regular),
                .foregroundColor: segment.isFinal ? ink : draft, .paragraphStyle: captionStyle
            ]))
            if snapshot.showEnglish || segment.translationError != nil {
                let sourceStyle = NSMutableParagraphStyle()
                sourceStyle.lineSpacing = 5
                sourceStyle.paragraphSpacing = 28
                text.append(NSAttributedString(string: segment.source + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: secondary,
                    .paragraphStyle: sourceStyle
                ]))
            }
            return text
        }

        private static func captionState(_ segment: CaptionSegment, isIdle: Bool) -> String {
            if segment.translationError != nil { return "번역 실패 · 원문 확인" }
            if segment.contextIsPending { return "문맥 확인 중" }
            if segment.translation != nil && segment.translatedRevision != segment.revision { return "이전 번역 · 갱신 중" }
            if !segment.sourceIsFinal { return isIdle ? "인식 미확정" : "듣고 수정하는 중" }
            return "번역 중"
        }
    }
}

@MainActor
final class CaptionScrollView: NSScrollView {
    var userDidScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        userDidScroll?()
        super.scrollWheel(with: event)
    }
}

// Dragging a scrollbar must suspend following just like a wheel gesture. Observe
// the explicit user input, never layout/bounds notifications from our own scrolls.
@MainActor
final class CaptionManualScroller: NSScroller {
    var userDidScroll: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        userDidScroll?()
        super.mouseDown(with: event)
    }
}

// Standard text commands include Page/Home/End, modifier navigation and text
// selection movement. Only explicit responder commands suspend following.
@MainActor
final class CaptionTextView: NSTextView {
    var userDidNavigate: (() -> Void)?
    // Passive test inspection; no observation, notification or layout callbacks.
    var viewportInspection: (() -> (segmentID: UUID?, followsLatest: Bool, selectedStartSegmentID: UUID?))?
    private static let navigationCommands: Set<String> = [
        "pageUp:", "pageDown:", "scrollPageUp:", "scrollPageDown:",
        "scrollLineUp:", "scrollLineDown:",
        "scrollToBeginningOfDocument:", "scrollToEndOfDocument:",
        "moveToBeginningOfDocument:", "moveToEndOfDocument:",
        "moveToBeginningOfDocumentAndModifySelection:", "moveToEndOfDocumentAndModifySelection:",
        "moveUp:", "moveDown:", "moveLeft:", "moveRight:",
        "moveUpAndModifySelection:", "moveDownAndModifySelection:",
        "moveLeftAndModifySelection:", "moveRightAndModifySelection:",
        "moveToBeginningOfParagraph:", "moveToEndOfParagraph:",
        "moveToBeginningOfParagraphAndModifySelection:", "moveToEndOfParagraphAndModifySelection:",
        "moveWordForward:", "moveWordBackward:",
        "moveWordForwardAndModifySelection:", "moveWordBackwardAndModifySelection:"
    ]

    override func doCommand(by selector: Selector) {
        if Self.navigationCommands.contains(NSStringFromSelector(selector)) { userDidNavigate?() }
        super.doCommand(by: selector)
    }
}
