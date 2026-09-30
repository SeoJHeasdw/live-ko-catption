import AppKit
import SwiftUI

@main @MainActor
struct LiveKoCaptionApp: App {
    @NSApplicationDelegateAdaptor(CaptionAppDelegate.self) private var delegate
    @ViewState private var model = CaptionModel(preview: CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--snapshot"))

    var body: some Scene {
        Window("한글 라이브 자막", id: "captions") {
            CaptionView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("원문·자막 저장…") { model.exportTranscript() }
                    .keyboardShortcut("s", modifiers: .command).disabled(!model.hasContent)
            }
        }
    }
}

@MainActor
final class CaptionAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: CaptionModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
