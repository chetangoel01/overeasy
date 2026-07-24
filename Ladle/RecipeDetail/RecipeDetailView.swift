import LadleCore
import SwiftUI

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let statusText: String
    @Bindable var importCoordinator: ImportCoordinator
    let makeEditorViewModel: (Recipe) -> RecipeEditorViewModel
    let recipeDidChange: (Recipe) -> Void
    let toggleFavorite: (UUID) -> Void

    @State private var displayedRecipe: Recipe
    @State private var isFavorite: Bool
    @State private var isNutritionPresented = false
    @State private var isEditorPresented = false
    @State private var isReimportPresented = false
    @State private var editorViewModel: RecipeEditorViewModel?
    @State private var cookingViewModel: CookingViewModel?

    init(
        recipe: Recipe,
        statusText: String = "Saved recipe",
        importCoordinator: ImportCoordinator,
        makeEditorViewModel: @escaping (Recipe) -> RecipeEditorViewModel,
        recipeDidChange: @escaping (Recipe) -> Void,
        toggleFavorite: @escaping (UUID) -> Void
    ) {
        self.statusText = statusText
        self.importCoordinator = importCoordinator
        self.makeEditorViewModel = makeEditorViewModel
        self.recipeDidChange = recipeDidChange
        self.toggleFavorite = toggleFavorite
        _displayedRecipe = State(initialValue: recipe)
        _isFavorite = State(initialValue: recipe.isFavorite)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heroImage
                recipeHeader
                RecipeMetadataBand(recipe: displayedRecipe)

                Button("Start Cooking") {
                    cookingViewModel = CookingViewModel(
                        recipe: displayedRecipe
                    )
                }
                .buttonStyle(LadlePrimaryButtonStyle())

                IngredientList(
                    ingredients: displayedRecipe.orderedIngredients
                )
                MethodList(steps: displayedRecipe.orderedSteps)

                if displayedRecipe.nutrition?.isEstimated == true {
                    estimateNote
                }

                secondaryActions
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.paper)
        .accessibilityIdentifier("recipe.detail")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LadleTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LadleTheme.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back to recipes")
            }
            ToolbarItem(placement: .principal) {
                Text("Recipe")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.62))
            }
            ToolbarItem(placement: .primaryAction) {
                favoriteButton
            }
        }
        .sheet(isPresented: $isNutritionPresented) {
            if let nutrition = displayedRecipe.nutrition {
                NutritionView(
                    nutrition: nutrition,
                    recipeTitle: displayedRecipe.title
                )
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            if let editorViewModel {
                RecipeEditorView(viewModel: editorViewModel) { recipe in
                    applyChangedRecipe(recipe)
                }
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
        .fullScreenCover(
            item: $cookingViewModel,
            onDismiss: {
                cookingViewModel = nil
            }
        ) { viewModel in
            FullRecipeView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        if let imageName = displayedRecipe.images.first?.localName {
            Image(imageName)
                .resizable()
                .scaledToFill()
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
        } else {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
            .fill(LadleTheme.field)
            .frame(height: 260)
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: 30))
                    .foregroundStyle(LadleTheme.paprika)
            }
            .accessibilityLabel("Recipe photo unavailable")
        }
    }

    private var recipeHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(statusText)
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

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Recipe options")

            secondaryAction(
                title: "Edit recipe",
                systemImage: "square.and.pencil"
            ) {
                editorViewModel = makeEditorViewModel(displayedRecipe)
                isEditorPresented = true
            }
            secondaryAction(
                title: "Re-import from source",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                isReimportPresented = true
            }

            if displayedRecipe.nutrition != nil {
                secondaryAction(
                    title: "View nutrition",
                    systemImage: "chart.bar"
                ) {
                    isNutritionPresented = true
                }
            }

            secondaryAction(
                title: "Watch original video",
                systemImage: "play.rectangle"
            ) {
                openURL(displayedRecipe.originalURL)
            }
        }
    }

    private func secondaryAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 34, height: 34)
                    .background(LadleTheme.review, in: Circle())
                Text(title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LadleTheme.ink.opacity(0.34))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
        }
        .accessibilityLabel(title)
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
}
