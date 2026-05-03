import AppKit
import Foundation

enum FullDiskAccess {
    /// Heuristic: if we can list `~/Library/Mail`, we have FDA. Mail.app stores its
    /// data there and the directory is gated by FDA for non-Apple processes.
    /// Returns false if the directory doesn't exist (no Mail.app data) — caller
    /// should distinguish that case if needed.
    static func isGrantedHeuristic() -> Bool {
        let mailDir = URL(fileURLWithPath: ("~/Library/Mail" as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mailDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Try to read directory contents — this is what TCC actually gates.
        return (try? FileManager.default.contentsOfDirectory(atPath: mailDir.path)) != nil
    }

    /// Opens the System Settings pane where the user can grant Full Disk Access
    /// to FMail. The URL scheme has shifted across macOS versions; we try the
    /// current Tahoe form first and fall back to the older form.
    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

import SwiftUI

struct FullDiskAccessPrompt: View {
    var onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Full Disk Access required", systemImage: "lock.shield")
                .font(.title2)

            Text("FMail reads Apple Mail's local data at `~/Library/Mail/` to build a faster index and search. macOS gates this behind Full Disk Access.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Steps:").font(.headline)
                Text("1. Click *Open System Settings* below.")
                Text("2. Toggle FMail on in the Full Disk Access list. (You may need to drag FMail.app into the list if it isn't shown.)")
                Text("3. Return here and click *Recheck*. macOS Tahoe sometimes requires relaunching FMail before the change takes effect.")
            }
            .font(.callout)

            HStack {
                Button("Open System Settings") {
                    FullDiskAccess.openSystemSettings()
                }
                .keyboardShortcut(.defaultAction)

                Button("Recheck", action: onRecheck)
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
    }
}
