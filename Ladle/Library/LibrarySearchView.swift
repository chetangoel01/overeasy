import LadleCore
import SwiftUI

struct LibrarySearchView: View {
    @Bindable var viewModel: LibraryViewModel
    let openRecipe: (Recipe) -> Void

    @FocusState private var searchIsFocused: Bool
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            LibraryDestinationHeader("Search")
            searchField
            content
        }
        .background(LadleTheme.paper)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await Task.yield()
            searchIsFocused = true
        }
        .accessibilityIdentifier("library.search")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LadleTheme.mutedInk)
            TextField(
                "Recipe, ingredient, or creator",
                text: $query
            )
            .focused($searchIsFocused)
            .submitLabel(.search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .foregroundStyle(LadleTheme.mutedInk)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.bottom, LadleTheme.Spacing.regular)
    }

    @ViewBuilder
    private var content: some View {
        if normalizedQuery.isEmpty {
            searchPrompt
        } else if results.isEmpty {
            emptyResults
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(results) { recipe in
                        RecipeListRow(
                            recipe: recipe,
                            openRecipe: { openRecipe(recipe) },
                            toggleFavorite: {
                                viewModel.toggleFavorite(recipeID: recipe.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var searchPrompt: some View {
        ContentUnavailableView(
            "Find any saved recipe",
            systemImage: "text.magnifyingglass",
            description: Text(
                "Search recipe names, ingredients, and creators."
            )
        )
        .foregroundStyle(LadleTheme.ink)
    }

    private var emptyResults: some View {
        ContentUnavailableView.search(text: normalizedQuery)
            .foregroundStyle(LadleTheme.ink)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [Recipe] {
        viewModel.searchResults(matching: normalizedQuery)
    }
}
