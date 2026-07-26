import LadleCore
import SwiftUI

private enum RecipeEditorSection: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case media = "Media"
    case timing = "Timing"
    case ingredients = "Ingredients"
    case method = "Method"
    case nutrition = "Nutrition"

    var id: String { rawValue }
}

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: RecipeEditorViewModel
    let didSave: (Recipe) -> Void

    @State private var selectedSection: RecipeEditorSection = .basics

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sectionNavigation

                ScrollView {
                    sectionContent
                        .padding(LadleTheme.Spacing.regular)
                        .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
            .background(LadleTheme.paper)
            .accessibilityIdentifier("recipe.editor")
            .navigationTitle("Edit recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.discardChanges()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save recipe") {
                        if let recipe = viewModel.save() {
                            didSave(recipe)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
        .interactiveDismissDisabled(viewModel.hasChanges)
    }

    private var sectionNavigation: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(RecipeEditorSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Text(section.rawValue)
                            .ladleFont(.metadata)
                            .foregroundStyle(
                                selectedSection == section
                                    ? Color.white
                                    : LadleTheme.ink
                            )
                            .padding(.horizontal, 13)
                            .frame(minHeight: 44)
                            .background(
                                selectedSection == section
                                    ? LadleTheme.paprika
                                    : LadleTheme.field,
                                in: Capsule()
                            )
                    }
                    .accessibilityLabel("\(section.rawValue) section")
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.paper)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(LadleTheme.ink.opacity(0.08))
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .basics:
            basicsSection
        case .media:
            mediaSection
        case .timing:
            timingSection
        case .ingredients:
            ingredientsSection
        case .method:
            methodSection
        case .nutrition:
            nutritionSection
        }
    }

    private var basicsSection: some View {
        editorSection(
            title: "The essentials",
            message: "Keep the name clear and the description useful at a glance."
        ) {
            editorField(
                title: "Recipe title",
                text: $viewModel.draft.title,
                showsClearButton: true
            )
            if viewModel.hasIssue(.titleRequired) {
                validationText("Add a recipe title.")
            }
            if viewModel.hasIssue(.titleTooLong) {
                validationText("Keep the title to 300 characters or fewer.")
            }

            editorField(
                title: "Creator",
                text: $viewModel.draft.creatorName
            )
            if viewModel.hasIssue(.creatorNameTooLong) {
                validationText("Keep the creator name to 200 characters or fewer.")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .ladleFont(.bodyStrong)
                TextEditor(text: $viewModel.draft.description)
                    .ladleFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .editorSurface()
                    .accessibilityLabel("Recipe description")
                if viewModel.hasIssue(.descriptionTooLong) {
                    validationText(
                        "Keep the description to 10,000 characters or fewer."
                    )
                }
            }
        }
    }

    private var mediaSection: some View {
        editorSection(
            title: "Source & media",
            message: "The original source stays attached so you can always check the video."
        ) {
            if let image = viewModel.draft.images.first {
                RecipeArtworkView(
                    recipeID: viewModel.draft.id,
                    image: image
                )
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )
                .clipped()
                .accessibilityLabel("Current recipe photo")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Original source")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.56))
                Text(viewModel.draft.originalURL.absoluteString)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink)
                    .textSelection(.enabled)
                Text(viewModel.draft.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.paprika)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .editorSurface()
        }
    }

    private var timingSection: some View {
        editorSection(
            title: "Timing & yield",
            message: "Use whole minutes and the number of servings the recipe makes."
        ) {
            editorField(
                title: "Preparation minutes",
                text: $viewModel.draft.preparationMinutes,
                keyboardType: .numberPad
            )
            if viewModel.hasIssue(.preparationMinutesInvalid) {
                validationText(
                    "Enter a whole number from zero to 43,200."
                )
            }

            editorField(
                title: "Cooking minutes",
                text: $viewModel.draft.cookingMinutes,
                keyboardType: .numberPad
            )
            if viewModel.hasIssue(.cookingMinutesInvalid) {
                validationText(
                    "Enter a whole number from zero to 43,200."
                )
            }
            if viewModel.hasIssue(.totalMinutesInvalid) {
                validationText(
                    "Preparation and cooking time together must be 43,200 minutes or fewer."
                )
            }

            editorField(
                title: "Servings",
                text: $viewModel.draft.servings,
                keyboardType: .decimalPad
            )
            if viewModel.hasIssue(.servingsMustBePositive) {
                validationText(
                    "Servings must be greater than zero and at most 10,000."
                )
            }
        }
    }

    private var ingredientsSection: some View {
        editorSection(
            title: "Ingredients",
            message: "Edit each part separately, then arrange the cooking order."
        ) {
            ForEach(
                Array(viewModel.draft.ingredients.enumerated()),
                id: \.element.id
            ) { index, ingredient in
                ingredientCard(index: index, ingredient: ingredient)
            }

            Button {
                viewModel.addIngredient()
            } label: {
                Label("Add ingredient", systemImage: "plus")
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .disabled(
                viewModel.draft.ingredients.count
                    >= RecipeContractLimits.ingredients
            )
            if viewModel.hasIssue(.tooManyIngredients) {
                validationText("A recipe can have at most 200 ingredients.")
            }
        }
    }

    private var methodSection: some View {
        editorSection(
            title: "Method",
            message: "Keep each instruction focused on one useful cooking moment."
        ) {
            ForEach(
                Array(viewModel.draft.steps.enumerated()),
                id: \.element.id
            ) { index, step in
                stepCard(index: index, step: step)
            }

            Button {
                viewModel.addStep()
            } label: {
                Label("Add step", systemImage: "plus")
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .disabled(
                viewModel.draft.steps.count >= RecipeContractLimits.steps
            )
            if viewModel.hasIssue(.tooManySteps) {
                validationText("A recipe can have at most 200 steps.")
            }
        }
    }

    private var nutritionSection: some View {
        editorSection(
            title: "Nutrition",
            message: "Leave a value blank when it isn’t known. Estimated values stay clearly labeled."
        ) {
            Toggle(
                "Include nutrition",
                isOn: $viewModel.draft.nutrition.isIncluded
            )
            .ladleFont(.bodyStrong)
            .tint(LadleTheme.paprika)

            if viewModel.draft.nutrition.isIncluded {
                nutritionField(
                    "Calories",
                    text: $viewModel.draft.nutrition.calories
                )
                nutritionField(
                    "Protein (g)",
                    text: $viewModel.draft.nutrition.proteinGrams
                )
                nutritionField(
                    "Carbohydrates (g)",
                    text: $viewModel.draft.nutrition.carbohydrateGrams
                )
                nutritionField(
                    "Fat (g)",
                    text: $viewModel.draft.nutrition.fatGrams
                )
                nutritionField(
                    "Saturated fat (g)",
                    text: $viewModel.draft.nutrition.saturatedFatGrams
                )
                nutritionField(
                    "Fiber (g)",
                    text: $viewModel.draft.nutrition.fiberGrams
                )
                nutritionField(
                    "Sugar (g)",
                    text: $viewModel.draft.nutrition.sugarGrams
                )
                nutritionField(
                    "Sodium (mg)",
                    text: $viewModel.draft.nutrition.sodiumMilligrams
                )
                nutritionField(
                    "Serving basis",
                    text: $viewModel.draft.nutrition.servingBasis
                )

                Toggle(
                    "Values are estimated",
                    isOn: $viewModel.draft.nutrition.isEstimated
                )
                .ladleFont(.bodyStrong)
                .tint(LadleTheme.paprika)

                let nutritionIssues = viewModel.validationIssues.filter {
                    if case .nutritionValueInvalid = $0 {
                        return true
                    }
                    return false
                }
                if !nutritionIssues.isEmpty {
                    validationText(
                        "Nutrition values must be between zero and 1,000,000; serving basis must be positive."
                    )
                }
            }
        }
    }

    private func ingredientCard(
        index: Int,
        ingredient: RecipeDraft.IngredientDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            itemHeader(
                title: "Ingredient \(index + 1)",
                index: index,
                count: viewModel.draft.ingredients.count,
                moveUp: {
                    viewModel.moveIngredient(from: index, to: index - 1)
                },
                moveDown: {
                    viewModel.moveIngredient(from: index, to: index + 1)
                },
                delete: {
                    viewModel.removeIngredient(id: ingredient.id)
                }
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ingredientQuantityField(at: index)
                    ingredientUnitField(at: index)
                }

                VStack(spacing: 10) {
                    ingredientQuantityField(at: index)
                    ingredientUnitField(at: index)
                }
            }
            editorField(
                title: "Ingredient name",
                text: $viewModel.draft.ingredients[index].name
            )
            editorField(
                title: "Preparation",
                text: $viewModel.draft.ingredients[index].preparation
            )
            if viewModel.hasIssue(
                .ingredientNameRequired(ingredient.id)
            ) {
                validationText("Add an ingredient name.")
            }
            if viewModel.hasIssue(
                .ingredientFieldTooLong(ingredient.id)
            ) {
                validationText(
                    "Shorten this ingredient’s quantity, unit, name, or preparation."
                )
            }
        }
        .padding(16)
        .editorSurface()
    }

    private func stepCard(
        index: Int,
        step: RecipeDraft.StepDraft
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            itemHeader(
                title: "Step \(index + 1)",
                index: index,
                count: viewModel.draft.steps.count,
                moveUp: {
                    viewModel.moveStep(from: index, to: index - 1)
                },
                moveDown: {
                    viewModel.moveStep(from: index, to: index + 1)
                },
                delete: {
                    viewModel.removeStep(id: step.id)
                }
            )

            TextEditor(
                text: $viewModel.draft.steps[index].instruction
            )
            .ladleFont(.body)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: 120)
            .background(
                LadleTheme.paper,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .accessibilityLabel("Step \(index + 1) instruction")

            if viewModel.hasIssue(.stepInstructionRequired(step.id)) {
                validationText("Add an instruction for this step.")
            }
            if viewModel.hasIssue(.stepInstructionTooLong(step.id)) {
                validationText(
                    "Keep this instruction to 5,000 characters or fewer."
                )
            }
        }
        .padding(16)
        .editorSurface()
    }

    private func editorSection<Content: View>(
        title: String,
        message: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
                Text(message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.62))
            }

            content()

            if viewModel.state == .persistenceFailed {
                validationText(
                    "Overeasy couldn’t save these edits. Your draft is still here."
                )
            }
        }
    }

    private func editorField(
        title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        showsClearButton: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
            HStack(spacing: 8) {
                TextField(title, text: text)
                    .ladleFont(.body)
                    .keyboardType(keyboardType)
                    .accessibilityLabel(title)
                    .frame(minHeight: 44)

                if showsClearButton, !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(
                                LadleTheme.ink.opacity(0.42)
                            )
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear \(title)")
                }
            }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .editorSurface()
        }
    }

    private func compactField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
            TextField(title, text: text)
                .ladleFont(.body)
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(
                    LadleTheme.paper,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity)
    }

    private func nutritionField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        editorField(
            title: title,
            text: text,
            keyboardType: .decimalPad
        )
    }

    private func itemHeader(
        title: String,
        index: Int,
        count: Int,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    itemTitle(title)
                    HStack(spacing: 0) {
                        Spacer()
                        itemActions(
                            title: title,
                            index: index,
                            count: count,
                            moveUp: moveUp,
                            moveDown: moveDown,
                            delete: delete
                        )
                    }
                }
            } else {
                HStack {
                    itemTitle(title)
                    Spacer()
                    itemActions(
                        title: title,
                        index: index,
                        count: count,
                        moveUp: moveUp,
                        moveDown: moveDown,
                        delete: delete
                    )
                }
            }
        }
        .foregroundStyle(LadleTheme.paprika)
    }

    private func itemTitle(_ title: String) -> some View {
        Text(title)
            .ladleFont(.section)
            .foregroundStyle(LadleTheme.ink)
    }

    @ViewBuilder
    private func itemActions(
        title: String,
        index: Int,
        count: Int,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        Group {
            Button(action: moveUp) {
                Image(systemName: "arrow.up")
                    .frame(width: 44, height: 44)
            }
            .disabled(index == 0)
            .accessibilityLabel("Move \(title) up")

            Button(action: moveDown) {
                Image(systemName: "arrow.down")
                    .frame(width: 44, height: 44)
            }
            .disabled(index == count - 1)
            .accessibilityLabel("Move \(title) down")

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Delete \(title)")
        }
    }

    private func ingredientQuantityField(at index: Int) -> some View {
        compactField(
            "Quantity",
            text: $viewModel.draft.ingredients[index].quantityText
        )
    }

    private func ingredientUnitField(at index: Int) -> some View {
        compactField(
            "Unit",
            text: $viewModel.draft.ingredients[index].unit
        )
    }

    private func validationText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.paprika)
    }
}

private extension View {
    func editorSurface() -> some View {
        background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
    }
}
