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
            CommandGroup(after: .sidebar) {
                SortByMenuCommand()
            }
        }
    }
}

/// "View → Sort Mails by" / "Sort Conversations by" submenus + trailing
/// separator. SwiftUI lays out each `Picker` inside `Commands` as a submenu
/// with one menu item per tag and a check beside the active one — that's the
/// macOS-native rendering of a single-selection picker in a menu bar.
private struct SortByMenuCommand: View {
    @FocusedValue(\.mailModel) private var focused

    var body: some View {
        Picker("Sort Mails by", selection: mailBinding) {
            Text("Newest Message on Top").tag(MessageSortOrder.newest)
            Text("Oldest Message on Top").tag(MessageSortOrder.oldest)
        }
        .disabled(model == nil)

        Picker("Sort Conversations by", selection: conversationBinding) {
            Text("Newest Message on Top").tag(MessageSortOrder.newest)
            Text("Oldest Message on Top").tag(MessageSortOrder.oldest)
        }
        .disabled(model == nil)

        Divider()
    }

    /// `@FocusedValue` of an optional Entry yields a double-optional; collapse
    /// it once so callers see a plain `MailModel?`.
    private var model: MailModel? { focused ?? nil }

    private var mailBinding: Binding<MessageSortOrder> {
        Binding(
            get: { model?.messageSortOrder ?? .newest },
            set: { newValue in model?.messageSortOrder = newValue }
        )
    }

    private var conversationBinding: Binding<MessageSortOrder> {
        Binding(
            get: { model?.conversationSortOrder ?? .oldest },
            set: { newValue in model?.conversationSortOrder = newValue }
        )
    }
}
