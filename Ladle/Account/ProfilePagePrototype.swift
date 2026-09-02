import SwiftUI

/// Variant B of issue #62: the profile as a page pushed onto the current
/// tab's stack, person first, with the settings behind a single row.
///
/// Throwaway prototype. The library rows go nowhere on purpose — what is
/// being judged is whether the facts read better as rows than as one line,
/// and whether the accent picker is far enough away to hurt.
struct ProfilePagePrototype: View {
    let accountSession: AccountSession
    let library: LibraryViewModel
    var authClient: AuthClient?
    var googleSignIn: (any GoogleSignInProviding)?
    var onAuthenticated: @MainActor () async -> Void = {}
    var signOut: @MainActor () async -> Void = {}
    var deleteAccount: @MainActor () async throws -> Void = {}

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Form {
            heroSection
            librarySection
            settingsSection
            accountSection
        }
        .listRowBackground(LadleTheme.Surface.raised)
        .scrollContentBackground(.hidden)
        .background(LadleTheme.Surface.porcelain)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Sign out of Overeasy?",
            isPresented: $isSignOutConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { @MainActor in await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Recipes are removed from this device but stay in your synced library."
            )
        }
        .alert(
            "Delete your Overeasy account?",
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button("Delete Account", role: .destructive) {
                Task { @MainActor in try? await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your synced recipes and account data will be permanently deleted. This can\u{2019}t be undone."
            )
        }
    }

    /// The hero sits in a section with no background and no insets, so the
    /// porcelain runs behind it and the grouped rows start below — the same
    /// treatment the header section has in the sheet today.
    private var heroSection: some View {
        Section {
            ProfileIdentityView(
                accountSession: accountSession,
                library: library,
                diameter: 112,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: onAuthenticated
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var librarySection: some View {
        Section("Your library") {
            libraryRow("Saved recipes", value: library.recipes.count)
            libraryRow("Favorites", value: favoriteCount)
            // No fixture has been cooked, so this one is a stand-in for the
            // count the real page would read off `lastCookedAt`.
            libraryRow("Recently cooked", value: 1)
        }
    }

    private func libraryRow(_ title: String, value: Int) -> some View {
        NavigationLink {
            ProfilePlaceholderPagePrototype(title: title)
        } label: {
            LabeledContent(title, value: "\(value)")
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink {
                ProfileSettingsPagePrototype()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("account.settings")
        }
    }

    private var accountSection: some View {
        Section {
            Button("Sign out") {
                isSignOutConfirmationPresented = true
            }
            .foregroundStyle(LadleTheme.Intent.destructive)
            .accessibilityIdentifier("account.sign-out")

            Button("Delete account", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
            .accessibilityIdentifier("account.delete")
        } header: {
            Text("Account")
        } footer: {
            Text(
                "Signing out keeps your synced library in Overeasy. Deleting removes it permanently."
            )
        }
    }

    private var favoriteCount: Int {
        library.recipes.filter(\.isFavorite).count
    }
}

/// The settings, one push behind the profile: everything from today's sheet
/// that is not the cook or their library.
struct ProfileSettingsPagePrototype: View {
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue

    var body: some View {
        Form {
            appearanceSection
            privacySection
        }
        .listRowBackground(LadleTheme.Surface.raised)
        .scrollContentBackground(.hidden)
        .background(LadleTheme.Surface.porcelain)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceSection: some View {
        Section {
            HStack(spacing: LadleTheme.Spacing.compact) {
                ForEach(LadleAccentColor.allCases) { option in
                    Button {
                        accentColor = option.rawValue
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.actionColor)
                            if selectedAccent == option {
                                Image(systemName: "checkmark")
                                    .font(
                                        .system(
                                            size: LadleTheme.IconSize.small,
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(LadleTheme.Label.onAccent)
                            }
                        }
                        .frame(
                            width: LadleTheme.Control.hitTarget,
                            height: LadleTheme.Control.hitTarget
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LadlePressButtonStyle())
                    .accessibilityLabel(option.title)
                    .accessibilityValue(
                        selectedAccent == option ? "Selected" : ""
                    )
                }
            }
            .padding(.vertical, LadleTheme.Spacing.tight)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Tints buttons, favorites, and the selected tab.")
        }
        .sensoryFeedback(.selection, trigger: accentColor)
    }

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacyDetailView()
            } label: {
                Label("Privacy & data", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("account.privacy")
        } footer: {
            Text("What Overeasy stores, and what it never does.")
        }
    }

    private var selectedAccent: LadleAccentColor {
        LadleAccentColor.resolve(storedValue: accentColor)
    }
}

/// Where the library rows land in the prototype. A real page would show the
/// recipes behind the count; this one only says so.
struct ProfilePlaceholderPagePrototype: View {
    let title: String

    var body: some View {
        VStack {
            Text("This row is not wired up in the prototype.")
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(LadleTheme.Layout.screenMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LadleTheme.Surface.porcelain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
