import LadleCore
import SwiftUI

struct ReviewCompletionPresentation: Equatable {
    private(set) var isReviewed = false

    var title: String {
        isReviewed ? "Reviewed" : "Mark reviewed"
    }

    var systemImage: String? {
        isReviewed ? "checkmark" : nil
    }

    mutating func markReviewed() {
        isReviewed = true
    }

    static func navigationDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .zero : .milliseconds(160)
    }
}

private enum RecipeDetailSection: String, CaseIterable, Identifiable {
    case ingredients = "Ingredients"
    case method = "Method"

    var id: Self { self }
}

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ladleAccent) private var accent

    let statusText: String
    @Bindable var importCoordinator: ImportCoordinator
    let makeEditorViewModel: (Recipe) -> RecipeEditorViewModel
    let recipeDidChange: (Recipe) -> Void
    let reviewDidComplete: () -> Void
    let toggleFavorite: (UUID) -> Bool
    let completeReview: (UUID) -> Recipe?
    let deleteRecipe: (UUID) -> Bool
    let access: LibraryRecipeAccess
    let openAccount: () -> Void

    @State private var displayedRecipe: Recipe
    @State private var isFavorite: Bool
    @State private var isNutritionPresented = false
    @State private var isReimportPresented = false
    @State private var isVideoPresented = false
    @State private var editorViewModel: RecipeEditorViewModel?
    @State private var cookingViewModel: CookingViewModel?
    @State private var section: RecipeDetailSection = .ingredients
    @State private var isDeleteConfirmationPresented = false
    @State private var reviewIsPending: Bool
    @State private var reviewPresentation =
        ReviewCompletionPresentation()

    private var allowsLibraryEdits: Bool { access == .saved }

    /// Which server object can re-sign the hero image's expired URL.
    /// It follows the access the screen was opened with, never the id
    /// alone: a Discover preview's recipe id IS the Discover sourceID,
    /// which /v1/recipes/{id} answers with a 404.
    var artworkOwner: RemoteImageOwner {
        switch access {
        case .saved:
            .recipe(id: displayedRecipe.id)
        case .discover:
            .discoverSource(id: displayedRecipe.id)
        }
    }

    init(
        recipe: Recipe,
        statusText: String = "Saved recipe",
        importCoordinator: ImportCoordinator,
        makeEditorViewModel: @escaping (Recipe) -> RecipeEditorViewModel,
        recipeDidChange: @escaping (Recipe) -> Void,
        reviewDidComplete: @escaping () -> Void = {},
        toggleFavorite: @escaping (UUID) -> Bool,
        completeReview: @escaping (UUID) -> Recipe? = { _ in nil },
        deleteRecipe: @escaping (UUID) -> Bool = { _ in false },
        access: LibraryRecipeAccess = .saved,
        openAccount: @escaping () -> Void
    ) {
        self.statusText = statusText
        self.importCoordinator = importCoordinator
        self.makeEditorViewModel = makeEditorViewModel
        self.recipeDidChange = recipeDidChange
        self.reviewDidComplete = reviewDidComplete
        self.toggleFavorite = toggleFavorite
        self.completeReview = completeReview
        self.deleteRecipe = deleteRecipe
        self.access = access
        self.openAccount = openAccount
        _displayedRecipe = State(initialValue: recipe)
        _isFavorite = State(initialValue: recipe.isFavorite)
        _reviewIsPending = State(
            initialValue: recipe.reviewStatus == .needsReview
                || statusText == "Check details"
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                    heroImage
                    recipeHeader
                    RecipeMetadataBand(recipe: displayedRecipe)
                    if let nutrition = displayedRecipe.nutrition {
                        RecipeNutritionSummary(nutrition: nutrition) {
                            isNutritionPresented = true
                        }
                    }
                    if showsReviewNotice {
                        reviewNotice
                            .id("recipe-review")
                    }
                    sectionPicker
                    sectionContent

                    if !displayedRecipe.notes.isEmpty {
                        creatorNotes
                    }

                    cookingAction {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(
                                "recipe-review",
                                anchor: .center
                            )
                        }
                    }
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, LadleTheme.Layout.scrollTail)
            }
            .scrollIndicators(.hidden)
        }
        .background(LadleTheme.Surface.porcelain)
        .sensoryFeedback(.selection, trigger: isFavorite)
        .sensoryFeedback(.success, trigger: reviewIsPending) {
            wasPending,
            isPending in
            LadleFeedbackPolicy.didFinishReview(
                wasPending: wasPending,
                isPending: isPending
            )
        }
        .task(id: reviewPresentation.isReviewed) {
            guard reviewPresentation.isReviewed else {
                return
            }
            do {
                try await Task.sleep(
                    for: ReviewCompletionPresentation.navigationDelay(
                        reduceMotion: reduceMotion
                    )
                )
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            reviewDidComplete()
        }
        .accessibilityIdentifier("recipe.detail")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if allowsLibraryEdits {
                ToolbarItemGroup(placement: .primaryAction) {
                    favoriteButton
                    optionsMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openAccount) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
                }
                .foregroundStyle(LadleTheme.Label.primary)
                .buttonStyle(LadlePressButtonStyle())
                .accessibilityLabel("Account")
            }
        }
        .sheet(isPresented: $isNutritionPresented) {
            if let nutrition = displayedRecipe.nutrition {
                NutritionView(
                    nutrition: nutrition,
                    recipeTitle: displayedRecipe.title,
                    uncountedNote: NutritionNote.uncounted(in: displayedRecipe)
                )
            }
        }
        .sheet(item: $editorViewModel) { editorViewModel in
            RecipeEditorView(viewModel: editorViewModel) { recipe in
                applyChangedRecipe(recipe)
            }
        }
        .sheet(
            isPresented: $isReimportPresented,
            onDismiss: {
                // A swipe-down runs none of the sheet's own cleanup, so
                // every dismissal funnels through the coordinator: a
                // finished reimport left published here would wedge the
                // Add Recipe sheet behind "Re-import in progress".
                importCoordinator.releaseReimport(
                    for: displayedRecipe.id
                )
            }
        ) {
            ReimportSheet(
                currentRecipe: displayedRecipe,
                coordinator: importCoordinator
            ) { recipe in
                applyChangedRecipe(recipe)
            }
        }
        .sheet(isPresented: $isVideoPresented) {
            VideoEmbedSheet(recipe: displayedRecipe)
        }
        .fullScreenCover(
            item: $cookingViewModel,
            onDismiss: {
                cookingViewModel = nil
            }
        ) { viewModel in
            FullRecipeView(viewModel: viewModel)
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) {
                if deleteRecipe(displayedRecipe.id) {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your synced Overeasy library.")
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        RecipeArtworkView(
            owner: artworkOwner,
            image: displayedRecipe.images.first
        )
        .frame(height: 322)
        .frame(maxWidth: .infinity)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .clipped()
        .accessibilityLabel("Recipe photo")
    }

    private var recipeHeader: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Text(displayedRecipe.title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: LadleTheme.Spacing.compact) {
                if let creatorName = displayedRecipe.creatorName {
                    Text(creatorName)
                }
                if displayedRecipe.creatorName != nil {
                    Text("·")
                        .accessibilityHidden(true)
                }
                Text(displayedRecipe.source.libraryTitle)
            }
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))

            if !displayedRecipe.description.isEmpty {
                Text(displayedRecipe.description)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("Recipe section", selection: $section) {
            ForEach(RecipeDetailSection.allCases) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .ingredients:
            IngredientList(
                ingredients: displayedRecipe.orderedIngredients,
                showsIcons: true
            )
        case .method:
            MethodList(steps: displayedRecipe.orderedSteps)
        }
    }

    private var creatorNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Notes from the source")

            VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
                ForEach(
                    Array(displayedRecipe.notes.enumerated()),
                    id: \.offset
                ) { _, note in
                    HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
                        Circle()
                            .fill(LadleTheme.Label.secondary)
                            .frame(width: 5, height: 5)
                            .padding(.top, LadleTheme.Spacing.compact)
                            .accessibilityHidden(true)
                        Text(note)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("recipe.notes")
    }

    private var estimateNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(accent.label)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Estimated nutrition")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(
                    "Values are estimated from the imported recipe and may vary by ingredients or serving size."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.62))
            }
        }
        .padding(16)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Estimated nutrition. Values may vary by ingredients or serving size."
        )
    }

    private var reviewNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Check uncertain details",
                systemImage: "pencil.and.list.clipboard"
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.Label.primary)

            Text(
                "Some details are missing or inferred. Check them before cooking."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.secondary)
            .fixedSize(horizontal: false, vertical: true)

            reviewAction
        }
        .padding(16)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var reviewAction: some View {
        if let systemImage = reviewPresentation.systemImage {
            Label(
                reviewPresentation.title,
                systemImage: systemImage
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.Label.primary)
            .frame(maxWidth: .infinity, minHeight: LadleTheme.Control.primary)
            .background(
                LadleTheme.Intent.success.opacity(0.62),
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .accessibilityIdentifier("recipe.reviewed")
        } else {
            Button(
                reviewPresentation.title,
                action: markReviewed
            )
            .buttonStyle(
                LadleButtonStyle(role: .secondary)
            )
            .accessibilityIdentifier("recipe.complete-review")
        }
    }

    private func markReviewed() {
        guard let reviewed = completeReview(
            displayedRecipe.id
        ) else {
            return
        }
        reviewPresentation.markReviewed()
        reviewIsPending = false
        applyChangedRecipe(reviewed)
    }

    private var favoriteButton: some View {
        Button {
            if toggleFavorite(displayedRecipe.id) {
                isFavorite.toggle()
            }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(
                    isFavorite ? accent.label : LadleTheme.Label.primary
                )
                .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(
            isFavorite
                ? "Remove \(displayedRecipe.title) from favorites"
                : "Add \(displayedRecipe.title) to favorites"
        )
    }

    private func applyChangedRecipe(_ recipe: Recipe) {
        displayedRecipe = recipe
        isFavorite = recipe.isFavorite
        recipeDidChange(recipe)
    }

    private var needsReview: Bool {
        reviewIsPending
    }

    private var showsReviewNotice: Bool {
        needsReview || reviewPresentation.isReviewed
    }

    @ViewBuilder
    private func cookingAction(
        showReview: @escaping () -> Void
    ) -> some View {
        switch cookingReadiness {
        case .ready:
            Button("Start Cooking") {
                cookingViewModel = CookingViewModel(
                    recipe: displayedRecipe
                )
            }
            .buttonStyle(LadleButtonStyle(role: .primary))
        case .needsReview:
            Button("Review before cooking", action: showReview)
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
        case .missingIngredients:
            if allowsLibraryEdits {
                Button("Add ingredients before cooking") {
                    editorViewModel = makeEditorViewModel(displayedRecipe)
                }
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
            } else {
                previewUnavailable("Ingredients aren’t available in this preview.")
            }
        case .missingMethod:
            if allowsLibraryEdits {
                Button("Add a method before cooking") {
                    editorViewModel = makeEditorViewModel(displayedRecipe)
                }
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
            } else {
                previewUnavailable("The method isn’t available in this preview.")
            }
        }
    }

    private func previewUnavailable(_ message: String) -> some View {
        Text(message)
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cookingReadiness: RecipeCookingReadiness {
        needsReview ? .needsReview : displayedRecipe.cookingReadiness
    }

    private var optionsMenu: some View {
        Menu {
            ForEach(recipeOptions.filter { !$0.isDestructive }) { option in
                Button {
                    perform(option)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }

            if let destructive = recipeOptions.first(where: \.isDestructive) {
                Section {
                    Button(role: .destructive) {
                        perform(destructive)
                    } label: {
                        Label(
                            destructive.title,
                            systemImage: destructive.systemImage
                        )
                    }
                    // The menu-wide label tint would otherwise leave the
                    // glyph dark while only the title turned red.
                    .tint(LadleTheme.Intent.destructive)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(
                    width: LadleTheme.Control.hitTarget,
                    height: LadleTheme.Control.hitTarget
                )
        }
        // The app-wide accent tint would paint every menu glyph red, which
        // competes with the genuinely destructive item. Menu glyphs follow
        // the label colour, and the destructive role keeps its own red.
        .tint(LadleTheme.Label.primary)
        .foregroundStyle(LadleTheme.Label.primary)
        .accessibilityLabel("Recipe options")
    }

    private var recipeOptions: [RecipeOption] {
        var options: [RecipeOption] = [.edit, .reimport]
        if displayedRecipe.nutrition != nil {
            options.append(.nutrition)
        }
        options.append(.source)
        options.append(.delete)
        return options
    }

    /// A menu dismisses itself before its action runs, so each option can
    /// present its own sheet directly - no deferred-until-dismiss dance.
    private func perform(_ option: RecipeOption) {
        switch option {
        case .edit:
            editorViewModel = makeEditorViewModel(displayedRecipe)
        case .reimport:
            isReimportPresented = true
        case .nutrition:
            isNutritionPresented = true
        case .source:
            isVideoPresented = true
        case .delete:
            isDeleteConfirmationPresented = true
        }
    }
}
