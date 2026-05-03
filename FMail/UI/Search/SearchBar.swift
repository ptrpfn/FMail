import SwiftUI

struct SearchBar: View {
    @Bindable var model: MailModel
    @FocusState.Binding var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Search — try `from:kyoko after:2024-01-01 -draft`",
                    text: Binding(
                        get: { model.searchQuery },
                        set: { newValue in model.updateSearch(newValue) }
                    )
                )
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand {
                    model.clearSearch()
                    focused = false
                }
                .onSubmit {
                    model.updateSearch(model.searchQuery)
                }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if !model.searchInterpretation.isEmpty {
                interpretedStrip
            }
        }
    }

    @ViewBuilder
    private var interpretedStrip: some View {
        HStack(spacing: 4) {
            Text("Interpreted as")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(model.searchInterpretation)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1), in: Capsule())
                .lineLimit(1)
            Spacer()
            if model.bodyIndexProgress.total > 0 && model.bodyIndexProgress.done < model.bodyIndexProgress.total {
                Text("body index \(model.bodyIndexProgress.done.formatted())/\(model.bodyIndexProgress.total.formatted())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
