import SwiftUI

struct ResearchInputsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var researchInputs: ResearchInputStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Add sources") {
                    ForEach(researchInputs.mustUseSources) { source in
                        MustUseSourceEditorRow(source: source)
                            .environmentObject(researchInputs)
                    }
                    .onDelete(perform: deleteSources)

                    Button("Add source") {
                        researchInputs.addBlankSource()
                    }
                }

                Section("Domain guidance") {
                    TextEditor(text: Binding(
                        get: { researchInputs.domainGuidance },
                        set: { researchInputs.updateDomainGuidance($0) }
                    ))
                    .frame(minHeight: 120)
                }
            }
            .navigationTitle("Research Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func deleteSources(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            researchInputs.mustUseSources.indices.contains(index) ? researchInputs.mustUseSources[index].id : nil
        }
        for id in ids {
            researchInputs.removeSource(id: id)
        }
    }
}

struct MustUseSourceEditorRow: View {
    @EnvironmentObject private var researchInputs: ResearchInputStore

    let source: MustUseSourceInput

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: binding(\.kind)) {
                ForEach(MustUseSourceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField(
                "https://...",
                text: binding(\.url),
                prompt: Text("Source URL")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField("Notes (optional)", text: binding(\.notes), axis: .vertical)
                .lineLimit(1 ... 3)
        }
        .padding(.vertical, 4)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MustUseSourceInput, Value>) -> Binding<Value> {
        Binding(
            get: { source[keyPath: keyPath] },
            set: { newValue in
                var updated = source
                updated[keyPath: keyPath] = newValue
                researchInputs.updateSource(updated)
            }
        )
    }
}
