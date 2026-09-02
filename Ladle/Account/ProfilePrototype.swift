import SwiftUI

/// Throwaway prototypes for issue #62 — the two Profile directions and the
/// name step, built so the shapes can be looked at before one is chosen.
///
/// Nothing in this file or its siblings ships: the switch is honoured only
/// alongside `-ui-testing`, and every shipping path behaves as it did.
enum ProfilePrototype: String {
    /// The profile stays the sheet it is today, with the settings inline
    /// under a header led by the cook.
    case a
    /// The profile is a pushed page, person first, with the settings behind
    /// a single row.
    case b
    /// The sign-up name step, shown full screen in place of the library.
    case name

    private static let argument = "-profile-prototype"

    init?(launchArguments: [String]) {
        guard
            launchArguments.contains("-ui-testing"),
            let index = launchArguments.firstIndex(of: Self.argument),
            launchArguments.indices.contains(index + 1),
            let prototype = Self(rawValue: launchArguments[index + 1])
        else {
            return nil
        }
        self = prototype
    }
}

/// The one line of facts under the name: what a cook would recognise as
/// theirs. The counts come from the library on screen; the month is fixed,
/// because the account's creation date is not on the wire yet.
enum ProfileFacts {
    static let firstMonth = "August 2026"

    @MainActor
    static func line(
        for state: AccountState,
        library: LibraryViewModel
    ) -> String {
        let recipes = library.recipes.count
        switch state {
        case .undecided, .guest:
            return "\(count(recipes, "recipe")) on this device"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            let favorites = library.recipes.filter(\.isFavorite).count
            return [
                count(recipes, "recipe"),
                count(favorites, "favorite"),
                "cooking since \(firstMonth)",
            ]
            .joined(separator: " · ")
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// The cook, at the top of both directions: a large avatar, the name in the
/// title face, the provider line, and the facts line.
///
/// The 64-point header this grows out of is a row that happens to come
/// first. At 96 and 112 the avatar is the subject of the screen, so the
/// initials grow with it — a `recipeTitle` monogram inside a 96-point circle
/// reads as a badge someone forgot to fill.
struct ProfileIdentityView: View {
    let accountSession: AccountSession
    let library: LibraryViewModel
    var diameter: CGFloat = 96

    @State private var flow: AccountSignInFlow
    @State private var isSignInPresented = false

    init(
        accountSession: AccountSession,
        library: LibraryViewModel,
        diameter: CGFloat = 96,
        authClient: AuthClient? = nil,
        googleSignIn: (any GoogleSignInProviding)? = nil,
        onAuthenticated: @escaping @MainActor () async -> Void = {}
    ) {
        self.accountSession = accountSession
        self.library = library
        self.diameter = diameter
        _flow = State(
            initialValue: AccountSignInFlow(
                accountSession: accountSession,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            if isSignedIn {
                avatar
                identity
            } else {
                guestIdentity

                Button("Sign in") { isSignInPresented = true }
                    .buttonStyle(LadleButtonStyle(role: .secondary))
                    .padding(.horizontal, LadleTheme.Layout.sheetMargin)
                    .accessibilityIdentifier("account.profile.sign-in")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LadleTheme.Layout.sectionGap)
        .sheet(isPresented: $isSignInPresented) {
            signInSheet
        }
    }

    private var identity: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text(displayedName)
                .ladleFont(.title)
                .foregroundStyle(
                    accountSession.profile?.displayName == nil
                        ? LadleTheme.Label.secondary
                        : LadleTheme.Label.primary
                )
                .multilineTextAlignment(.center)

            Text(AccountSheet.accountTitle(for: accountSession.state))
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)

            factsLine
                .padding(.top, LadleTheme.Spacing.tight)
        }
        .padding(.horizontal, LadleTheme.Layout.sheetMargin)
    }

    /// A guest has no photo and no name, and inventing either would only
    /// look broken — but the word sits in the face the name would, so the
    /// header reads as one design in both states.
    private var guestIdentity: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text("Guest")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)

            factsLine
                .padding(.top, LadleTheme.Spacing.tight)
        }
    }

    private var factsLine: some View {
        Text(
            ProfileFacts.line(
                for: accountSession.state,
                library: library
            )
        )
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var avatar: some View {
        if let photoURL = accountSession.profile?.avatarURL {
            AsyncImage(url: photoURL) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            } placeholder: {
                monogram
            }
            .accessibilityHidden(true)
        } else {
            monogram
                .accessibilityHidden(true)
        }
    }

    private var monogram: some View {
        Group {
            if let initials = accountSession.profile?.monogram {
                Text(initials)
                    .ladleFont(diameter >= 112 ? .display : .title)
                    .foregroundStyle(LadleTheme.Label.primary)
            } else {
                Image(systemName: "person.fill")
                    .font(
                        .system(
                            size: LadleTheme.IconSize.hero,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(LadleTheme.Label.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(LadleTheme.Surface.badge, in: Circle())
    }

    private var signInSheet: some View {
        NavigationStack {
            VStack(spacing: LadleTheme.Spacing.generous) {
                Text("Keep your recipes in sync")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .multilineTextAlignment(.center)

                Text(
                    "Signing in keeps everything you have saved and lifts the 10-recipe guest limit."
                )
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                SignInOptionsView(flow: flow, identifierPrefix: "account")

                Spacer(minLength: 0)
            }
            .padding(LadleTheme.Layout.sheetMargin)
            .frame(maxWidth: .infinity)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isSignInPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var displayedName: String {
        accountSession.profile?.displayName ?? "Add your name"
    }

    private var isSignedIn: Bool {
        switch accountSession.state {
        case .undecided, .guest:
            false
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            true
        }
    }
}
