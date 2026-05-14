import AppKit
import SwiftUI

struct SearchResultsView: View {
    var model: MailModel

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
                SearchResultsHeader(model: model)
                Divider()
                // Manual click handling instead of `List(selection:)` —
                // multi-select inside NavigationSplitView's content column is
                // flaky, especially because opening the reader steals focus
                // away from the List which then ignores ⌘-click.
                // Reading `NSEvent.modifierFlags` at click time is reliable.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.searchResults) { msg in
                                row(for: msg)
                                    .id(msg.rowId)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: model.selectedSearchResultIds) { _, newIds in
                        guard newIds.count == 1, let id = newIds.first else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .focusable()
            // Suppress the default macOS blue focus ring; we still want the
            // view to be focused so .onKeyPress fires.
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                navigate(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                navigate(by: 1)
                return .handled
            }
        }
    }

    /// Move the search-result selection by `direction` (-1 = previous,
    /// +1 = next). Replaces any multi-selection with the single newly-
    /// chosen row and opens it in the reader (same as a plain click).
    private func navigate(by direction: Int) {
        let results = model.searchResults
        guard !results.isEmpty else { return }
        let currentIdx: Int? = {
            guard model.selectedSearchResultIds.count == 1,
                  let id = model.selectedSearchResultIds.first
            else { return nil }
            return results.firstIndex(where: { $0.rowId == id })
        }()
        let newIdx: Int
        if let currentIdx {
            newIdx = max(0, min(results.count - 1, currentIdx + direction))
            if newIdx == currentIdx { return }
        } else {
            newIdx = direction > 0 ? 0 : results.count - 1
        }
        let target = results[newIdx]
        model.selectedSearchResultIds = [target.rowId]
        model.openFromSearch(target)
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
        switch ListSelectionGesture.action() {
        case .toggle:
            if model.selectedSearchResultIds.contains(msg.rowId) {
                model.selectedSearchResultIds.remove(msg.rowId)
            } else {
                model.selectedSearchResultIds.insert(msg.rowId)
            }
        case .rangeFromAnchor:
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
        case .open:
            model.selectedSearchResultIds = [msg.rowId]
            model.openFromSearch(msg)
        }
    }
}

private struct SearchResultsHeader: View {
    var model: MailModel

    var body: some View {
        BulkActionHeader(
            totalCount: model.searchResults.count,
            totalLabel: { "\($0) result\($0 == 1 ? "" : "s")" },
            selectedCount: model.selectedSearchResultIds.count,
            onMarkRead: { model.markSelectedSearchResultsAsRead(true) },
            onMarkUnread: { model.markSelectedSearchResultsAsRead(false) },
            onMoveToJunk: { model.moveSelectedSearchResultsToJunk() },
            onDelete: { model.deleteSelectedSearchResults() },
            onClearSelection: { model.selectedSearchResultIds = [] }
        )
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
                        Text(date, format: date.listFormat())
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
}
