import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting mid-import leaves a half-copied folder, so confirm first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = MainActor.assumeIsolated({ model }),
              MainActor.assumeIsolated({ model.phase == .importing }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An import is still running"
        alert.informativeText = "If you quit now, the folder will be incomplete and nothing on the card will be verified."
        alert.addButton(withTitle: "Keep Importing")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

@main
struct CameraCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Camera Copy", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            // Just under "About Camera Copy". The check itself lives in ContentView's Updater.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
            }
        }
    }
}
