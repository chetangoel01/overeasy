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
                        .tint(LadleTheme.Label.onAccent)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Retry import")
                }
            }
            .buttonStyle(LadleButtonStyle(role: .primary))

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
            HStack(spacing: LadleTheme.Layout.iconGap) {
                Image(systemName: systemImage)
                    .font(
                        .system(
                            size: LadleTheme.IconSize.large,
                            weight: .semibold
                        )
                    )
                    .frame(width: LadleTheme.IconSize.feature)
                Text(title)
                    .accessibilityIdentifier(
                        "import.recovery.\(mode.rawValue).label"
                    )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
        }
        .buttonStyle(LadleButtonStyle(role: .secondary))
    }
}
