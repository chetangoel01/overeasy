import SwiftUI

struct ImportRecoveryActions: View {
    @Environment(\.ladleAccent) private var accent

    let isRetrying: Bool
    let retryAvailability: ImportRetryAvailability
    var layout: ImportRecoveryLayout = .retryFirst
    let retry: () -> Void
    let chooseInput: (RecoveryInputMode) -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Layout.rowGap) {
            switch layout {
            case .retryFirst:
                retryAction(role: .primary)
                correctionNotesButton
                pastedDetailsButton()
                manualButton()
            case .manualEntryFirst:
                // Nothing was left unread, so retry is not the way out: the
                // two ways the cook can supply the recipe lead, and retry
                // follows them as a row like any other.
                pastedDetailsButton(role: .primary)
                manualButton()
                correctionNotesButton
                retryAction(role: .secondary)
            }
        }
    }

    private var correctionNotesButton: some View {
        recoveryButton(
            "Add correction notes",
            systemImage: "text.bubble",
            mode: .correctionNotes
        )
    }

    private func pastedDetailsButton(
        role: LadleButtonRole = .secondary
    ) -> some View {
        recoveryButton(
            "Paste recipe details",
            systemImage: "doc.on.clipboard",
            mode: .pastedDetails,
            role: role
        )
    }

    private func manualButton(
        role: LadleButtonRole = .secondary
    ) -> some View {
        recoveryButton(
            "Create manually",
            systemImage: "square.and.pencil",
            mode: .manual,
            role: role
        )
    }

    @ViewBuilder
    private func retryAction(role: LadleButtonRole) -> some View {
        if case .after = retryAvailability {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                retryButton(at: context.date, role: role)
            }
        } else {
            retryButton(at: .now, role: role)
        }
    }

    private func retryButton(
        at date: Date,
        role: LadleButtonRole
    ) -> some View {
        Button(action: retry) {
            if isRetrying {
                ProgressView()
                    // The spinner takes the label colour its own role would
                    // have used; onAccent white on a raised fill is invisible.
                    .tint(role.label(accent))
                    .frame(maxWidth: .infinity)
            } else if role == .primary {
                Text(retryAvailability.buttonTitle(at: date))
            } else {
                // Demoted, retry joins the column of recovery rows and takes
                // their icon and shared label origin rather than sitting
                // centred among them.
                rowLabel(
                    retryAvailability.buttonTitle(at: date),
                    systemImage: "arrow.clockwise",
                    identifier: "import.recovery.retry.label"
                )
            }
        }
        .buttonStyle(LadleButtonStyle(role: role))
        .disabled(
            isRetrying || !retryAvailability.allowsRetry(at: date)
        )
    }

    private func recoveryButton(
        _ title: String,
        systemImage: String,
        mode: RecoveryInputMode,
        role: LadleButtonRole = .secondary
    ) -> some View {
        Button {
            chooseInput(mode)
        } label: {
            rowLabel(
                title,
                systemImage: systemImage,
                identifier: "import.recovery.\(mode.rawValue).label"
            )
        }
        .buttonStyle(LadleButtonStyle(role: role))
        .disabled(isRetrying)
    }

    private func rowLabel(
        _ title: String,
        systemImage: String,
        identifier: String
    ) -> some View {
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
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LadleTheme.Layout.cardPadding)
    }
}
