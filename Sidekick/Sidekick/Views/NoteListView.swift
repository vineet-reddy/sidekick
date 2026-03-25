import SwiftData
import SwiftUI

struct NoteListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var heartbeat: HeartbeatManager
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    @State private var searchText = ""
    @State private var editingNote: Note?
    @State private var newNoteText = ""
    @FocusState private var isNewNoteFocused: Bool
    @State private var prioritizedNoteID: UUID?

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
                LazyVStack(spacing: 12) {
                    if filteredNotes.isEmpty && newNoteText.isEmpty {
                        Text("Jot something down below to get started.")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }

                    ForEach(filteredNotes) { note in
                        noteCard(for: note)
                            .offset(x: 0, y: prioritizedNoteID == note.id ? -6 : 0)
                            .animation(.spring(response: 0.3), value: prioritizedNoteID)
                            .onTapGesture {
                                editingNote = note
                            }
                            .contextMenu {
                                Button(note.priorityRequestedAt == nil ? "Prioritize" : "Prioritized") {
                                    prioritize(note)
                                }
                                .disabled(note.priorityRequestedAt != nil)

                                Button("Edit") {
                                    editingNote = note
                                }

                                Button("Delete", role: .destructive) {
                                    delete(note)
                                }
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 30, coordinateSpace: .local)
                                    .onEnded { value in
                                        if value.translation.height < -40 &&
                                            abs(value.translation.width) < abs(value.translation.height) {
                                            prioritize(note)
                                        }
                                    }
                            )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }

            VStack {
                Spacer()
                inlineComposer
            }
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    runHeartbeatNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("notes.syncButton")
                .accessibilityLabel("Run sync now")
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditorView(note: note)
        }
    }

    private var inlineComposer: some View {
        HStack(spacing: 12) {
            TextField("Just start typing...", text: $newNoteText, axis: .vertical)
                .lineLimit(1...4)
                .focused($isNewNoteFocused)
                .onSubmit {
                    commitNewNote()
                }
                .accessibilityIdentifier("notes.composerField")

            if !newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    commitNewNote()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(SidekickTheme.accent)
                }
                .accessibilityIdentifier("notes.sendButton")
                .accessibilityLabel("Save note")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(SidekickTheme.edge, lineWidth: 1)
        )
        .shadow(color: SidekickTheme.shadow, radius: 12, x: 0, y: -4)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityIdentifier("notes.inlineComposer")
    }

    private func noteCard(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Text(note.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    prioritize(note)
                } label: {
                    Image(systemName: note.priorityRequestedAt == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(note.priorityRequestedAt == nil ? SidekickTheme.accent : .green)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("note.prioritize.\(note.id.uuidString)")
                .accessibilityLabel(note.priorityRequestedAt == nil ? "Prioritize note" : "Note prioritized")
            }

            if note.content.split(separator: "\n").count > 1 || note.content.count > 64 {
                Text(note.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("note.card.\(note.id.uuidString)")
    }

    private func commitNewNote() {
        let trimmed = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let note = Note(content: trimmed, createdAt: .now, updatedAt: .now)
        modelContext.insert(note)
        try? modelContext.save()
        newNoteText = ""
        isNewNoteFocused = false
        scheduleHeartbeat()
    }

    private func prioritize(_ note: Note) {
        prioritizedNoteID = note.id
        note.priorityRequestedAt = .now
        try? modelContext.save()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            prioritizedNoteID = nil
        }

        Task {
            await heartbeat.run(modelContext: modelContext, force: true)
        }
    }

    private func scheduleHeartbeat() {
        Task {
            try? await Task.sleep(for: .seconds(30))
            await heartbeat.run(modelContext: modelContext, force: true)
        }
    }

    private func runHeartbeatNow() {
        Task {
            await heartbeat.run(modelContext: modelContext, force: true)
        }
    }

    private func delete(_ note: Note) {
        try? ContentDeletionService.deleteNote(note, modelContext: modelContext)
    }
}
