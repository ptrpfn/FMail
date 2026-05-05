import AppKit
import SwiftUI

@main
struct FMailApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
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
                            let alert = NSAlert()
                            alert.messageText = "Mail.app accounts & mailboxes"
                            alert.informativeText = dump.isEmpty ? "(no output)" : dump
                            alert.addButton(withTitle: "Copy")
                            alert.addButton(withTitle: "Close")
                            let response = alert.runModal()
                            if response == .alertFirstButtonReturn {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(dump, forType: .string)
                            }
                        }
                    }
                }
            }
        }
    }
}
