import SwiftUI

enum RecoveryInputMode: String, Identifiable {
    case correctionNotes
    case pastedDetails
    case manual

    var id: String { rawValue }
}

struct CorrectionNotesView: View {
    @Environment(\.dismiss) private var dismiss

    let mode: RecoveryInputMode
    let submit: (_ correctionNotes: String?, _ pastedText: String?) -> Void

    @State private var title = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(mode.title)
                            .ladleFont(.title)
                            .foregroundStyle(LadleTheme.ink)
                        Text(mode.message)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink.opacity(0.64))
                    }

                    if mode == .manual {
                        TextField("Recipe title", text: $title)
                            .ladleFont(.body)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(
                                LadleTheme.field,
                                in: RoundedRectangle(
                                    cornerRadius: LadleTheme.Corner.control,
                                    style: .continuous
                                )
                            )
                            .accessibilityLabel("Recipe title")
                    }

                    TextEditor(text: $text)
                        .ladleFont(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 180)
                        .background(
                            LadleTheme.field,
                            in: RoundedRectangle(
                                cornerRadius: LadleTheme.Corner.control,
                                style: .continuous
                            )
                        )
                        .accessibilityLabel(mode.fieldLabel)

                    Button(mode.buttonTitle) {
                        switch mode {
                        case .correctionNotes:
                            submit(text, nil)
                        case .pastedDetails:
                            submit(nil, text)
                        case .manual:
                            submit(nil, "\(title)\n\(text)")
                        }
                        dismiss()
                    }
                    .buttonStyle(LadlePrimaryButtonStyle())
                    .disabled(
                        text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || (
                                mode == .manual
                                    && title.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    )
                }
                .padding(LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
    }
}

private extension RecoveryInputMode {
    var title: String {
        switch self {
        case .correctionNotes:
            "Add correction notes"
        case .pastedDetails:
            "Paste recipe details"
        case .manual:
            "Create manually"
        }
    }

    var message: String {
        switch self {
        case .correctionNotes:
            "Tell Ladle what the video says or what it missed."
        case .pastedDetails:
            "Paste a caption, ingredient list, or method to rescue the recipe."
        case .manual:
            "Keep the original link and create a simple recipe from what you know."
        }
    }

    var fieldLabel: String {
        switch self {
        case .correctionNotes:
            "Correction notes"
        case .pastedDetails:
            "Pasted recipe details"
        case .manual:
            "Recipe details"
        }
    }

    var buttonTitle: String {
        switch self {
        case .correctionNotes:
            "Retry with notes"
        case .pastedDetails:
            "Use pasted details"
        case .manual:
            "Create recipe"
        }
    }
}
