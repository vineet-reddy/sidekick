import SwiftData
import SwiftUI

struct NoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @StateObject private var speech = SpeechRecognizerService()
    @State private var content: String
    @State private var seedContent = ""

    let mode: DraftMode

    init(mode: DraftMode) {
        self.mode = mode
        switch mode {
        case .create:
            _content = State(initialValue: "")
        case let .edit(note):
            _content = State(initialValue: note.content)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SidekickBackground()

                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(mode.isCreate ? "Fresh idea" : "Refine note")
                            .font(.system(.title2, design: .rounded, weight: .bold))

                        Text("Keep it rough. The AI backend should be invisible here.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $content)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 320)
                            .background(Color.clear)

                        HStack {
                            Button {
                                toggleDictation()
                            } label: {
                                Label(
                                    speech.isListening ? "Stop dictation" : "Dictate",
                                    systemImage: speech.isListening ? "stop.circle.fill" : "waveform.circle.fill"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(speech.isListening ? .red : SidekickTheme.accent)

                            Spacer()

                            Text("\(content.count) chars")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage = speech.errorMessage, !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .glassCard()

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .navigationTitle(mode.isCreate ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        speech.stop()
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
        }
    }

    private func toggleDictation() {
        if speech.isListening {
            speech.stop()
            return
        }

        seedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await speech.start { transcript in
                if seedContent.isEmpty {
                    content = transcript
                } else {
                    content = seedContent + "\n" + transcript
                }
            }
        }
    }

    private func save() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        switch mode {
        case .create:
            let note = Note(content: trimmed, createdAt: .now, updatedAt: .now)
            modelContext.insert(note)
        case let .edit(note):
            note.content = trimmed
            note.updatedAt = .now
        }

        try? modelContext.save()
        speech.stop()
        dismiss()
    }
}
