import SwiftUI

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    let accountSession: AccountSession
    let recipeCount: Int
    let installationID: String
    let signOut: @MainActor () async -> Void

    @State private var isSignOutConfirmationPresented = false
    @State private var isSigningOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountSection
                    storedDataSection
                    notTrackedSection
                    signOutSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Your account")

            infoRow(
                icon: "person",
                title: "Signed in as",
                value: accountStateTitle
            )
            infoRow(
                icon: "book.closed",
                title: "Recipes in your library",
                value: "\(recipeCount)"
            )
            infoRow(
                icon: "iphone",
                title: "Installation ID",
                value: shortInstallationID
            )
        }
    }

    private var storedDataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "What Overeasy stores")

            Text(
                """
                To make imports and sync work, Overeasy keeps:

                • The links you import and the recipes extracted from \
                them — ingredients, steps, timers, and estimated \
                nutrition — synced to your account.
                • A copy of each video's thumbnail, so your library \
                keeps its artwork after the original expires.
                • Correction notes and pasted recipe text you add \
                during recovery, stored encrypted and used only to \
                re-run your import.
                • An anonymous account identifier. Guests are keyed to \
                this install; Sign in with Apple adds only the \
                identifier Apple provides.
                """
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notTrackedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "What Overeasy doesn’t do")

            Text(
                """
                • No ads, no analytics SDKs, no selling or sharing \
                data with third parties.
                • No tracking across other apps or websites.
                • Timers, notifications, and Health export run \
                entirely on this device — nutrition leaves the app \
                only when you explicitly export a serving to Apple \
                Health.
                """
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isSignOutConfirmationPresented = true
            } label: {
                if isSigningOut {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 24)
                } else {
                    Text("Sign out")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .disabled(isSigningOut)
            .accessibilityIdentifier("account.sign-out")

            Text(
                "Signing out removes recipes from this device. Your synced library returns when you sign back in."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.55))
        }
        .confirmationDialog(
            "Sign out of Overeasy?",
            isPresented: $isSignOutConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                performSignOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Recipes are removed from this device but stay in your synced library."
            )
        }
    }

    private func performSignOut() {
        guard !isSigningOut else {
            return
        }
        isSigningOut = true
        Task { @MainActor in
            await signOut()
            isSigningOut = false
            dismiss()
        }
    }

    private var accountStateTitle: String {
        switch accountSession.state {
        case .undecided: "Not signed in"
        case .guest: "Guest"
        case .freeAccount: "Free account"
        case .signedInWithApple: "Apple account"
        }
    }

    private var shortInstallationID: String {
        String(installationID.prefix(8))
    }

    private func infoRow(
        icon: String,
        title: String,
        value: String
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 34, height: 34)
                .background(LadleTheme.review, in: Circle())
            Text(title)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink)
            Spacer()
            Text(value)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}
