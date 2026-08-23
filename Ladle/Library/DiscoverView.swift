import LadleCore
import Observation
import SwiftUI

@MainActor
@Observable
final class DiscoverViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([DiscoverRecipe])
        case failed
    }

    private let service: any DiscoverServing
    private(set) var state: State = .idle

    init(service: any DiscoverServing) {
        self.service = service
    }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            state = .loaded(try await service.fetchDiscoverRecipes())
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed
        }
    }
}

struct DiscoverView: View {
    @State private var viewModel: DiscoverViewModel
    let saveRecipe: (DiscoverRecipe) -> Void

    init(
        service: any DiscoverServing,
        saveRecipe: @escaping (DiscoverRecipe) -> Void
    ) {
        _viewModel = State(
            initialValue: DiscoverViewModel(service: service)
        )
        self.saveRecipe = saveRecipe
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                loadingContent
            case let .loaded(recipes) where recipes.isEmpty:
                emptyContent
            case let .loaded(recipes):
                recipeList(recipes)
            case .failed:
                failedContent
            }
        }
        .background(LadleTheme.paper)
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        .accessibilityIdentifier("library.discover")
    }

    private var loadingContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    DiscoverLoadingRow()
                    Divider()
                        .overlay(LadleTheme.ink.opacity(0.08))
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
        }
        .scrollDisabled(true)
        .accessibilityLabel("Loading Discover")
    }

    private var emptyContent: some View {
        ContentUnavailableView(
            "Nothing to discover yet",
            systemImage: "sparkles",
            description: Text(
                "Public recipe saves will collect here as more cooks use Overeasy."
            )
        )
        .foregroundStyle(LadleTheme.ink)
    }

    private var failedContent: some View {
        ContentUnavailableView {
            Label("Couldn’t load Discover", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Your saved recipes are still available.")
        } actions: {
            Button("Try again") {
                Task { await viewModel.load() }
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
        }
        .foregroundStyle(LadleTheme.ink)
    }

    private func recipeList(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved by cooks")
                        .ladleFont(.section)
                        .foregroundStyle(LadleTheme.ink)
                    Text("Popular public recipe videos, ranked by saves.")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                .padding(.vertical, LadleTheme.Spacing.medium)

                ForEach(recipes) { recipe in
                    DiscoverRecipeRow(
                        recipe: recipe,
                        save: { saveRecipe(recipe) }
                    )
                    Divider()
                        .overlay(LadleTheme.ink.opacity(0.08))
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.load() }
    }
}

private struct DiscoverRecipeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recipe: DiscoverRecipe
    let save: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    details
                    saveButton
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    artwork
                    details
                    saveButton
                }
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "discover.\(recipe.originalURL.absoluteString)"
        )
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                artwork
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(recipe.creatorName ?? recipe.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.paprika)
                    .lineLimit(1)
                Text(recipe.title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(2)
                if !recipe.description.isEmpty {
                    Text(recipe.description)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                        .lineLimit(2)
                }
                Text(saveCountText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        AsyncImage(url: recipe.imageURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    LadleTheme.oat
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(LadleTheme.paprika)
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .accessibilityHidden(true)
    }

    private var saveButton: some View {
        Button(action: save) {
            Label("Save", systemImage: "plus")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.onAccent)
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(LadleTheme.brick, in: Capsule())
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel("Save \(recipe.title)")
    }

    private var saveCountText: String {
        recipe.savedCount == 1
            ? "Saved by 1 cook"
            : "Saved by \(recipe.savedCount) cooks"
    }
}

private struct DiscoverLoadingRow: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: LadleTheme.Corner.control)
                .fill(LadleTheme.oat)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.ube)
                    .frame(width: 90, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.oat)
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.oat)
                    .frame(width: 150, height: 12)
            }
        }
        .padding(.vertical, 14)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
