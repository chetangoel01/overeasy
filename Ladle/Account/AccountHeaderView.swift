import PhotosUI
import SwiftUI

/// One line of facts under the name: what a cook would recognise as theirs.
///
/// The counts come from the library on the device; the month comes from the
/// account's creation date, which is why that date is on the wire at all.
/// Pure, and deliberately free of `LibraryViewModel`, so the wording is a
/// unit test rather than a screenshot.
///
/// American spelling, like every other string in the app — "favorites" —
/// even though the documents around it are written in British.
enum ProfileFacts {
    static func line(
        for state: AccountState,
        recipes: Int,
        favorites: Int,
        createdAt: Date?
    ) -> String {
        switch state {
        case .undecided, .guest:
            return "\(count(recipes, "recipe")) on this device"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            var parts = [count(recipes, "recipe"), count(favorites, "favorite")]
            if let createdAt {
                // Omitted rather than guessed when the account predates the
                // field: an invented month is worse than a shorter line.
                parts.append("cooking since \(month(createdAt))")
            }
            return parts.joined(separator: " · ")
        }
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }
}

/// What a cook is told when a profile edit did not save. Shared, because the
/// header, the sign-up name step and the avatar menu all submit through the
/// same client, and a failure there means the same thing on all three — only
/// the first sentence, naming what did not change, differs.
enum ProfileEditFailure {
    static func name(_ error: any Error) -> String {
        message(error, unchanged: "Your name is unchanged.")
    }

    static func photo(_ error: any Error) -> String {
        message(error, unchanged: "Your photo is unchanged.")
    }

    private static func message(
        _ error: any Error,
        unchanged: String
    ) -> String {
        switch RemoteFailure(error) {
        case .offline:
            return "\(unchanged) Reconnect and try again."
        case .serviceUnavailable:
            return "\(unchanged) Overeasy is temporarily unavailable."
        case let .rateLimited(retryAt):
            return "\(unchanged) Try again after \(retryAt.formatted(date: .omitted, time: .shortened))."
        case .authenticationExpired:
            return "\(unchanged) Sign in again before changing it."
        case .quotaExceeded, .invalidResponse, .unknown:
            return "\(unchanged) Please try again."
        }
    }
}

/// The cook, at the top of Profile.
///
/// iOS puts the person first — the Apple ID row is the first thing in
/// Settings.app — and Overeasy showed a cook nothing about themselves at
/// all: a signed-in account and a guest saw the same screen with one string
/// changed.
///
/// Signed in: a photo or a monogram at 96 points, the display name edited in
/// place, the account kind, and the facts line. A guest sees the word
/// "Guest", their own count, and a way to stop being one — no empty avatar
/// and no placeholder name, because a guest has neither and inventing them
/// would only look broken.
struct AccountHeaderView: View {
    /// Whether the avatar draws the provider's photo or the cook's initials.
    /// Offered only when there is a photo to choose. Per device on purpose:
    /// the name is what has to survive a reinstall, this does not.
    private enum AvatarStyle: String {
        case photo
        case initials

        static let preferenceKey = "ladle.profile.avatarStyle"
    }

    /// The avatar's diameter. Larger than any control height because it is
    /// artwork, not a control — `Control` names the three heights a tappable
    /// thing may have, and this is not one of them.
    ///
    /// 96, not the 64 this grew out of: at 64 the avatar was a row that
    /// happened to come first, and the screen was still Settings. At 96 the
    /// cook is the subject of it, which is the whole point of Profile.
    static let avatarDiameter: CGFloat = 96

    @AppStorage(AvatarStyle.preferenceKey)
    private var avatarStyle = AvatarStyle.photo.rawValue

    let accountSession: AccountSession
    let library: LibraryViewModel
    var authClient: AuthClient?

    @State private var flow: AccountSignInFlow
    @State private var isSignInPresented = false
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var isSavingName = false
    @State private var nameFailure: String?
    @FocusState private var isNameFocused: Bool

    @State private var isChoosingPhoto = false
    @State private var isTakingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    /// The picture the cook just chose, drawn while it uploads and kept
    /// afterwards. Kept, because the answer is a URL for the same photo and
    /// swapping to it would flash the monogram while `AsyncImage` fetched it.
    @State private var pendingPhoto: UIImage?
    @State private var isSavingPhoto = false
    @State private var photoFailure: String?

