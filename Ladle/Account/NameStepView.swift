import SwiftUI

/// The one screen a new Apple or Google account sees after signing up,
/// before the walkthrough.
///
/// It stands in the walkthrough's register on purpose — the same porcelain,
/// the same Skip in the header, the same primary button pinned at the bottom
/// — because the two screens are one flow and should not look like two apps.
///
/// Prefilled when the provider sent a name, which is Google always and Apple
/// only on the very first authorization for an Apple ID; empty when Apple
/// withheld it. The monogram is the one the Profile header will draw, built
/// from the field as it is typed, so the cook sees what they are choosing.
///
/// Skip always works, and a failed save keeps the screen rather than
/// stranding anyone: a name is not worth blocking entry to the app over.
struct NameStepView: View {
    let accountSession: AccountSession
    var authClient: AuthClient?
    let onComplete: () -> Void

    @State private var draftName: String
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var isNameFocused: Bool

    init(
        accountSession: AccountSession,
        authClient: AuthClient? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.accountSession = accountSession
        self.authClient = authClient
        self.onComplete = onComplete
        _draftName = State(
            initialValue: accountSession.profile?.displayName ?? ""
        )
    }

    var body: some View {
        ZStack {
            LadleTheme.Surface.porcelain
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // Centred in what is left between the header and the button,
                // and scrollable when the type is large enough to need it —
                // the shape Welcome uses for the same problem.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: LadleTheme.Spacing.generous) {
                            message
                            monogram
                            nameField
                            failureMessage
                        }
                        .frame(maxWidth: 360)
                        .padding(.horizontal, LadleTheme.Spacing.generous)
                        .padding(.vertical, LadleTheme.Spacing.generous)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                    }
                    .scrollIndicators(.hidden)
                }

                footer
            }
        }
        .task {
            // The keyboard comes up on arrival: the screen asks one question
            // and there is nothing else here to do. Deferred by one turn of
            // the run loop because this view fades in as a root state, and
            // focus set during that transition is dropped.
            await Task.yield()
            isNameFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("name-step.root")
    }

    private var header: some View {
        HStack {
            Spacer()

            Button(action: skip) {
                Text("Skip")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .frame(
                        minWidth: 44,
                        minHeight: LadleTheme.Control.hitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("name-step.skip")
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, LadleTheme.Spacing.compact)
    }

    private var message: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            Text("What should we call you?")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "It\u{2019}s how Overeasy greets you. You can change it any time in your profile."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The initials the Profile header will draw, drawn now. An empty field
    /// falls back to the same `person.fill` that header uses rather than an
    /// empty circle, so nothing on the screen looks like it failed to load.
    private var monogram: some View {
        Group {
            if let initials = AccountProfile(
                displayName: trimmedName
            ).monogram {
                Text(initials)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .contentTransition(.identity)
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
        .frame(
            width: AccountHeaderView.avatarDiameter,
            height: AccountHeaderView.avatarDiameter
        )
        .background(LadleTheme.Surface.badge, in: Circle())
        .accessibilityHidden(true)
    }

    private var nameField: some View {
        TextField("Your name", text: $draftName)
            .ladleFont(.recipeTitle)
            .foregroundStyle(LadleTheme.Label.primary)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($isNameFocused)
            .disabled(isSaving)
            .onSubmit(submit)
            .onChange(of: draftName) { _, value in
                // The server rejects a longer name outright, so the field
                // stops rather than letting the save fail.
                if value.count > AccountProfile.displayNameLimit {
                    draftName = String(
                        value.prefix(AccountProfile.displayNameLimit)
                    )
                }
            }
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
            .padding(.vertical, LadleTheme.Spacing.medium)
            .frame(minHeight: LadleTheme.Control.primary)
            .background(
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            // An empty text field has almost no hit area of its own — only
            // the line the caret would sit on. The chrome around it looks
            // tappable and has to be.
            .contentShape(Rectangle())
            .onTapGesture { isNameFocused = true }
            .accessibilityLabel("Your name")
            .accessibilityIdentifier("name-step.name-field")
    }

    @ViewBuilder
    private var failureMessage: some View {
        if let failure {
            Text(failure)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("name-step.failure")
        }
    }

    private var footer: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            Button("Continue", action: submit)
                .buttonStyle(LadleButtonStyle(role: .primary))
                .disabled(trimmedName.isEmpty || isSaving)
                .accessibilityIdentifier("name-step.continue")

            if isSaving {
                ProgressView()
            }
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, LadleTheme.Spacing.medium)
        .padding(.bottom, LadleTheme.Spacing.regular)
        .background(LadleTheme.Surface.porcelain)
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func skip() {
        isNameFocused = false
        onComplete()
    }

    private func submit() {
        guard !trimmedName.isEmpty, !isSaving else { return }
        isNameFocused = false
        failure = nil

        guard trimmedName != accountSession.profile?.displayName else {
            // The provider's name, accepted as it stands. Nothing to send,
            // and a needless round trip here could fail on the happy path.
            onComplete()
            return
        }

        guard let authClient else {
            // Demo and UI-test builds have no backend, the way the sign-in
            // flow has none; the name still lands on the session.
            accountSession.applyProfile(
                AccountProfile(
                    displayName: trimmedName,
                    avatarURL: accountSession.profile?.avatarURL,
                    avatarIsCustom:
                        accountSession.profile?.avatarIsCustom ?? false,
                    createdAt: accountSession.profile?.createdAt
                )
            )
            onComplete()
            return
        }

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await authClient.updateProfile(displayName: trimmedName)
                onComplete()
            } catch {
                // Stay here with the reason. Skip is still one tap away, so
                // a network error delays entry rather than blocking it.
                failure = ProfileEditFailure.name(error)
            }
        }
    }
}
