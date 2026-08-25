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
    private(set) var savingSourceIDs: Set<UUID> = []
    private(set) var loadingDetailSourceIDs: Set<UUID> = []
    private(set) var savedSourceIDs: Set<UUID> = []
    private(set) var saveErrorMessage: String?
    private(set) var detailErrorMessage: String?

    init(service: any DiscoverServing) {
        self.service = service
    }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let recipes = try await service.fetchDiscoverRecipes()
            savedSourceIDs = Set(
                recipes.lazy.compactMap { recipe in
                    recipe.savedRecipeID == nil ? nil : recipe.sourceID
                }
            )
            state = .loaded(
                recipes.filter { $0.savedRecipeID == nil }
            )
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed
        }
    }

    func isSaving(_ recipe: DiscoverRecipe) -> Bool {
        savingSourceIDs.contains(recipe.sourceID)
    }

    func isSaved(_ recipe: DiscoverRecipe) -> Bool {
        savedSourceIDs.contains(recipe.sourceID)
            || recipe.savedRecipeID != nil
    }

    func isLoadingDetail(_ recipe: DiscoverRecipe) -> Bool {
        loadingDetailSourceIDs.contains(recipe.sourceID)
    }

    func detail(for recipe: DiscoverRecipe) async -> Recipe? {
        guard !isLoadingDetail(recipe) else { return nil }
        loadingDetailSourceIDs.insert(recipe.sourceID)
        defer { loadingDetailSourceIDs.remove(recipe.sourceID) }
        do {
            let detail = try await service.fetchDiscoverRecipe(
                sourceID: recipe.sourceID
            )
            detailErrorMessage = nil
            return detail
        } catch {
            saveErrorMessage = nil
            detailErrorMessage = "That recipe couldn’t be opened."
            return nil
        }
    }

    func save(
        _ recipe: DiscoverRecipe
    ) async -> SavedDiscoverRecipe? {
        guard !isSaving(recipe), !isSaved(recipe) else {
            return nil
        }
        savingSourceIDs.insert(recipe.sourceID)
        defer { savingSourceIDs.remove(recipe.sourceID) }
        do {
            let saved = try await service.saveDiscoverRecipe(
                sourceID: recipe.sourceID
            )
            savedSourceIDs.insert(recipe.sourceID)
            if case let .loaded(recipes) = state {
                state = .loaded(
                    recipes.filter { $0.sourceID != recipe.sourceID }
                )
            }
            saveErrorMessage = nil
            detailErrorMessage = nil
            return saved
        } catch {
            detailErrorMessage = nil
            saveErrorMessage = "That recipe couldn’t be saved."
            return nil
        }
    }

    func clearOperationError() {
        saveErrorMessage = nil
        detailErrorMessage = nil
    }
}

struct DiscoverView: View {
    @State private var viewModel: DiscoverViewModel
    let saveRecipe: (SavedDiscoverRecipe) -> Void
    let openRecipe: (Recipe) -> Void

    init(
        service: any DiscoverServing,
        saveRecipe: @escaping (SavedDiscoverRecipe) -> Void,
        openRecipe: @escaping (Recipe) -> Void
    ) {
        _viewModel = State(
            initialValue: DiscoverViewModel(service: service)
        )
        self.saveRecipe = saveRecipe
        self.openRecipe = openRecipe
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
        .alert(
            viewModel.detailErrorMessage == nil
                ? "Couldn’t save recipe"
                : "Couldn’t open recipe",
            isPresented: operationErrorIsPresented
        ) {
            Button("OK", action: viewModel.clearOperationError)
        } message: {
            Text(
                viewModel.detailErrorMessage
                    ?? viewModel.saveErrorMessage
                    ?? "Please try again."
            )
        }
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
                        isLoadingDetail: viewModel.isLoadingDetail(recipe),
                        isSaving: viewModel.isSaving(recipe),
                        isSaved: viewModel.isSaved(recipe),
                        open: {
                            Task {
                                if let detail = await viewModel.detail(
                                    for: recipe
                                ) {
                                    openRecipe(detail)
                                }
                            }
                        },
                        save: {
                            Task {
                                if let saved = await viewModel.save(recipe) {
                                    saveRecipe(saved)
                                }
                            }
                        }
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

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: {
                viewModel.saveErrorMessage != nil
                    || viewModel.detailErrorMessage != nil
            },
            set: { if !$0 { viewModel.clearOperationError() } }
        )
    }
}

private struct DiscoverRecipeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recipe: DiscoverRecipe
    let isLoadingDetail: Bool
    let isSaving: Bool
    let isSaved: Bool
    let open: () -> Void
    let save: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: open) {
                        details
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingDetail)
                    saveButton
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Button(action: open) {
                        HStack(alignment: .top, spacing: 14) {
                            artwork
                            details
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingDetail)
                    saveButton
                }
            }
        }
        .padding(.vertical, 14)
        .contextMenu {
            Button("View Recipe", systemImage: "book.pages", action: open)
            if !isSaved {
                Button("Save Recipe", systemImage: "plus", action: save)
            }
        } preview: {
            DiscoverRecipeContextPreview(recipe: recipe)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open recipe", open)
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
        .overlay {
            if isLoadingDetail {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    ProgressView()
                        .tint(LadleTheme.brick)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var saveButton: some View {
        Button(action: save) {
            Group {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LadleTheme.onAccent)
                } else {
                    Label(
                        isSaved ? "Saved" : "Save",
                        systemImage: isSaved ? "checkmark" : "plus"
                    )
                }
            }
                .ladleFont(.metadata)
                .foregroundStyle(
                    isSaved ? LadleTheme.ink : LadleTheme.onAccent
                )
                .padding(.horizontal, 13)
                .frame(minHeight: 44)
                .background(
                    isSaved ? LadleTheme.celery : LadleTheme.brick,
                    in: Capsule()
                )
        }
        .buttonStyle(LadlePressButtonStyle())
        .disabled(isSaving || isSaved)
        .accessibilityLabel(
            isSaved ? "\(recipe.title) saved" : "Save \(recipe.title)"
        )
    }

    private var saveCountText: String {
        recipe.savedCount == 1
            ? "Saved by 1 cook"
            : "Saved by \(recipe.savedCount) cooks"
    }
}

private struct DiscoverRecipeContextPreview: View {
    let recipe: DiscoverRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: recipe.imageURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle()
                        .fill(LadleTheme.oat)
                        .overlay {
                            Image(systemName: "fork.knife")
                                .foregroundStyle(LadleTheme.paprika)
                        }
                }
            }
            .frame(height: 210)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )

            Text(recipe.creatorName ?? recipe.source.libraryTitle)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.accentText)
            Text(recipe.title)
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)
            if !recipe.description.isEmpty {
                Text(recipe.description)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(LadleTheme.paper)
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
