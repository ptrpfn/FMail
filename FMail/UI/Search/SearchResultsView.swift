import SwiftUI

struct SearchResultsView: View {
    @Bindable var model: MailModel

    var body: some View {
        if let err = model.searchError {
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if model.isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.searchResults.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try a broader query or different operators.")
            )
        } else {
            List(selection: Binding(
                get: { model.selectedSearchResultId },
                set: { newId in
                    if let newId, let m = model.searchResults.first(where: { $0.rowId == newId }) {
                        model.openFromSearch(m)
                    }
                }
            )) {
                ForEach(model.searchResults) { msg in
                    SearchResultRow(message: msg, mailboxes: model.mailboxes)
                        .tag(msg.rowId)
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let message: MessageHeader
    let mailboxes: [Mailbox]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(senderText)
                        .font(message.isRead ? .body : .body.bold())
                        .lineLimit(1)
                    Spacer()
                    if let date = message.dateReceived ?? message.dateSent {
                        Text(date, format: dateFormat(for: date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.callout)
                    .lineLimit(1)
                if let mb = mailbox {
                    Text(mb.pathComponents.joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if message.isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var senderText: String {
        if !message.senderDisplay.isEmpty { return message.senderDisplay }
        return message.senderAddress.isEmpty ? "(unknown)" : message.senderAddress
    }

    private var mailbox: Mailbox? {
        mailboxes.first(where: { $0.rowId == message.mailboxRowId })
    }

    private func dateFormat(for date: Date) -> Date.FormatStyle {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .dateTime.hour().minute() }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.year().month(.abbreviated).day()
    }
}
