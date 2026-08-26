import SwiftUI

struct ImportRecoveryActions: View {
    let isRetrying: Bool
    let retry: () -> Void
    let chooseInput: (RecoveryInputMode) -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Layout.rowGap) {
            Button(action: retry) {
                if isRetrying {
                    ProgressView()
                        .tint(LadleTheme.onAccent)
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
                    LadleTheme.Surface.raised,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
        }
    }
}
