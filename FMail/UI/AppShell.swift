import SwiftUI

struct AppShell: View {
    @State private var model = MailModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch model.loadState {
            case .idle, .bootstrapping:
                ProgressView("Opening index…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .indexing:
                IndexingProgressView(progress: model.indexProgress)
            case .fdaDenied:
                FullDiskAccessPrompt {
                    Task { await model.boot() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noMailData:
                ContentUnavailableView(
                    "No Mail data",
                    systemImage: "questionmark.folder",
                    description: Text("FMail couldn't find ~/Library/Mail. Set up Apple Mail first, then come back.")
                )
            case .failed(let msg):
                ContentUnavailableView(
                    "Failed to load",
                    systemImage: "xmark.octagon",
                    description: Text(msg)
                )
            case .ready:
                NavigationSplitView {
                    SidebarView(model: model)
                        .navigationTitle("FMail")
                        .frame(minWidth: 220, idealWidth: 260)
                } content: {
                    MessageListView(model: model, searchFocused: $searchFocused)
                        .frame(minWidth: 320, idealWidth: 420)
                        .navigationTitle(model.searchQuery.isEmpty ? model.sidebarTitle : "Search")
                } detail: {
                    ReaderView(model: model)
                        .frame(minWidth: 480)
                }
                .overlay(alignment: .bottom) {
                    footerStatus
                }
                .focusedSceneValue(\.mailModel, model)
            }
        }
        .task {
            await model.boot()
        }
        .background {
            // ⌘F focuses the search bar.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var footerStatus: some View {
        let showSync = model.indexProgress.stage != "Idle" && !model.indexProgress.stage.isEmpty
        let showBody = model.bodyIndexProgress.total > 0 &&
                       model.bodyIndexProgress.done < model.bodyIndexProgress.total &&
                       model.bodyIndexProgress.stage != "Idle"
        if showSync || showBody {
            VStack(alignment: .leading, spacing: 4) {
                if showSync {
                    IndexingFooterView(progress: model.indexProgress, label: "Syncing")
                }
                if showBody {
                    BodyIndexFooterView(progress: model.bodyIndexProgress)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
        }
    }
}

private struct IndexingProgressView: View {
    let progress: IndexProgress

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Building index for the first time")
                .font(.title2)
            Text("FMail is mirroring Apple Mail's metadata into its own SQLite database for faster search and accurate counts. This usually takes a couple of minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            VStack(spacing: 6) {
                Text(progress.stage)
                    .font(.headline)
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .progressViewStyle(.linear)
                        .frame(width: 360)
                    Text("\(progress.done.formatted()) / \(progress.total.formatted())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 360)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IndexingFooterView: View {
    let progress: IndexProgress
    var label: String = ""

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            if !label.isEmpty {
                Text(label).font(.caption.bold())
            }
            Text(progress.stage)
                .font(.caption)
            if progress.total > 0 {
                Text("(\(progress.done.formatted()) / \(progress.total.formatted()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BodyIndexFooterView: View {
    let progress: BodyIndexProgress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Body index")
                .font(.caption.bold())
            Text("\(progress.done.formatted()) / \(progress.total.formatted())")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

extension FocusedValues {
    @Entry var mailModel: MailModel?
}
