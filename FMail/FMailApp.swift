import AppKit
import SwiftUI

@main
struct FMailApp: App {
    /// One model instance shared by `WindowGroup` and `Settings`. Created
    /// here so a Settings window can read MCP server status without
    /// re-bootstrapping the index.
    @State private var model = MailModel()

    var body: some Scene {
        WindowGroup {
            AppShell(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
        .commands {
            // Mail.app structure diagnostic — runs an AppleScript that
            // dumps every account + mailbox name as Mail.app exposes them.
            // Used to verify that FMail's mailbox path matches what Mail.app
            // actually serves (Gmail folders are a frequent mismatch source).
            CommandMenu("Tools") {
                Button("Diagnose Mail.app structure…") {
                    Task {
                        let dump = await MailScripter.diagnoseStructure()
                        await MainActor.run {
                            showDiagnosticAlert(title: "Mail.app accounts & mailboxes", body: dump)
                        }
                    }
                }
                Button("Diagnose Junk mailboxes…") {
                    Task {
                        let dump = await MailScripter.diagnoseJunkMailboxes()
                        await MainActor.run {
                            showDiagnosticAlert(title: "Junk mailbox per account", body: dump)
                        }
                    }
                }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
private func showDiagnosticAlert(title: String, body: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body.isEmpty ? "(no output)" : body
    alert.addButton(withTitle: "Copy")
    alert.addButton(withTitle: "Close")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
    }
}
