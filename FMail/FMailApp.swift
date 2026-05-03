import SwiftUI

@main
struct FMailApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}
