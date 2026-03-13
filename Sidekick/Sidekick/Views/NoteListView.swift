import SwiftData
import SwiftUI

struct NoteListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    @State private var searchText = ""
    @State private var draftMode: DraftMode?

    private var filteredNotes: [Note] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return notes
        }

        return notes.filter {
            $0.content.localizedCaseInsensitiveContains(searchText) ||
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            SidekickBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionHeader(
                        eyebrow: "Research notes",
                        title: "Capture sparks before they vanish",
                        subtitle: "Write fragments fast. Sidekick clusters them quietly in the background."
                    )

                    if filteredNotes.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(filteredNotes) { note in
                                Button {
                                    draftMode = .edit(note)
                                } label: {
                                    noteCard(for: note)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Edit") {
                                        draftMode = .edit(note)
                                    }

                                    Button("Delete", role: .destructive) {
                                        delete(note)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    draftMode = .create
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SidekickTheme.accent)
                }
            }
        }
        .sheet(item: $draftMode) { mode in
            NoteEditorView(mode: mode)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("No notes yet")
                .font(.title3.weight(.semibold))
            Text("Start with messy thoughts, half-baked hypotheses, or voice memos from the hallway.")
                .foregroundStyle(.secondary)
            Button("Write your first note") {
                draftMode = .create
            }
            .buttonStyle(.borderedProminent)
            .tint(SidekickTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 24)
    }

    private func noteCard(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Spacer()

                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(note.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func delete(_ note: Note) {
        modelContext.delete(note)
        try? modelContext.save()
    }
}

enum DraftMode: Identifiable {
    case create
    case edit(Note)

    var id: String {
        switch self {
        case .create:
            return "create"
        case let .edit(note):
            return note.id.uuidString
        }
    }

    var isCreate: Bool {
        if case .create = self {
            return true
        }

        return false
    }
}
