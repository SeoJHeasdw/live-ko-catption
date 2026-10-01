import AppKit
import Observation
import SwiftUI

/// Presentation shares the existing model and leaves the detailed window's
/// readiness/translation host mounted while its window is ordered out.
@MainActor @Observable
final class CaptionWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var isCompact = false
    var sidebarExpanded = UserDefaults.standard.object(forKey: "captionSidebarExpanded") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarExpanded, forKey: "captionSidebarExpanded") }
    }
    @ObservationIgnored private(set) weak var detailWindow: NSWindow?
    @ObservationIgnored private(set) var compactPanel: NSPanel?
    @ObservationIgnored private weak var model: CaptionModel?
    @ObservationIgnored private var fullScreenObserver: NSObjectProtocol?
    @ObservationIgnored private var compactAfterFullScreen = false
    /// One above the level macOS uses to cover a display that a presentation
    /// has taken over, so the caption window is not hidden by a slideshow.
    private static let presentationLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)

    func attach(window: NSWindow, model: CaptionModel) {
        guard detailWindow !== window else { return }
        detailWindow = window
        self.model = model
        CaptionAppDelegate.windows = self
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.compactAfterFullScreen else { return }
                self.compactAfterFullScreen = false
                self.showCompact()
            }
        }
        if CommandLine.arguments.contains("--compact-preview") { showCompact() }
    }

    func showCompact() {
        guard let detailWindow, let model else { return }
        if detailWindow.styleMask.contains(.fullScreen) {
            compactAfterFullScreen = true
            detailWindow.toggleFullScreen(nil)
            return
        }
        let panel: NSPanel
        if let compactPanel { panel = compactPanel }
        else {
            panel = CompactCaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 224),
                styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "라이브 자막 · 간략 보기"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            let host = NSHostingView(rootView: CompactCaptionView(model: model, windows: self))
            // Only the explicit minimum belongs to SwiftUI. Caption document
            // height must never become the window's intrinsic or maximum size.
            host.sizingOptions = [.minSize]
            host.frame = NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            panel.contentMinSize = NSSize(width: 420, height: 144)
            if !panel.setFrameUsingName("CompactCaptionPanel") {
                let screen = detailWindow.screen ?? NSScreen.main
                let available = screen?.visibleFrame ?? detailWindow.frame
                panel.setFrameOrigin(NSPoint(x: available.midX - panel.frame.width / 2,
                    y: available.minY + 68))
            }
            panel.setFrameAutosaveName("CompactCaptionPanel")
            self.compactPanel = panel
        }
        // The setting can change while the detailed window is in front.
        panel.level = model.compactStaysAbovePresentations ? Self.presentationLevel : .floating
        keepOnScreen(panel, preferredScreen: detailWindow.screen)
        isCompact = true
        panel.orderFrontRegardless()
        detailWindow.orderOut(nil)
    }

    func showDetailed() {
        compactAfterFullScreen = false
        guard let detailWindow else { return }
        isCompact = false
        if detailWindow.isMiniaturized { detailWindow.deminiaturize(nil) }
        detailWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        compactPanel?.orderOut(nil)
    }

    func pauseOrResume() async {
        guard let model else { return }
        if model.canStop { await model.stop() }
        else if model.canStart { await model.start() }
    }

    func stopAndShowDetailed() async {
        guard let model else { return }
        // Bring the preserved transcript and any finalization error into view.
        // This never clears history, including a pause already in progress.
        showDetailed()
        if model.canStop { await model.stop() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        showDetailed()
        return false
    }

    private func keepOnScreen(_ panel: NSWindow, preferredScreen: NSScreen?) {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }
            ?? preferredScreen ?? NSScreen.main
        guard let available = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.size.width = min(available.width, max(panel.minSize.width, frame.width))
        frame.size.height = min(available.height, max(panel.minSize.height, frame.height))
        frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }
}

private final class CompactCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CaptionWindowAttachment: NSViewRepresentable {
    let windows: CaptionWindowCoordinator
    let model: CaptionModel

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attached = { window in windows.attach(window: window, model: model) }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) { view.attachIfNeeded() }

    final class AttachmentView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }
        func attachIfNeeded() {
            guard let window else { return }
            // Do not change presentation in the middle of SwiftUI's layout.
            let attached = attached
            Task { @MainActor [weak window] in
                if let window { attached?(window) }
            }
        }
    }
}