    init(
        accountSession: AccountSession,
        library: LibraryViewModel,
        authClient: AuthClient?,
        googleSignIn: (any GoogleSignInProviding)?,
        onAuthenticated: @escaping @MainActor () async -> Void
    ) {
        self.accountSession = accountSession
        self.library = library
        self.authClient = authClient
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
        VStack(spacing: LadleTheme.Spacing.medium) {
            if isSignedIn {
                avatarControl
                signedInIdentity
            } else {
                guestIdentity

                Button("Sign in") { isSignInPresented = true }
                    .buttonStyle(LadleButtonStyle(role: .secondary))
                    .padding(.horizontal, LadleTheme.Layout.sheetMargin)
                    .accessibilityIdentifier("account.profile.sign-in")
            }
        }
        .frame(maxWidth: .infinity)
        // No top padding. The gap above the avatar is the form's own first
        // section inset, trimmed in `AccountSheet` to the system's ordinary
        // one; adding 24 of ours on top of it is what left the sheet opening
        // on a band of nothing.
        .padding(.bottom, LadleTheme.Layout.sectionGap)
        .sheet(isPresented: $isSignInPresented) {
            signInSheet
        }
        .onChange(of: accountSession.state) { _, state in
            // `onAuthenticated` runs up in the library, so nothing else here
            // would ever close this sheet after a successful sign-in.
            if isSignInPresented, state != .guest, state != .undecided {
                isSignInPresented = false
            }
        }
        .alert(
            "Name couldn’t be saved",
            isPresented: Binding(
                get: { nameFailure != nil },
                set: { if !$0 { nameFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(nameFailure ?? "Please try again.")
        }
        .alert(
            "Photo couldn’t be saved",
            isPresented: Binding(
                get: { photoFailure != nil },
                set: { if !$0 { photoFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(photoFailure ?? "Please try again.")
        }
        .photosPicker(
            isPresented: $isChoosingPhoto,
            selection: $pickedItem,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                pickedItem = nil
                guard
                    let data = try? await item.loadTransferable(
                        type: Data.self
                    ),
                    let image = UIImage(data: data)
                else {
                    // A picture in iCloud that would not download, or a
                    // format no `UIImage` can read.
                    photoFailure =
                        "Your photo is unchanged. That picture couldn’t be opened."
                    return
                }
                choosePhoto(image)
            }
        }
        .fullScreenCover(isPresented: $isTakingPhoto) {
            CameraPhotoPicker(onCapture: choosePhoto)
                .ignoresSafeArea()
        }
    }

    // MARK: - Signed in

    private var signedInIdentity: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            nameControl
            Text(AccountSheet.accountTitle(for: accountSession.state))
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)

            factsLine
                .padding(.top, LadleTheme.Spacing.tight)
        }
        .padding(.horizontal, LadleTheme.Layout.sheetMargin)
    }

    /// A guest has no photo and no name, and inventing either would only look
    /// broken — but "Guest" sits in the face the name would, so the header
    /// reads as one design in both states, and the count is theirs too.
    private var guestIdentity: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text("Guest")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)

            factsLine
                .padding(.top, LadleTheme.Spacing.tight)
        }
        .padding(.horizontal, LadleTheme.Layout.sheetMargin)
    }

    private var factsLine: some View {
        Text(
            ProfileFacts.line(
                for: accountSession.state,
                recipes: library.recipes.count,
                favorites: library.recipes.filter(\.isFavorite).count,
                createdAt: accountSession.profile?.createdAt
            )
        )
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("account.profile.facts")
    }

    @ViewBuilder
    private var nameControl: some View {
        if isEditingName {
            TextField("Your name", text: $draftName)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isNameFocused)
                .onAppear { isNameFocused = true }
                .onSubmit(submitName)
                .onChange(of: isNameFocused) { _, focused in
                    // Done is not the only way out of a field: a scroll, a
                    // tap elsewhere or a drag on the sheet all end editing,
                    // and iOS commits an inline edit on blur rather than
                    // stranding the field open. `submitName` clears
                    // `isEditingName` first, so this cannot re-enter.
                    if !focused, isEditingName {
                        submitName()
                    }
                }
                .onChange(of: draftName) { _, value in
                    // The server rejects a longer name outright, so the
                    // field stops rather than letting the save fail.
                    if value.count > AccountProfile.displayNameLimit {
                        draftName = String(
                            value.prefix(AccountProfile.displayNameLimit)
                        )
                    }
                }
                .padding(.horizontal, LadleTheme.Layout.sheetMargin)
                .accessibilityIdentifier("account.profile.name-field")
        } else {
            Button(action: beginEditingName) {
                HStack(spacing: LadleTheme.Spacing.compact) {
                    Text(displayedName)
                        .ladleFont(.title)
                        .foregroundStyle(
                            accountSession.profile?.displayName == nil
                                ? LadleTheme.Label.secondary
                                : LadleTheme.Label.primary
                        )
                    if isSavingName {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSavingName)
            .accessibilityIdentifier("account.profile.name")
            .accessibilityHint("Edit the name shown on your account")
        }
    }

    /// The avatar, and everything a cook can do to it.
    ///
    /// A menu for every signed-in cook now, not only one a provider gave a
    /// picture to: choosing a photo is the thing a profile screen is expected
    /// to let you do, and an Apple account — which never gets a provider photo
    /// at all — had no way to reach it.
    ///
    /// What is in the menu depends on what exists. Take Photo only where there
    /// is a camera; the photo/initials choice only when there is a photo to
    /// show; Remove only when the photo is the cook’s own, because the
    /// provider’s copy is not ours to take away.
    private var avatarControl: some View {
        Menu {
            if CameraPhotoPicker.isAvailable {
                Button("Take Photo", systemImage: "camera") {
                    isTakingPhoto = true
                }
            }
            Button("Choose Photo", systemImage: "photo.on.rectangle") {
                isChoosingPhoto = true
            }
            if hasPhoto {
                Picker("Avatar", selection: $avatarStyle) {
                    Text("Show photo").tag(AvatarStyle.photo.rawValue)
                    Text("Show initials").tag(AvatarStyle.initials.rawValue)
                }
                .pickerStyle(.inline)
            }
            if isPhotoTheCooks {
                Button(
                    "Remove Photo",
                    systemImage: "trash",
                    role: .destructive,
                    action: removePhoto
                )
            }
        } label: {
            avatar
        }
        .buttonStyle(.plain)
        .disabled(isSavingPhoto)
        .accessibilityLabel("Profile picture options")
        .accessibilityIdentifier("account.profile.avatar")
    }

    private var avatar: some View {
        Group {
            if avatarStyle != AvatarStyle.photo.rawValue {
                monogram
            } else if let pendingPhoto {
                circle(Image(uiImage: pendingPhoto))
            } else if let photoURL {
                AsyncImage(url: photoURL) { image in
                    circle(image)
                } placeholder: {
                    monogram
                }
            } else {
                monogram
            }
        }
        .overlay {
            if isSavingPhoto {
                ProgressView()
                    .frame(
                        width: Self.avatarDiameter,
                        height: Self.avatarDiameter
                    )
                    .background(
                        LadleTheme.Surface.badge.opacity(0.7),
                        in: Circle()
                    )
            }
        }
    }

    private func circle(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
            .clipShape(Circle())
    }

    private var monogram: some View {
        Group {
            if let initials = accountSession.profile?.monogram {
                Text(initials)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.Label.primary)
            } else {
                // No name yet — every Apple cook who signed in before the
                // name was captured — so there are no initials to draw.
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
        .frame(width: Self.avatarDiameter, height: Self.avatarDiameter)
        .background(LadleTheme.Surface.badge, in: Circle())
    }

    // MARK: - Guest

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

                if let failure = flow.failure {
                    Text(failure.message)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.sign-in-failure")
                }
            }
            .padding(LadleTheme.Layout.sheetMargin)
            // Centred rather than pinned to the top. The content is a title,
            // a sentence and two buttons; against a fixed medium detent that
            // left a half-sheet of empty paper hanging beneath it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Editing

    private var isSignedIn: Bool {
        switch accountSession.state {
        case .undecided, .guest:
            false
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            true
        }
    }

    private var photoURL: URL? {
        accountSession.profile?.avatarURL
    }

    private var hasPhoto: Bool {
        pendingPhoto != nil || photoURL != nil
    }

    /// Whether the picture on screen is one the cook chose rather than one a
    /// provider supplied. `pendingPhoto` counts: they have just picked it, and
    /// the offer to take it away must not wait for a round trip.
    private var isPhotoTheCooks: Bool {
        pendingPhoto != nil || accountSession.profile?.avatarIsCustom == true
    }

    private var displayedName: String {
        accountSession.profile?.displayName ?? "Add your name"
    }

    private func beginEditingName() {
        draftName = accountSession.profile?.displayName ?? ""
        isEditingName = true
    }

    /// Crop, downscale, show, then send.
    ///
    /// The picture appears at once and the upload runs behind it: a cook who
    /// has just chosen a photo should not watch the old one for a round trip.
    /// A failure puts the old one back, which is what the alert says happened.
    private func choosePhoto(_ image: UIImage) {
        guard let jpeg = ProfilePhoto.jpeg(from: image) else {
            photoFailure =
                "Your photo is unchanged. That picture couldn’t be prepared."
            return
        }
        pendingPhoto = image
        // A cook showing initials who then picks a photo means to see it;
        // leaving the toggle alone would look like nothing happened.
        avatarStyle = AvatarStyle.photo.rawValue
        guard let authClient else {
            // Demo and UI-test builds have no backend, the way the sign-in
            // flow has none. The photo lands on the session from a file, so
            // the whole menu — Remove Photo included — is still walkable.
            applyPhotoLocally(jpeg)
            return
        }
        isSavingPhoto = true
        Task { @MainActor in
            defer { isSavingPhoto = false }
            do {
                try await authClient.uploadAvatar(jpeg)
            } catch {
                pendingPhoto = nil
                photoFailure = ProfileEditFailure.photo(error)
            }
        }
    }

    private func removePhoto() {
        let restored = pendingPhoto
        pendingPhoto = nil
        guard let authClient else {
            accountSession.applyProfile(
                AccountProfile(
                    displayName: accountSession.profile?.displayName,
                    avatarURL: nil,
                    avatarIsCustom: false,
                    createdAt: accountSession.profile?.createdAt
                )
            )
            return
        }
        isSavingPhoto = true
        Task { @MainActor in
            defer { isSavingPhoto = false }
            do {
                try await authClient.removeAvatar()
            } catch {
                pendingPhoto = restored
                photoFailure = ProfileEditFailure.photo(error)
            }
        }
    }

    private func applyPhotoLocally(_ jpeg: Data) {
        let file = URL.temporaryDirectory
            .appending(path: "profile-photo-\(UUID().uuidString).jpg")
        try? jpeg.write(to: file, options: .atomic)
        accountSession.applyProfile(
            AccountProfile(
                displayName: accountSession.profile?.displayName,
                avatarURL: file,
                avatarIsCustom: true,
                createdAt: accountSession.profile?.createdAt
            )
        )
    }

    private func submitName() {
        let trimmed = draftName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isEditingName = false
        isNameFocused = false
        guard trimmed != (accountSession.profile?.displayName ?? "") else {
            return
        }
        guard let authClient else {
            // Demo and UI-test builds have no backend, the way the sign-in
            // flow has none; the header still edits.
            accountSession.applyProfile(
                AccountProfile(
                    displayName: trimmed.isEmpty ? nil : trimmed,
                    avatarURL: photoURL,
                    avatarIsCustom:
                        accountSession.profile?.avatarIsCustom ?? false,
                    createdAt: accountSession.profile?.createdAt
                )
            )
            return
        }
        isSavingName = true
        Task { @MainActor in
            defer { isSavingName = false }
            do {
                try await authClient.updateProfile(displayName: trimmed)
            } catch {
                // The name shown comes from the session, which the failed
                // request never touched, so it has already reverted.
                nameFailure = ProfileEditFailure.name(error)
            }
        }
    }
}
