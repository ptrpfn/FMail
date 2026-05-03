import SwiftUI

/// Modal sheet shown before handing a reply off to Mail.app. Lets the user
/// confirm (or correct) the recipient address — the wrong-address-catching
/// mechanic from the spec.
struct ReplyConfirmationSheet: View {
    @Bindable var model: MailModel
    let draft: ReplyDraft
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTo: String
    @State private var showPicker: Bool = false
    @State private var makePreferred: Bool = false
    @State private var blockOriginal: Bool = false

    init(model: MailModel, draft: ReplyDraft) {
        self.model = model
        self.draft = draft
        self._selectedTo = State(initialValue: draft.suggestedToAddress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())

            recipientBlock

            if let from = draft.ourAddress {
                row(label: "From") {
                    Text(from)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                row(label: "From") {
                    Text("(Mail.app will pick the account)")
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            row(label: "Subject") {
                Text(subjectPreview).textSelection(.enabled)
            }

            preferencesBlock

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelReply()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open in Mail.app") {
                    model.sendReply(
                        toAddress: selectedTo,
                        makePreferred: makePreferred && selectedTo != draft.suggestedToAddress,
                        blockOriginal: blockOriginal
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.kind != .forward && selectedTo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var title: String {
        switch draft.kind {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }

    private var subjectPreview: String {
        let prefix: String
        switch draft.kind {
        case .reply, .replyAll: prefix = "Re: "
        case .forward: prefix = "Fwd: "
        }
        let s = draft.originalMessage.subject
        if s.lowercased().hasPrefix(prefix.lowercased()) { return s }
        return prefix + s
    }

    @ViewBuilder
    private var recipientBlock: some View {
        switch draft.kind {
        case .forward:
            row(label: "To") {
                Text("Type a recipient in Mail.app.")
                    .foregroundStyle(.secondary)
                    .italic()
            }
        case .reply, .replyAll:
            row(label: "To") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(selectedTo)
                            .textSelection(.enabled)
                        if let contact = draft.resolvedContact {
                            Text("· \(contact.displayName)")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        if draft.candidateAddresses.count > 1 {
                            Spacer()
                            Button(showPicker ? "Hide options" : "Use different address…") {
                                showPicker.toggle()
                            }
                            .controlSize(.small)
                        }
                    }
                    if showPicker {
                        addressPicker
                    }
                }
            }
            if draft.kind == .replyAll, let cc = ccPreview, !cc.isEmpty {
                row(label: "Cc") {
                    Text(cc).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                }
            }
        }
    }

    @ViewBuilder
    private var addressPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(draft.candidateAddresses, id: \.self) { addr in
                HStack {
                    Image(systemName: addr.lowercased() == selectedTo.lowercased() ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(addr.lowercased() == selectedTo.lowercased() ? Color.accentColor : .secondary)
                    Text(addr)
                        .font(.callout.monospaced())
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedTo = addr
                }
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var preferencesBlock: some View {
        if draft.resolvedContact != nil, draft.kind != .forward, draft.candidateAddresses.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $makePreferred) {
                    Text("Always reply to **\(selectedTo)** for this contact")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                .disabled(selectedTo.lowercased() == draft.suggestedToAddress.lowercased())

                if selectedTo.lowercased() != draft.originalMessage.senderAddress.lowercased() {
                    Toggle(isOn: $blockOriginal) {
                        Text("Hide **\(draft.originalMessage.senderAddress)** from future suggestions")
                            .font(.callout)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var ccPreview: String? {
        guard draft.kind == .replyAll else { return nil }
        let to = draft.originalBody?.headers["to"].map { EncodedWord.decode($0) } ?? ""
        let cc = draft.originalBody?.headers["cc"].map { EncodedWord.decode($0) } ?? ""
        return [to, cc].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.secondary)
                .font(.callout)
            content()
            Spacer()
        }
    }
}
