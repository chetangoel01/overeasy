import LadleCore
import SwiftUI

struct AddRecipeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var coordinator: ImportCoordinator
    let accountSession: AccountSession
    let viewRecipe: (Recipe, String) -> Void

    @State private var linkText = ""
    @State private var isManualEntry = false
    @State private var manualTitle = ""
    @State private var manualDetails = ""
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var recoveryInputMode: RecoveryInputMode?
    @State private var isRetrying = false

    init(
        coordinator: ImportCoordinator,
        accountSession: AccountSession,
        initialLink: String = "",
        viewRecipe: @escaping (Recipe, String) -> Void
    ) {
        self.coordinator = coordinator
        self.accountSession = accountSession
        self.viewRecipe = viewRecipe
        _linkText = State(initialValue: initialLink)
    }

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.operation?.isReimport == true {
                    operationUnavailableContent
                } else {
                    switch coordinator.state {
                    case .importing:
                        importingContent
                    case .completed:
                        successContent(needsReview: false)
                    case .needsReview:
                        successContent(needsReview: true)
                    case .duplicate:
                        duplicateContent
                    case let .guestLimit(decision):
                        guestLimitContent(decision: decision)
                    case let .failed(jobID, reason):
                        failedContent(jobID: jobID, reason: reason)
                    case .idle, .validationFailed, .persistenceFailed:
                        if isManualEntry {
                            manualContent
                        } else {
                            linkContent
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LadleTheme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                }
            }
        }
        .presentationDetents(
            [.medium, .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
        .sheet(item: $recoveryInputMode) { mode in
            CorrectionNotesView(mode: mode) { notes, pastedText in
                guard case let .failed(jobID, _) = coordinator.state else {
                    return
                }
                runRetry(
                    jobID: jobID,
                    correctionNotes: notes,
                    pastedRecipeText: pastedText
                )
            }
        }
        .onAppear {
            coordinator.prepareForNewImport()
            if coordinator.operation == nil {
                coordinator.reset()
            }
        }
        .onChange(of: accountSession.state) { _, state in
            guard state == .freeAccount
                    || state == .signedInWithApple
                    || state == .signedInWithGoogle,
                  case .guestLimit = coordinator.state else {
                return
            }
            Task {
                await coordinator.continueAfterGuestPrompt()
            }
        }
        .onChange(of: coordinator.state) { _, state in
            if case .failed = state {
                selectedDetent = .large
            }
        }
    }

    private var linkContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sheetIntro(
                    icon: "link",
                    title: "Add a recipe",
                    message: "Paste a recipe video link and Overeasy will turn it into something you can actually cook."
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recipe link")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)

                    TextField(
                        "TikTok, Instagram, or YouTube link",
                        text: $linkText
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 52)
                    .background(
                        LadleTheme.field,
                        in: RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("Recipe link")
                }

                validationMessage

                Button("Import from link") {
                    Task {
                        await coordinator.submit(urlText: linkText)
                    }
                }
                .buttonStyle(LadlePrimaryButtonStyle())
                .disabled(
                    linkText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )

                Button {
                    coordinator.reset()
                    isManualEntry = true
                    selectedDetent = .large
                } label: {
                    Label("Create manually", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)

                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(LadleTheme.paprika)
                    Text("Tip: sharing a video to Overeasy is even faster.")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.62))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LadleTheme.review,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var manualContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sheetIntro(
                    icon: "square.and.pencil",
                    title: "Create manually",
                    message: "Start with a title and any details you already have. You can tidy everything up later."
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recipe title")
                        .ladleFont(.bodyStrong)
                    TextField("Recipe title", text: $manualTitle)
                        .ladleFont(.body)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .background(
                            LadleTheme.field,
                            in: RoundedRectangle(
                                cornerRadius: LadleTheme.Corner.control,
                                style: .continuous
                            )
                        )
                        .accessibilityLabel("Recipe title")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recipe details")
                        .ladleFont(.bodyStrong)
                    TextEditor(text: $manualDetails)
                        .ladleFont(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 130)
                        .background(
                            LadleTheme.field,
                            in: RoundedRectangle(
                                cornerRadius: LadleTheme.Corner.control,
                                style: .continuous
                            )
                        )
                        .accessibilityLabel("Recipe details")
                }

                Button("Save manual recipe") {
                    Task {
                        await coordinator.createManualRecipe(
                            title: manualTitle,
                            details: manualDetails
                        )
                    }
                }
                .buttonStyle(LadlePrimaryButtonStyle())
                .disabled(
                    manualTitle.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )

                Button("Use a link instead") {
                    coordinator.reset()
                    isManualEntry = false
                    selectedDetent = .medium
                }
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .foregroundStyle(LadleTheme.ink)
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var importingContent: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
                .tint(LadleTheme.paprika)
                .frame(width: 64, height: 64)
                .background(LadleTheme.review, in: Circle())

            VStack(spacing: 8) {
                Text("Cracking this one open")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                Text("Overeasy is pulling out the useful parts. You can keep browsing while it works.")
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.64))
                    .multilineTextAlignment(.center)
            }

            Button("Keep browsing") {
                dismiss()
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func successContent(needsReview: Bool) -> some View {
        VStack(spacing: 22) {
            Image(
                systemName: needsReview
                    ? "pencil.and.list.clipboard"
                    : "checkmark"
            )
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(
                LadleTheme.ink
            )
            .frame(width: 62, height: 62)
            .background(
                needsReview ? LadleTheme.review : LadleTheme.success,
                in: Circle()
            )

            VStack(spacing: 8) {
                Text(needsReview ? "Check a few details" : "Recipe saved")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                    .multilineTextAlignment(.center)
                Text(
                    coordinator.completedRecipe?.title
                        ?? "Your recipe is ready."
                )
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
                .multilineTextAlignment(.center)
            }

            Button("View recipe") {
                guard let recipe = coordinator.completedRecipe else {
                    return
                }
                viewRecipe(
                    recipe,
                    needsReview ? "Check details" : "Imported recipe"
                )
                coordinator.reset()
                dismiss()
            }
            .buttonStyle(LadlePrimaryButtonStyle())

            Button("Back to recipes") {
                coordinator.reset()
                dismiss()
            }
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink)
            .frame(minHeight: 44)
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private var duplicateContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 60, height: 60)
                .background(LadleTheme.review, in: Circle())

            VStack(spacing: 8) {
                Text("Already in your recipes")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                    .multilineTextAlignment(.center)
                Text(
                    coordinator.existingDuplicate?.title
                        ?? "This link has already been rescued."
                )
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
                .multilineTextAlignment(.center)
            }

            Button("Open existing recipe") {
                guard let recipe = coordinator.existingDuplicate else {
                    return
                }
                viewRecipe(recipe, "Saved recipe")
                dismiss()
            }
            .buttonStyle(LadlePrimaryButtonStyle())

            Button("Import another copy") {
                Task {
                    await coordinator.importDuplicateCopy()
                }
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func guestLimitContent(
        decision: GuestSaveDecision
    ) -> some View {
        GuestLimitView(
            decision: decision,
            accountSession: accountSession
        ) {
            Task {
                await coordinator.continueAfterGuestPrompt()
            }
        }
    }

    private func failedContent(
        jobID: UUID,
        reason: ImportFailure
    ) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 60, height: 60)
                    .background(LadleTheme.review, in: Circle())
                Text("We saved the link")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                Text(reason.addRecipeMessage)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.64))
                    .multilineTextAlignment(.center)

                ImportRecoveryActions(
                    isRetrying: isRetrying,
                    retry: { runRetry(jobID: jobID) },
                    chooseInput: { recoveryInputMode = $0 }
                )

                Button("Back to recipes") {
                    coordinator.reset()
                    dismiss()
                }
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .frame(minHeight: 44)
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private func runRetry(
        jobID: UUID,
        correctionNotes: String? = nil,
        pastedRecipeText: String? = nil
    ) {
        isRetrying = true
        Task {
            await coordinator.retry(
                jobID: jobID,
                correctionNotes: correctionNotes,
                pastedRecipeText: pastedRecipeText
            )
            isRetrying = false
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        switch coordinator.state {
        case let .validationFailed(error):
            Label(error.addRecipeMessage, systemImage: "exclamationmark.circle")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.paprika)
        case .persistenceFailed:
            Label(
                "Overeasy couldn’t save that import. Please try again.",
                systemImage: "exclamationmark.circle"
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.paprika)
        default:
            EmptyView()
        }
    }

    private func sheetIntro(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 48, height: 48)
                .background(LadleTheme.review, in: Circle())
            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
        }
    }

    private var operationUnavailableContent: some View {
        ContentUnavailableView(
            "Re-import in progress",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text(
                "Finish reviewing that replacement before adding another recipe."
            )
        )
        .foregroundStyle(LadleTheme.ink)
        .padding(LadleTheme.Spacing.generous)
    }

    private func close() {
        if coordinator.operation?.isReimport != true,
           !coordinator.isImporting {
            coordinator.reset()
        }
        dismiss()
    }
}

private extension ImportValidationError {
    var addRecipeMessage: String {
        switch self {
        case .invalidURL:
            "Paste a complete link that starts with http or https."
        case .unsupportedSource:
            "Use a TikTok, Instagram, or YouTube link."
        }
    }
}

private extension ImportFailure {
    var addRecipeMessage: String {
        switch self {
        case .privateOrDeleted:
            "The post may be private or deleted. Your link is still saved."
        case .unsupportedSource:
            "That source isn’t supported yet."
        case .invalidURL:
            "That link doesn’t look complete."
        case .networkUnavailable:
            "The network dropped out. The import is safe to retry."
        case .authenticationExpired:
            "Your session ended. Sign in again to retry this import."
        case .parserUnavailable:
            "Overeasy couldn’t read the video, but the link is still saved."
        case .insufficientTextEvidence:
            "The post didn’t include enough written recipe detail. Paste it or add the recipe manually."
        case .quotaExceeded:
            "Overeasy has reached its processing limit. Your link is safe to retry later."
        }
    }
}
