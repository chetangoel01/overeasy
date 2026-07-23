import Foundation
import LadleCore
import Observation

enum LibraryDisplayMode: String, CaseIterable {
    case grid
    case list
}

@MainActor
@Observable
final class LibraryViewModel {
    enum LoadState: Equatable {
        case idle
        case loaded
        case failed(String)
    }

    private enum PreferenceKey {
        static let displayMode = "ladle.library.display-mode"
    }

    @ObservationIgnored
    private let repository: RecipeRepository

    @ObservationIgnored
    private let preferenceStore: PreferenceStoring

    private(set) var recipes: [Recipe] = []
    private(set) var importJobs: [ImportJob] = []
    private(set) var loadState: LoadState = .idle
    private(set) var operationErrorMessage: String?

    var searchText = ""
    var sort: RecipeSort = .recentlyAdded
    var favoritesOnly = false
    var maximumTotalMinutes: Int?
    var maximumCalories: Decimal?

    var displayMode: LibraryDisplayMode {
        didSet {
            preferenceStore.set(
                displayMode.rawValue,
                forKey: PreferenceKey.displayMode
            )
        }
    }

    init(
        repository: RecipeRepository,
        preferenceStore: PreferenceStoring = UserDefaults.standard
    ) {
        self.repository = repository
        self.preferenceStore = preferenceStore
        displayMode = preferenceStore
            .string(forKey: PreferenceKey.displayMode)
            .flatMap(LibraryDisplayMode.init(rawValue:))
            ?? .grid
    }

    static func resetDisplayPreference(
        in preferenceStore: PreferenceStoring = UserDefaults.standard
    ) {
        preferenceStore.removeObject(forKey: PreferenceKey.displayMode)
    }

    var visibleRecipes: [Recipe] {
        RecipeQuery(
            searchText: searchText,
            sort: sort,
            favoritesOnly: favoritesOnly,
            maximumTotalMinutes: maximumTotalMinutes,
            maximumCalories: maximumCalories
        )
        .apply(to: recipes)
    }

    var actionableImportJobs: [ImportJob] {
        importJobs
            .filter { job in
                switch job.status {
                case .ready:
                    false
                case .parsing, .needsReview, .failed:
                    true
                }
            }
            .sorted { lhs, rhs in
                let leftPriority = priority(for: lhs.status)
                let rightPriority = priority(for: rhs.status)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func load() {
        do {
            recipes = try repository.fetchRecipes()
            importJobs = try repository.fetchImportJobs()
            loadState = .loaded
        } catch {
            recipes = []
            importJobs = []
            loadState = .failed("Your recipes couldn’t be loaded.")
        }
    }

    func toggleFavorite(recipeID: UUID) {
        guard var recipe = recipes.first(where: { $0.id == recipeID }) else {
            return
        }

        recipe.isFavorite.toggle()
        recipe.updatedAt = .now

        do {
            try repository.save(recipe)
            if let index = recipes.firstIndex(
                where: { $0.id == recipeID }
            ) {
                recipes[index] = recipe
            }
            operationErrorMessage = nil
        } catch {
            operationErrorMessage = "That favorite couldn’t be updated."
        }
    }

    func makeEditorViewModel(
        for recipe: Recipe
    ) -> RecipeEditorViewModel {
        RecipeEditorViewModel(
            recipe: recipe,
            repository: repository
        )
    }

    func removeMaximumTimeFilter() {
        maximumTotalMinutes = nil
    }

    func removeMaximumCaloriesFilter() {
        maximumCalories = nil
    }

    func removeFavoritesFilter() {
        favoritesOnly = false
    }

    func clearOperationError() {
        operationErrorMessage = nil
    }

    private func priority(for status: ImportStatus) -> Int {
        switch status {
        case .failed:
            0
        case .needsReview:
            1
        case .parsing:
            2
        case .ready:
            3
        }
    }
}
