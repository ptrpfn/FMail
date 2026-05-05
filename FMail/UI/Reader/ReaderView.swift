import SwiftUI

struct ReaderView: View {
    @Bindable var model: MailModel

    var body: some View {
        Group {
            content
        }
        .sheet(item: Binding(
            get: { model.replyDraft.map { ReplyDraftWrapper(draft: $0) } },
            set: { _ in model.cancelReply() }
        )) { wrapper in
            ReplyConfirmationSheet(model: model, draft: wrapper.draft)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedThreadId == nil {
            ContentUnavailableView(
                "Select a thread",
                systemImage: "envelope",
                description: Text("Choose a thread from the list to read it here.")
            )
        } else if model.isLoadingThreadMessages {
            ProgressView("Loading thread…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let messages = model.messagesInSelectedThread
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(messages.enumerated()), id: \.element.rowId) { index, msg in
                        if index > 0 && index - 1 < messages.count {
                            timeDelta(from: messages[index - 1], to: msg)
                        }
                        MessageBlock(
                            message: msg,
                            messageBody: model.selectedMessageId == msg.rowId ? model.bodyForSelectedMessage : nil,
                            isLoadingBody: model.selectedMessageId == msg.rowId && model.isLoadingBody,
                            bodyError: model.selectedMessageId == msg.rowId ? model.bodyError : nil,
                            isExpanded: model.selectedMessageId == msg.rowId,
                            onTap: { model.selectMessage(msg) },
                            onReply: { model.startReply(kind: .reply, message: msg, body: model.bodyForSelectedMessage) },
                            onReplyAll: { model.startReply(kind: .replyAll, message: msg, body: model.bodyForSelectedMessage) },
                            onForward: { model.startReply(kind: .forward, message: msg, body: model.bodyForSelectedMessage) }
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func timeDelta(from previous: MessageHeader, to current: MessageHeader) -> some View {
        if let prev = previous.dateReceived ?? previous.dateSent,
           let curr = current.dateReceived ?? current.dateSent {
            let delta = curr.timeIntervalSince(prev)
            if delta > 0 {
                HStack {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                    Text(formatDelta(delta))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func formatDelta(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "+\(Int(seconds))s" }
        if seconds < 3600 { return "+\(Int(seconds / 60))m" }
        if seconds < 86400 { return "+\(Int(seconds / 3600))h" }
        if seconds < 86400 * 30 { return "+\(Int(seconds / 86400))d" }
        if seconds < 86400 * 365 { return "+\(Int(seconds / (86400 * 30)))mo" }
        return "+\(Int(seconds / (86400 * 365)))y"
    }
}

private struct MessageBlock: View {
    let message: MessageHeader
    let messageBody: MessageBody?
    let isLoadingBody: Bool
    let bodyError: String?
    let isExpanded: Bool
    let onTap: () -> Void
    let onReply: () -> Void
    let onReplyAll: () -> Void
    let onForward: () -> Void

    @State private var htmlMeasuredHeight: CGFloat = 200
    /// Per-message opt-in: load external `<img src="http://…">` references
    /// (e.g. newsletter graphs). False by default — privacy-preserving.
    /// Resets when the user navigates away (MessageBlock recreated).
    @State private var loadRemoteImages: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                // Toolbar at the top — long footers shouldn't push Reply
                // off-screen.
                replyToolbar
                if let bodyError {
                    bodyErrorBlock(bodyError)
                } else if isLoadingBody {
                    ProgressView()
                } else if let messageBody {
                    if !messageBody.attachmentNames.isEmpty {
                        HStack {
                            Image(systemName: "paperclip").foregroundStyle(.secondary)
                            Text(messageBody.attachmentNames.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    bodyContent(messageBody)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(message.isRead ? Color.secondary.opacity(0.05) : Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isExpanded ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .padding(.bottom, 4)
        .onTapGesture { onTap() }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderDisplay.isEmpty ? message.senderAddress : message.senderDisplay)
                    .font(message.isRead ? .body : .body.bold())
                if isExpanded {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.title3.weight(.semibold))
                        .padding(.top, 2)
                } else {
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if message.isFlagged {
                Image(systemName: "flag.fill")
                    .foregroundStyle(.orange)
            }
            if let date = message.dateReceived ?? message.dateSent {
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func bodyContent(_ body: MessageBody) -> some View {
        // Prefer HTML rendering when the message has an HTML part — much
        // closer to Mail.app's display fidelity. WKWebView is locked down
        // (no network) so no read-tracking pixels and no remote-image leaks.
        if let html = body.html, !html.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !loadRemoteImages && HTMLBodyView.containsRemoteImages(html) {
                    Button {
                        loadRemoteImages = true
                    } label: {
                        Label("Load remote images", systemImage: "photo.on.rectangle")
                    }
                    .controlSize(.small)
                    .help("This email includes external images. Loading them sends a network request to the sender's server, which can be used as a read receipt. Choice doesn't persist — re-open the email and they're hidden again.")
                }
                HTMLBodyView(html: html, allowRemoteImages: loadRemoteImages, measuredHeight: $htmlMeasuredHeight)
                    .frame(height: htmlMeasuredHeight)
                    .frame(maxWidth: .infinity)
            }
        } else {
            Text(body.displayText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var replyToolbar: some View {
        HStack(spacing: 8) {
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .keyboardShortcut("r", modifiers: .command)
            Button(action: onReplyAll) {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(action: onForward) {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            if let rfcId = message.rfcMessageId, !rfcId.isEmpty {
                Button {
                    _ = MailAppOpener.openMessage(rfcMessageId: rfcId)
                } label: {
                    Label("Open in Mail.app", systemImage: "arrow.up.right.square")
                }
                .help("Opens Mail.app at this message — useful when the body hasn't downloaded yet")
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func bodyErrorBlock(_ message: String) -> some View {
        let isPermissionError = message.contains("-1743") || message.lowercased().contains("not authorized")
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if isPermissionError {
                Text("FMail needs permission to send Apple events to Mail.app for Mark-as-Read to work. Open Automation settings, find FMail in the list, and check the box next to Mail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")
                        ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Privacy & Security → Automation", systemImage: "lock.shield")
                }
                .controlSize(.small)
            }
            if let rfcId = self.message.rfcMessageId, !rfcId.isEmpty {
                Button {
                    _ = MailAppOpener.openMessage(rfcMessageId: rfcId)
                } label: {
                    Label("Open in Mail.app to download", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Wraps ReplyDraft for use with `.sheet(item:)`, which requires Identifiable.
private struct ReplyDraftWrapper: Identifiable, Equatable {
    let draft: ReplyDraft
    var id: Int { draft.originalMessage.rowId }
    static func == (lhs: ReplyDraftWrapper, rhs: ReplyDraftWrapper) -> Bool {
        lhs.draft == rhs.draft
    }
}
