import SwiftUI

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let accountSession: AccountSession
    let library: LibraryViewModel
    let installationID: String
    let signOut: @MainActor () async -> Void
    let deleteAccount: @MainActor () async throws -> Void

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var deletionErrorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: LadleTheme.Spacing.cooking
                ) {
                    accountSection
                    privacySection
                    signOutSection
                    deleteAccountSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.top, LadleTheme.Spacing.regular)
                .padding(.bottom, LadleTheme.Spacing.cooking)
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

            VStack(spacing: 0) {
                infoRow(
                    icon: "person",
                    title: "Signed in as",
                    value: accountStateTitle
                )
                accountDivider
                infoRow(
                    icon: "book.closed",
                    title: "Recipes in your library",
                    value: "\(library.recipes.count)"
                )
                accountDivider
                infoRow(
                    icon: "iphone",
                    title: "Installation ID",
                    value: shortInstallationID
                )
            }
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
                .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var deleteAccountSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Text(
                "Deleting your account permanently removes your synced recipes and account data."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                if isDeletingAccount {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 24)
                } else {
                    Text("Delete account")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .tint(.red)
            .disabled(isDeletingAccount)
            .accessibilityIdentifier("account.delete")
        }
        .alert(
            "Delete your Overeasy account?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete Account", role: .destructive) {
                performAccountDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your synced recipes and account data will be permanently deleted. This can’t be undone."
            )
        }
        .alert(
            "Account could not be deleted",
            isPresented: Binding(
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                deletionErrorMessage
                    ?? "Please check your connection and try again."
            )
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Privacy")

            NavigationLink {
                PrivacyDetailView()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LadleTheme.paprika)
                        .frame(width: 34, height: 34)
                        .background(LadleTheme.review, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy & data")
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink)
                        Text("What Overeasy stores, and what it never does")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.mutedInk)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 56)
                .background(
                    LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                    .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.privacy")
        }
    }

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Divider()
                .overlay(LadleTheme.ink.opacity(0.1))

            Text(
                "Signing out removes recipes from this device. Your synced library returns when you sign back in."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)

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

    private func performAccountDeletion() {
        guard !isDeletingAccount else {
            return
        }
        isDeletingAccount = true
        Task { @MainActor in
            do {
                try await deleteAccount()
                dismiss()
            } catch {
                isDeletingAccount = false
                deletionErrorMessage =
                    "Please check your connection and try again."
            }
        }
    }

    private var accountStateTitle: String {
        switch accountSession.state {
        case .undecided: "Not signed in"
        case .guest: "Guest"
        case .freeAccount: "Free account"
        case .signedInWithApple: "Apple account"
        case .signedInWithGoogle: "Google account"
        }
    }

    private var shortInstallationID: String {
        String(installationID.prefix(8))
    }

    private var accountDivider: some View {
        Divider()
            .overlay(LadleTheme.ink.opacity(0.08))
            .padding(.leading, 61)
    }

    private func infoRow(
        icon: String,
        title: String,
        value: String
    ) -> some View {
        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
            spacing: 13
        ) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 34, height: 34)
                .background(LadleTheme.review, in: Circle())

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    infoTitle(title)
                    infoValue(value)
                }
            } else {
                infoTitle(title)
                Spacer(minLength: LadleTheme.Spacing.compact)
                infoValue(value)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private func infoTitle(_ title: String) -> some View {
        Text(title)
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink)
    }

    private func infoValue(_ value: String) -> some View {
        Text(value)
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink.opacity(0.75))
    }

}
