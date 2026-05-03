import SwiftUI

struct MessageListView: View {
    @Bindable var model: MailModel
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
            List(selection: Binding(
                get: { model.selectedThreadId },
                set: { newId in
                    if let newId, let t = model.threadsForSelectedMailbox.first(where: { $0.threadId == newId }) {
                        model.selectThread(t)
                    }
                }
            )) {
                ForEach(model.threadsForSelectedMailbox) { thread in
                    ThreadRow(thread: thread)
                        .tag(thread.threadId)
                }
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unreadCount > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.latestSenderDisplay.isEmpty ? "(unknown sender)" : thread.latestSenderDisplay)
                        .font(thread.unreadCount > 0 ? .body.bold() : .body)
                        .lineLimit(1)
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
                        Text(date, format: dateFormat(for: date))
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

    private func dateFormat(for date: Date) -> Date.FormatStyle {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return .dateTime.hour().minute()
        }
        if cal.isDate(date, equalTo: .now, toGranularity: .year) {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.year().month(.abbreviated).day()
    }
}
