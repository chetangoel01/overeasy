import SwiftUI

struct ImportRecoveryActions: View {
    let isRetrying: Bool
    let retry: () -> Void
    let chooseInput: (RecoveryInputMode) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Button(action: retry) {
                if isRetrying {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Retry import")
                }
            }
            .buttonStyle(LadlePrimaryButtonStyle())

            recoveryButton(
                "Add correction notes",
                systemImage: "text.bubble",
                mode: .correctionNotes
            )
            recoveryButton(
                "Paste recipe details",
                systemImage: "doc.on.clipboard",
                mode: .pastedDetails
            )
            recoveryButton(
                "Create manually",
                systemImage: "square.and.pencil",
                mode: .manual
            )
        }
        .disabled(isRetrying)
    }

    private func recoveryButton(
        _ title: String,
        systemImage: String,
        mode: RecoveryInputMode
    ) -> some View {
        Button {
            chooseInput(mode)
        } label: {
            Label(title, systemImage: systemImage)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
        }
    }
}
