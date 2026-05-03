import SwiftUI

struct SidebarView: View {
    @Bindable var model: MailModel

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { newSel in
                guard let newSel else { return }
                switch newSel {
                case .allMailboxes:
                    model.selectAllMailboxes()
                case .mailbox(let id):
                    if let mb = model.mailboxes.first(where: { $0.rowId == id }) {
                        model.selectMailbox(mb)
                    }
                }
            }
        )) {
            Section {
                AllMailboxesRow(unreadCount: model.allUnreadCount)
                    .tag(SidebarSelection.allMailboxes)
            }

            ForEach(model.mailboxesByAccount, id: \.0.uuid) { (account, mailboxes) in
                Section(account.displayName) {
                    ForEach(mailboxes) { mb in
                        MailboxRow(mailbox: mb)
                            .tag(SidebarSelection.mailbox(mb.rowId))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $model.showHidden) {
                    Image(systemName: "eye")
                }
                .help("Show hidden mailboxes (All Mail, Recovered, SendLater)")
            }
        }
    }
}

private struct AllMailboxesRow: View {
    let unreadCount: Int

    var body: some View {
        HStack {
            Image(systemName: "tray.full")
                .foregroundStyle(.tint)
            Text("All Mailboxes")
                .fontWeight(.medium)
            Spacer()
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }
}

private struct MailboxRow: View {
    let mailbox: Mailbox

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mailbox.displayName)
                    .lineLimit(1)
                if mailbox.pathComponents.count > 1 {
                    Text(mailbox.pathComponents.dropLast().joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if mailbox.unreadCount > 0 {
                Text("\(mailbox.unreadCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }

    private var icon: String {
        switch mailbox.displayName {
        case "INBOX": return "tray"
        case "Sent Messages", "Sent Mail": return "paperplane"
        case "Drafts": return "doc"
        case "Junk": return "xmark.bin"
        case "Deleted Messages", "Trash": return "trash"
        case "Archive": return "archivebox"
        case "All Mail": return "envelope.badge"
        default: return "folder"
        }
    }
}
