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
    @State private var isCancelConfirmationPresented = false

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
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents(
            [.medium, .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
        .confirmationDialog(
            "Cancel this import?",
            isPresented: $isCancelConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel Import", role: .destructive) {
                cancelImport()
            }
            Button("Keep Processing", role: .cancel) {}
        } message: {
            Text("The recipe will stop processing and disappear from Inbox.")
        }
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
            if coordinator.isImporting {
                selectedDetent = .large
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
            } else if case .importing = state {
                selectedDetent = .large
            }
        }
    }

    private var linkContent: some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                sheetIntro(
                    icon: "link",
                    title: "Add a recipe",
                    message: "Paste a recipe video link and Overeasy will turn it into something you can actually cook."
                )

                VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
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
                    .padding(.horizontal, LadleTheme.Layout.cardPadding)
                    .frame(minHeight: 52)
                    .background(
                        LadleTheme.Surface.raised,
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
                .buttonStyle(LadleButtonStyle(role: .primary))
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

                HStack(spacing: LadleTheme.Layout.iconGap) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(LadleTheme.Label.accent)
                    Text("Tip: sharing a video to Overeasy is even faster.")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.62))
                }
                .padding(LadleTheme.Layout.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LadleTheme.Surface.steel,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var manualContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
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
                        .padding(.horizontal, LadleTheme.Layout.cardPadding)
                        .frame(minHeight: 50)
                        .background(
                            LadleTheme.Surface.raised,
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
                        .padding(LadleTheme.Spacing.medium)
                        .frame(minHeight: 130)
                        .background(
                            LadleTheme.Surface.raised,
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
                .buttonStyle(LadleButtonStyle(role: .primary))
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
        VStack(spacing: LadleTheme.Layout.sectionGap) {
            ProgressView()
                .controlSize(.large)
                .tint(LadleTheme.Label.accent)
                .frame(width: 64, height: 64)
                .background(LadleTheme.Surface.steel, in: Circle())

            VStack(spacing: 8) {
                Text("Cracking this one open")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                Text("Overeasy is pulling out the useful parts. You can keep browsing while it works.")
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.64))
                    .multilineTextAlignment(.center)
            }

            Button("Cancel Import", role: .destructive) {
                isCancelConfirmationPresented = true
            }
            .ladleFont(.bodyStrong)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func successContent(needsReview: Bool) -> some View {
        VStack(spacing: LadleTheme.Layout.sectionGap) {
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
                needsReview ? LadleTheme.Surface.steel : LadleTheme.Intent.success,
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
            .buttonStyle(LadleButtonStyle(role: .primary))

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
        VStack(spacing: LadleTheme.Layout.sectionGap) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 60, height: 60)
                .background(LadleTheme.Surface.steel, in: Circle())

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
            .buttonStyle(LadleButtonStyle(role: .primary))

            Button("Import another copy") {
                Task {
                    await coordinator.importDuplicateCopy()
                }
            }
            .buttonStyle(LadleButtonStyle(role: .secondary))
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
        let failure = coordinator.operationFailure.flatMap {
            $0.jobID == jobID ? $0 : nil
        } ?? ImportOperationFailure(jobID: jobID, reason: reason)
        return ScrollView {
            VStack(spacing: LadleTheme.Layout.sectionGap) {
                Image(
                    systemName: failure.report?.failure.systemImage
                        ?? "exclamationmark.triangle.fill"
                )
                    .font(.system(size: 24))
                    .foregroundStyle(LadleTheme.Label.accent)
                    .frame(width: 60, height: 60)
                    .background(LadleTheme.Surface.steel, in: Circle())
                Text(failure.title)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                Text(failure.message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.64))
                    .multilineTextAlignment(.center)

                ImportRecoveryActions(
                    isRetrying: isRetrying,
                    retryAvailability: failure.retryAvailability(),
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
                .foregroundStyle(LadleTheme.Label.accent)
        case .persistenceFailed:
            Label(
                "Overeasy couldn’t save that import. Please try again.",
                systemImage: "exclamationmark.circle"
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.accent)
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
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 48, height: 48)
                .background(LadleTheme.Surface.steel, in: Circle())
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

    private func cancelImport() {
        guard let jobID = coordinator.operation?.jobID else {
            return
        }
        Task {
            await coordinator.cancelImport(jobID: jobID)
            dismiss()
        }
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
