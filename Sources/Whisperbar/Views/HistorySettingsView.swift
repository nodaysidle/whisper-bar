import SwiftUI

// MARK: - History Tab

struct HistorySettingsView: View {
    @Bindable var controller: MenuBarController
    @State private var deletingRecord: TranscriptRecord?

    var body: some View {
        Form {
            Section("Offline search") {
                HStack {
                    TextField("Search transcripts", text: $controller.historyQuery)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(MenuControlID.historySearch)
                        .accessibilityLabel("Search transcripts")
                        .onSubmit {
                            Task { _ = await controller.searchHistory(controller.historyQuery) }
                        }
                    Button("Search") {
                        Task { _ = await controller.searchHistory(controller.historyQuery) }
                    }
                    .accessibilityLabel("Search local history")
                    Button("Show recent") {
                        Task { _ = await controller.searchHistory("") }
                    }
                    .accessibilityLabel("Show the recent transcripts")
                    Button("Reload") {
                        Task { _ = await controller.reloadHistory() }
                    }
                    .accessibilityIdentifier(MenuControlID.historyReload)
                    .accessibilityLabel("Reload local history")
                }

                Text(controller.storageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let feedback = controller.historyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Transcripts (\(controller.historyTranscripts.count))") {
                if controller.historyTranscripts.isEmpty {
                    Text("No stored transcript matches. Local history is bounded, offline-only, and never uploaded or synced anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.historyTranscripts) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.text)
                            .font(.callout)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("\(record.provider.displayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy") {
                                _ = controller.copyHistoryEntry(id: record.id)
                            }
                            .accessibilityIdentifier("\(MenuControlID.historyCopy).\(record.id)")
                            .accessibilityLabel("Copy transcript from \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")

                            Button("Delete") {
                                deletingRecord = record
                            }
                            .accessibilityIdentifier("\(MenuControlID.historyDelete).\(record.id)")
                            .accessibilityLabel("Delete transcript from \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete Transcript?",
            isPresented: Binding(
                get: { deletingRecord != nil },
                set: { if !$0 { deletingRecord = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete from History", role: .destructive) {
                if let record = deletingRecord {
                    Task { _ = await controller.deleteHistoryEntry(id: record.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete this transcript from local history? This cannot be undone.")
        }
    }
}
