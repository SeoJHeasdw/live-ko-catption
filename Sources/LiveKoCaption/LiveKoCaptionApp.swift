import AppKit
import SwiftUI

@main @MainActor
struct LiveKoCaptionApp: App {
    @NSApplicationDelegateAdaptor(CaptionAppDelegate.self) private var delegate
    @ViewState private var windows = CaptionWindowCoordinator()
    @ViewState private var model = CaptionUISoakRunner.requestedSeconds != nil
        ? CaptionUISoakRunner.makeModel()
        : CaptionModel(preview: CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--snapshot"))

    var body: some Scene {
        Window("라이브 자막", id: "captions") {
            CaptionView(model: model, windows: windows)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("기록 저장…") { model.exportTranscript() }
                    .keyboardShortcut("s", modifiers: .command).disabled(!model.hasContent)
            }
            CommandMenu("자막 보기") {
                Button("상세 보기") { windows.showDetailed() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("간략 보기") { windows.showCompact() }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                Button(controlTitle) {
                    Task { await windows.pauseOrResume() }
                }.disabled(!model.canStart && !model.canStop)
                Button("일시정지하고 상세 보기") {
                    Task { await windows.stopAndShowDetailed() }
                }.keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("번역 방향 전환") {
                    Task { await model.switchDirection() }
                }.keyboardShortcut("d", modifiers: .command).disabled(!model.canSwitchDirection)
            }
        }
    }

    private var controlTitle: String {
        switch model.phase {
        case .starting: return "시작 취소"
        case .listening: return "일시정지"
        case .stopping: return "마지막 자막 정리 중"
        case .idle: return model.hasContent ? "자막 재개" : "자막 시작"
        }
    }
}

@MainActor
final class CaptionAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: CaptionModel?
    static weak var windows: CaptionWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CaptionUISoakRunner.requestedSeconds != nil {
            Task { @MainActor in
                for _ in 0..<30 {
                    if let model = Self.model { CaptionUISoakRunner.start(model: model); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fputs("Cannot capture app preview\n", stderr)
                    NSApp.terminate(nil)
                    return
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    do { try data.write(to: URL(fileURLWithPath: path)) }
                    catch { fputs("Preview write failed: \(error)\n", stderr) }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Self.windows?.isCompact != true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.windows?.showDetailed()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isListening else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        // Quitting remains responsive even if a system model fails to finish.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
