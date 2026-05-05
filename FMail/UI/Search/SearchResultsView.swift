import AppKit
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
            VStack(spacing: 0) {
                if model.selectedSearchResultIds.count > 1 {
                    BulkActionBar(model: model)
                    Divider()
                }
                // Manual click handling instead of `List(selection:)` —
                // multi-select inside NavigationSplitView's content column is
                // flaky, especially because opening the reader steals focus
                // away from the List which then ignores ⌘-click.
                // Reading `NSEvent.modifierFlags` at click time is reliable.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchResults) { msg in
                            row(for: msg)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for msg: MessageHeader) -> some View {
        let isSelected = model.selectedSearchResultIds.contains(msg.rowId)
        SearchResultRow(message: msg, mailboxes: model.mailboxes)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(msg)
            }
    }

    private func handleTap(_ msg: MessageHeader) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            // ⌘-click: toggle this row in the selection without opening.
            if model.selectedSearchResultIds.contains(msg.rowId) {
                model.selectedSearchResultIds.remove(msg.rowId)
            } else {
                model.selectedSearchResultIds.insert(msg.rowId)
            }
        } else if mods.contains(.shift) {
            // ⇧-click: range-select from the first selected (anchor) to here.
            if let anchorId = model.selectedSearchResultIds.first,
               let anchorIdx = model.searchResults.firstIndex(where: { $0.rowId == anchorId }),
               let thisIdx = model.searchResults.firstIndex(where: { $0.rowId == msg.rowId }) {
                let range = anchorIdx <= thisIdx ? anchorIdx...thisIdx : thisIdx...anchorIdx
                for i in range {
                    model.selectedSearchResultIds.insert(model.searchResults[i].rowId)
                }
            } else {
                model.selectedSearchResultIds = [msg.rowId]
                model.openFromSearch(msg)
            }
        } else {
            // Plain click: replace selection and open in reader.
            model.selectedSearchResultIds = [msg.rowId]
            model.openFromSearch(msg)
        }
    }
}

private struct BulkActionBar: View {
    @Bindable var model: MailModel

    var body: some View {
        HStack(spacing: 8) {
            Text("\(model.selectedSearchResultIds.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.markSelectedSearchResultsAsRead(true)
            } label: {
                Label("Mark as Read", systemImage: "envelope.open")
            }
            Button {
                model.markSelectedSearchResultsAsRead(false)
            } label: {
                Label("Mark as Unread", systemImage: "envelope.badge")
            }
            Button("Clear") {
                model.selectedSearchResultIds = []
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
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
