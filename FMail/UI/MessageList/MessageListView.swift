import AppKit
import SwiftUI

struct MessageListView: View {
    var model: MailModel
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, focused: $searchFocused)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if !model.searchQuery.isEmpty {
                SearchResultsView(model: model)
            } else {
                threadsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var threadsList: some View {
        if model.selection == nil {
            ContentUnavailableView(
                "Select a mailbox",
                systemImage: "tray",
                description: Text("Choose a mailbox in the sidebar to see its threads.")
            )
        } else if model.isLoadingThreads {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = model.threadsError {
            ContentUnavailableView(
                "Failed to load",
                systemImage: "xmark.octagon",
                description: Text(err)
            )
        } else if model.threadsForSelectedMailbox.isEmpty {
            ContentUnavailableView(
                "No messages",
                systemImage: "tray",
                description: Text("This mailbox has no messages.")
            )
        } else {
            VStack(spacing: 0) {
                ThreadListHeader(model: model)
                Divider()
                // Manual click handling — same reason as SearchResultsView:
                // List(selection: Set<T>) is unreliable inside
                // NavigationSplitView's content column, especially when
                // opening the reader on click steals focus.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.threadsForSelectedMailbox) { thread in
                                threadRow(for: thread)
                                    .id(thread.threadId)
                                Divider()
                            }
                        }
                    }
                    .onChange(of: model.selectedThreadId) { _, newId in
                        guard let newId else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newId, anchor: .center)
                        }
                    }
                }
            }
            .focusable()
            // Suppress the default macOS blue focus ring; we still want
            // the view to be focused so .onKeyPress fires, but the ring
            // bleeds visibly into the surrounding split-view dividers.
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                navigateThreads(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                navigateThreads(by: 1)
                return .handled
            }
        }
    }

    /// Move the open-thread selection by `direction` (-1 = previous,
    /// +1 = next) in the visible thread list. Wraps neither end. If
    /// nothing is selected yet, the first arrow press selects the
    /// top (down) or the bottom (up) row.
    private func navigateThreads(by direction: Int) {
        let threads = model.threadsForSelectedMailbox
        guard !threads.isEmpty else { return }
        let currentIdx = model.selectedThreadId
            .flatMap { id in threads.firstIndex(where: { $0.threadId == id }) }
        let newIdx: Int
        if let currentIdx {
            newIdx = max(0, min(threads.count - 1, currentIdx + direction))
            if newIdx == currentIdx { return }
        } else {
            newIdx = direction > 0 ? 0 : threads.count - 1
        }
        model.selectThread(threads[newIdx])
    }

    @ViewBuilder
    private func threadRow(for thread: ThreadSummary) -> some View {
        let isSelected = model.selectedThreadIds.contains(thread.threadId)
        ThreadRow(thread: thread)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                handleThreadTap(thread)
            }
    }

    private func handleThreadTap(_ thread: ThreadSummary) {
        switch ListSelectionGesture.action() {
        case .toggle:
            model.toggleThreadSelection(thread)
        case .rangeFromAnchor:
            if let anchor = model.selectedThreadIds.first {
                model.selectThreadRange(anchorThreadId: anchor, to: thread.threadId)
            } else {
                model.selectThread(thread)
            }
        case .open:
            model.selectThread(thread)
        }
    }
}

private struct ThreadListHeader: View {
    var model: MailModel

    var body: some View {
        BulkActionHeader(
            totalCount: model.threadsForSelectedMailbox.count,
            totalLabel: { "\($0) thread\($0 == 1 ? "" : "s")" },
            selectedCount: model.selectedThreadIds.count,
            onMarkRead: { Task { await model.markSelectedThreadsAsRead(true) } },
            onMarkUnread: { Task { await model.markSelectedThreadsAsRead(false) } },
            onMoveToJunk: { Task { await model.moveSelectedThreadsToJunk() } },
            onDelete: { Task { await model.deleteSelectedThreads() } },
            onClearSelection: { model.selectedThreadIds = [] }
        )
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary

    private var correspondentText: String {
        if !thread.latestSenderDisplay.isEmpty { return thread.latestSenderDisplay }
        return thread.latestIsOutgoing ? "(no recipient)" : "(unknown sender)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unreadCount > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    HStack(spacing: 4) {
                        if thread.latestIsOutgoing {
                            Text("To:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(correspondentText)
                            .font(thread.unreadCount > 0 ? .body.bold() : .body)
                            .lineLimit(1)
                    }
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let date = thread.latestDateReceived {
                        Text(date, format: date.listFormat())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(thread.latestSubject.isEmpty ? "(no subject)" : thread.latestSubject)
                    .font(thread.unreadCount > 0 ? .callout.weight(.semibold) : .callout)
                    .lineLimit(1)
            }

            if thread.flaggedCount > 0 {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
