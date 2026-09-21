import SwiftUI

// MARK: - Modes and Vocabulary Tab

struct ModesSettingsView: View {
    @Bindable var controller: MenuBarController

    @State private var editorModeID: String?
    @State private var modeName = ""
    @State private var modeInstructions = ""
    @State private var modeIsDefault = false
    @State private var newTerm = ""
    @State private var deletingModeID: String?
    @State private var deletingModeName: String = ""

    var body: some View {
        Form {
            Section("Writing modes") {
                if controller.writingModes.isEmpty {
                    Text("No writing mode is stored yet. Add one below; without a mode the locked default behavior applies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.writingModes) { mode in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(mode.name)
                                    .font(.callout)
                                if mode.isDefault {
                                    Text("default")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if controller.selectedWritingModeID == mode.id {
                                    Text("selected")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(mode.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                        Button("Select") {
                            _ = controller.selectWritingMode(id: mode.id)
                        }
                        .accessibilityLabel("Select the \(mode.name) writing mode")
                        Button("Edit") {
                            editorModeID = mode.id
                            modeName = mode.name
                            modeInstructions = mode.instructions
                            modeIsDefault = mode.isDefault
                        }
                        .accessibilityLabel("Edit the \(mode.name) writing mode")
                        Button("Delete") {
                            deletingModeID = mode.id
                            deletingModeName = mode.name
                        }
                        .accessibilityIdentifier("\(MenuControlID.modeDelete).\(mode.id)")
                        .accessibilityLabel("Delete the \(mode.name) writing mode")
                    }
                }
                HStack {
                    Button("Use the locked default behavior") {
                        _ = controller.selectWritingMode(id: nil)
                    }
                    .accessibilityLabel("Clear the selected writing mode")
                    Button("Reload from storage") {
                        Task { _ = await controller.reloadWritingConfiguration() }
                    }
                    .accessibilityLabel("Reload writing modes and vocabulary")
                }
                if let feedback = controller.writingFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(editorModeID == nil ? "New writing mode" : "Edit writing mode") {
                TextField("Name", text: $modeName)
                    .accessibilityIdentifier(MenuControlID.modeName)
                    .accessibilityLabel("Writing mode name")
                TextField("Instructions", text: $modeInstructions, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier(MenuControlID.modeInstructions)
                    .accessibilityLabel("Writing mode instructions")
                Toggle("Use as the stored default mode", isOn: $modeIsDefault)
                    .accessibilityLabel("Store as the default writing mode")
                HStack {
                    Button("Save mode") {
                        Task {
                            let saved = await controller.saveWritingMode(
                                id: editorModeID,
                                name: modeName,
                                instructions: modeInstructions,
                                isDefault: modeIsDefault
                            )
                            if saved {
                                editorModeID = nil
                                modeName = ""
                                modeInstructions = ""
                                modeIsDefault = false
                            }
                        }
                    }
                    .disabled(modeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || modeInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(MenuControlID.modeSave)
                    .accessibilityLabel("Save the writing mode")

                    Button("Clear editor") {
                        editorModeID = nil
                        modeName = ""
                        modeInstructions = ""
                        modeIsDefault = false
                    }
                    .accessibilityLabel("Clear the writing mode editor")
                }
            }

            Section("Vocabulary") {
                HStack {
                    TextField("Term", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(MenuControlID.vocabularyField)
                        .accessibilityLabel("Vocabulary term")
                    Button("Add term") {
                        let term = newTerm
                        Task {
                            if await controller.addVocabularyTerm(term) {
                                newTerm = ""
                            }
                        }
                    }
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(MenuControlID.vocabularyAdd)
                    .accessibilityLabel("Add the vocabulary term")
                }
                if controller.vocabularyTerms.isEmpty {
                    Text("No vocabulary term is stored yet. Added terms are fed deterministically into transcription requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(controller.vocabularyTerms) { term in
                    HStack {
                        Text(term.term)
                            .font(.callout)
                        Spacer()
                        Button("Remove") {
                            Task { _ = await controller.removeVocabularyTerm(id: term.id) }
                        }
                        .accessibilityIdentifier("\(MenuControlID.vocabularyRemove).\(term.id)")
                        .accessibilityLabel("Remove the \(term.term) vocabulary term")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete Writing Mode?",
            isPresented: Binding(
                get: { deletingModeID != nil },
                set: { if !$0 { deletingModeID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Mode", role: .destructive) {
                if let id = deletingModeID {
                    Task { _ = await controller.deleteWritingMode(id: id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete the writing mode \"\(deletingModeName)\"?")
        }
    }
}
