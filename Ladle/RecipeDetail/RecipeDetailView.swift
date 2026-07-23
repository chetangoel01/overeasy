import LadleCore
import SwiftUI

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let recipe: Recipe
    let statusText: String
    let toggleFavorite: () -> Void

    @State private var isFavorite: Bool
    @State private var isNutritionPresented = false

    init(
        recipe: Recipe,
        statusText: String = "Saved recipe",
        toggleFavorite: @escaping () -> Void
    ) {
        self.recipe = recipe
        self.statusText = statusText
        self.toggleFavorite = toggleFavorite
        _isFavorite = State(initialValue: recipe.isFavorite)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                heroImage
                recipeHeader
                RecipeMetadataBand(recipe: recipe)

                Button("Start Cooking") {}
                    .buttonStyle(LadlePrimaryButtonStyle())

                IngredientList(ingredients: recipe.orderedIngredients)
                MethodList(steps: recipe.orderedSteps)

                if recipe.nutrition?.isEstimated == true {
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
                    .font(LadleTypography.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.62))
            }
            ToolbarItem(placement: .primaryAction) {
                favoriteButton
            }
        }
        .sheet(isPresented: $isNutritionPresented) {
            if let nutrition = recipe.nutrition {
                NutritionView(nutrition: nutrition)
            }
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        if let imageName = recipe.images.first?.localName {
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
                .textCase(.uppercase)
                .font(LadleTypography.eyebrow)
                .tracking(1.4)
                .foregroundStyle(LadleTheme.paprika)

            Text(recipe.title)
                .font(LadleTypography.title)
                .foregroundStyle(LadleTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                if let creatorName = recipe.creatorName {
                    Text(creatorName)
                }
                if recipe.creatorName != nil {
                    Text("·")
                        .accessibilityHidden(true)
                }
                Text(recipe.source.libraryTitle)
            }
            .font(LadleTypography.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.58))

            if !recipe.description.isEmpty {
                Text(recipe.description)
                    .font(LadleTypography.body)
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
                    .font(LadleTypography.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Text(
                    "Values are estimated from the imported recipe and may vary by ingredients or serving size."
                )
                .font(LadleTypography.metadata)
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
            ) {}
            secondaryAction(
                title: "Re-import from source",
                systemImage: "arrow.triangle.2.circlepath"
            ) {}

            if recipe.nutrition != nil {
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
                openURL(recipe.originalURL)
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
                    .font(LadleTypography.bodyStrong)
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
            toggleFavorite()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(
                    isFavorite ? LadleTheme.paprika : LadleTheme.ink
                )
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(
            isFavorite
                ? "Remove \(recipe.title) from favorites"
                : "Add \(recipe.title) to favorites"
        )
    }
}
