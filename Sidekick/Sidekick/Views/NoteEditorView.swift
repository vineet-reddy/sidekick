import SwiftData
import SwiftUI

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var content: String
    @FocusState private var isFocused: Bool

    let note: Note

    init(note: Note) {
        self.note = note
        _content = State(initialValue: note.content)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidekickBackground()

                TextEditor(text: $content)
                    .scrollContentBackground(.hidden)
                    .padding(20)
                    .focused($isFocused)
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        note.content = trimmed
        note.updatedAt = .now
        try? modelContext.save()
        dismiss()
    }
}
