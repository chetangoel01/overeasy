import SwiftUI

/// The name step of issue #62: the one screen a new Apple or Google account
/// sees after signing up, before the walkthrough.
///
/// Throwaway prototype. It stands in the walkthrough's register on purpose —
/// same porcelain, same Skip in the header, same primary button pinned at the
/// bottom — because the two screens are one flow and should not look like
/// two apps. Prefilled when the provider sent a name, empty when Apple
/// withheld it; the monogram is the same one the profile will draw, so the
/// cook sees what they are choosing as they type.
struct NameStepPrototypeView: View {
    private static let avatarDiameter: CGFloat = 96

    let accountSession: AccountSession
    let onComplete: () -> Void

    @State private var draftName: String
    @FocusState private var isNameFocused: Bool

    init(
        accountSession: AccountSession,
        onComplete: @escaping () -> Void
    ) {
        self.accountSession = accountSession
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

                ScrollView {
                    VStack(spacing: LadleTheme.Spacing.generous) {
                        message
                        monogram
                        nameField
                    }
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.top, LadleTheme.Spacing.generous)
                    .padding(.bottom, LadleTheme.Spacing.generous)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("name-step.root")
    }

    private var header: some View {
        HStack {
            Spacer()

            Button(action: onComplete) {
                Text("Skip")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .frame(minWidth: 44, minHeight: LadleTheme.Control.hitTarget)
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
                "It’s how Overeasy greets you. You can change it any time in your profile."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The initials the profile will draw, drawn now. An empty field falls
    /// back to the same `person.fill` the header uses rather than an empty
    /// circle, so nothing on the screen looks like it failed to load.
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
            width: Self.avatarDiameter,
            height: Self.avatarDiameter
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
            .onSubmit(complete)
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
            .accessibilityLabel("Your name")
            .accessibilityIdentifier("name-step.name-field")
    }

    private var footer: some View {
        Button("Continue", action: complete)
            .buttonStyle(LadleButtonStyle(role: .primary))
            .disabled(trimmedName.isEmpty)
            .accessibilityIdentifier("name-step.continue")
            .padding(.horizontal, LadleTheme.Spacing.generous)
            .padding(.top, LadleTheme.Spacing.medium)
            .padding(.bottom, LadleTheme.Spacing.regular)
            .background(LadleTheme.Surface.porcelain)
    }

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func complete() {
        guard !trimmedName.isEmpty else { return }
        isNameFocused = false
        accountSession.applyProfile(
            AccountProfile(
                displayName: trimmedName,
                avatarURL: accountSession.profile?.avatarURL
            )
        )
        onComplete()
    }
}
