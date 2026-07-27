import LadleCore
import SwiftUI

private enum RecipeDetailSection: String, CaseIterable, Identifiable {
    case ingredients = "Ingredients"
    case method = "Method"

    var id: Self { self }
}

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let statusText: String
    @Bindable var importCoordinator: ImportCoordinator
    let makeEditorViewModel: (Recipe) -> RecipeEditorViewModel
    let recipeDidChange: (Recipe) -> Void
    let toggleFavorite: (UUID) -> Void
    let completeReview: (UUID) -> Recipe?
    let deleteRecipe: (UUID) -> Bool

    @State private var displayedRecipe: Recipe
    @State private var isFavorite: Bool
    @State private var isNutritionPresented = false
    @State private var isReimportPresented = false
    @State private var isVideoPresented = false
    @State private var isOptionsPresented = false
    @State private var editorViewModel: RecipeEditorViewModel?
    @State private var cookingViewModel: CookingViewModel?
    @State private var section: RecipeDetailSection = .ingredients
    @State private var pendingOption: RecipeOption?
    @State private var isDeleteConfirmationPresented = false
    @State private var reviewIsPending: Bool

    init(
        recipe: Recipe,
        statusText: String = "Saved recipe",
        importCoordinator: ImportCoordinator,
        makeEditorViewModel: @escaping (Recipe) -> RecipeEditorViewModel,
        recipeDidChange: @escaping (Recipe) -> Void,
        toggleFavorite: @escaping (UUID) -> Void,
        completeReview: @escaping (UUID) -> Recipe? = { _ in nil },
        deleteRecipe: @escaping (UUID) -> Bool = { _ in false }
    ) {
        self.statusText = statusText
        self.importCoordinator = importCoordinator
        self.makeEditorViewModel = makeEditorViewModel
        self.recipeDidChange = recipeDidChange
        self.toggleFavorite = toggleFavorite
        self.completeReview = completeReview
        self.deleteRecipe = deleteRecipe
        _displayedRecipe = State(initialValue: recipe)
        _isFavorite = State(initialValue: recipe.isFavorite)
        _reviewIsPending = State(
            initialValue: recipe.reviewStatus == .needsReview
                || statusText == "Needs review"
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heroImage
                recipeHeader
                RecipeMetadataBand(recipe: displayedRecipe)
                if needsReview {
                    reviewNotice
                }
                sectionPicker
                sectionContent

                if !displayedRecipe.notes.isEmpty {
                    creatorNotes
                }

                if displayedRecipe.nutrition?.isEstimated == true {
                    estimateNote
                }

                Button("Start Cooking") {
                    cookingViewModel = CookingViewModel(
                        recipe: displayedRecipe
                    )
                }
                .buttonStyle(LadlePrimaryButtonStyle())
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.paper)
        .accessibilityIdentifier("recipe.detail")
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LadleTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                favoriteButton
                Button {
                    isOptionsPresented = true
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(LadleTheme.ink)
                .accessibilityLabel("Recipe options")
            }
        }
        .sheet(
            isPresented: $isOptionsPresented,
            onDismiss: performPendingOption
        ) {
            RecipeOptionsSheet(
                options: recipeOptions,
                select: { pendingOption = $0 }
            )
        }
        .sheet(isPresented: $isNutritionPresented) {
            if let nutrition = displayedRecipe.nutrition {
                NutritionView(
                    nutrition: nutrition,
                    recipeTitle: displayedRecipe.title
                )
            }
        }
        .sheet(item: $editorViewModel) { editorViewModel in
            RecipeEditorView(viewModel: editorViewModel) { recipe in
                applyChangedRecipe(recipe)
            }
        }
        .sheet(isPresented: $isReimportPresented) {
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
            recipeID: displayedRecipe.id,
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
        VStack(alignment: .leading, spacing: 11) {
            Text(kicker)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))

            Text(displayedRecipe.title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
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
            .foregroundStyle(LadleTheme.ink.opacity(0.58))

            if !displayedRecipe.description.isEmpty {
                Text(displayedRecipe.description)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.7))
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
                ingredients: displayedRecipe.orderedIngredients
            )
        case .method:
            MethodList(steps: displayedRecipe.orderedSteps)
        }
    }

    private var creatorNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Notes from the source")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(
                    Array(displayedRecipe.notes.enumerated()),
                    id: \.offset
                ) { _, note in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(LadleTheme.paprika)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                            .accessibilityHidden(true)
                        Text(note)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink.opacity(0.75))
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
                .foregroundStyle(LadleTheme.paprika)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Estimated nutrition")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Text(
                    "Values are estimated from the imported recipe and may vary by ingredients or serving size."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.62))
            }
        }
        .padding(16)
        .background(
            LadleTheme.review,
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
            .foregroundStyle(LadleTheme.ink)

            Text(
                "Review the ingredients and method. When they look usable, mark this recipe reviewed to clear it from the import inbox."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)

            Button("Mark reviewed") {
                guard let reviewed = completeReview(
                    displayedRecipe.id
                ) else {
                    return
                }
                reviewIsPending = false
                applyChangedRecipe(reviewed)
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .accessibilityIdentifier("recipe.complete-review")
        }
        .padding(16)
        .background(
            LadleTheme.review,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var favoriteButton: some View {
        Button {
            isFavorite.toggle()
            toggleFavorite(displayedRecipe.id)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(
                    isFavorite ? LadleTheme.paprika : LadleTheme.ink
                )
                .frame(width: 44, height: 44)
        }
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

    private var kicker: String {
        statusText == "Saved recipe"
            || !needsReview
            ? "Saved from \(displayedRecipe.source.libraryTitle)"
            : statusText
    }

    private var needsReview: Bool {
        reviewIsPending
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

    private func performPendingOption() {
        guard let option = pendingOption else {
            return
        }
        pendingOption = nil
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
