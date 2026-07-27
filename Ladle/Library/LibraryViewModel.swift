import Foundation
import LadleCore
import Observation

enum LibraryDisplayMode: String, CaseIterable {
    case grid
    case list
}

enum LibraryRecipeCollection: Equatable {
    case all
    case quick
    case favorites
    case uncooked
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
        static let savedCollapsed = "ladle.library.saved-collapsed"
        static let comeBackCollapsed = "ladle.library.comeback-collapsed"
    }

    @ObservationIgnored
    private let repository: RecipeRepository

    @ObservationIgnored
    private let preferenceStore: PreferenceStoring

    @ObservationIgnored
    private let now: () -> Date

    private let didMutate:
        @MainActor @Sendable () async -> Void

    private(set) var recipes: [Recipe] = []
    private(set) var importJobs: [ImportJob] = []
    private(set) var loadState: LoadState = .idle
    private(set) var operationErrorMessage: String?

    var searchText = ""
    var sort: RecipeSort = .recentlyAdded
    var favoritesOnly = false
    var maximumTotalMinutes: Int?
    var maximumCalories: Decimal?
    var minimumProtein: Decimal?
    var maximumCarbohydrates: Decimal?
    var maximumFat: Decimal?
    var selectedCollection: LibraryRecipeCollection = .all

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
        preferenceStore: PreferenceStoring = UserDefaults.standard,
        now: @escaping () -> Date = Date.init,
        didMutate:
            @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.preferenceStore = preferenceStore
        self.now = now
        self.didMutate = didMutate
        displayMode = preferenceStore
            .string(forKey: PreferenceKey.displayMode)
            .flatMap(LibraryDisplayMode.init(rawValue:))
            ?? .grid
        isSavedThisWeekCollapsed = preferenceStore.bool(
            forKey: PreferenceKey.savedCollapsed
        )
        isComeBackToCollapsed = preferenceStore.bool(
            forKey: PreferenceKey.comeBackCollapsed
        )
    }

    private(set) var isSavedThisWeekCollapsed = false
    private(set) var isComeBackToCollapsed = false

    func toggleSavedThisWeekCollapsed() {
        isSavedThisWeekCollapsed.toggle()
        preferenceStore.set(
            isSavedThisWeekCollapsed,
            forKey: PreferenceKey.savedCollapsed
        )
    }

    func toggleComeBackToCollapsed() {
        isComeBackToCollapsed.toggle()
        preferenceStore.set(
            isComeBackToCollapsed,
            forKey: PreferenceKey.comeBackCollapsed
        )
    }

    func clearLocalLibrary() {
        try? repository.wipeAllData()
        load()
    }

    static func resetPreferences(
        in preferenceStore: PreferenceStoring = UserDefaults.standard
    ) {
        [
            PreferenceKey.displayMode,
            "ladle.library.inbox-dismissed",
            PreferenceKey.savedCollapsed,
            PreferenceKey.comeBackCollapsed,
        ].forEach {
            preferenceStore.removeObject(forKey: $0)
        }
    }

    var visibleRecipes: [Recipe] {
        let matches = RecipeQuery(
            searchText: searchText,
            sort: sort,
            favoritesOnly: favoritesOnly,
            maximumTotalMinutes: maximumTotalMinutes,
            maximumCalories: maximumCalories,
            minimumProtein: minimumProtein,
            maximumCarbohydrates: maximumCarbohydrates,
            maximumFat: maximumFat
        )
        .apply(to: recipes)
        return matches.filter(matchesSelectedCollection)
    }

    var savedThisWeek: [Recipe] {
        guard let week = Calendar.autoupdatingCurrent.dateInterval(
            of: .weekOfYear,
            for: now()
        ) else {
            return []
        }
        return RecipeQuery().apply(
            to: recipes.filter { week.contains($0.createdAt) }
        )
    }

    var quickRecipes: [Recipe] {
        RecipeQuery(maximumTotalMinutes: 30).apply(to: recipes)
    }

    var favoriteRecipes: [Recipe] {
        RecipeQuery(favoritesOnly: true).apply(to: recipes)
    }

    var uncookedRecipes: [Recipe] {
        RecipeQuery().apply(to: recipes.filter { $0.lastCookedAt == nil })
    }

    var watchRecipes: [Recipe] {
        RecipeQuery().apply(to: recipes.filter { $0.source != .other })
    }

    func searchResults(matching text: String) -> [Recipe] {
        RecipeQuery(searchText: text).apply(to: recipes)
    }

    func recipeForReview(_ job: ImportJob) -> Recipe? {
        for recipeID in [job.reviewRecipeID, job.currentRecipeID]
            .compactMap({ $0 }) {
            if let recipe = recipes.first(where: { $0.id == recipeID }) {
                return recipe
            }
        }
        return nil
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

    var importAttentionCount: Int {
        actionableImportJobs.filter {
            switch $0.status {
            case .needsReview, .failed:
                true
            case .parsing, .ready:
                false
            }
        }
        .count
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
            Task {
                await didMutate()
            }
        } catch {
            operationErrorMessage = "That favorite couldn’t be updated."
        }
    }

    func deleteRecipe(recipeID: UUID) -> Bool {
        do {
            try repository.deleteRecipe(id: recipeID)
            recipes.removeAll { $0.id == recipeID }
            operationErrorMessage = nil
            Task {
                await didMutate()
            }
            return true
        } catch {
            operationErrorMessage = "That recipe couldn’t be deleted."
            return false
        }
    }

    func deleteImport(jobID: UUID) -> Bool {
        do {
            try repository.deleteImportJob(id: jobID)
            importJobs.removeAll { $0.id == jobID }
            operationErrorMessage = nil
            return true
        } catch {
            operationErrorMessage = "That import couldn’t be deleted."
            return false
        }
    }

    func completeReview(recipeID: UUID) -> Recipe? {
        guard var recipe = recipes.first(
            where: { $0.id == recipeID }
        ) else {
            return nil
        }
        recipe.reviewStatus = .ready
        recipe.updatedAt = now()

        do {
            let completedJobs = try importJobs.map { job in
                guard job.status == .needsReview,
                      job.reviewCandidate == nil,
                      job.reviewRecipeID == recipeID else {
                    return job
                }
                return try job.transitioning(
                    to: .ready,
                    at: recipe.updatedAt
                )
            }
            try repository.completeReview(
                recipe: recipe,
                importJobs: completedJobs.filter { completed in
                    importJobs.contains {
                        $0.id == completed.id
                            && $0.status != completed.status
                    }
                }
            )
            recipes[recipes.firstIndex { $0.id == recipeID }!] = recipe
            importJobs = completedJobs
            operationErrorMessage = nil
            Task {
                await didMutate()
            }
            return recipe
        } catch {
            operationErrorMessage = "That review couldn’t be completed."
            return nil
        }
    }

    func makeEditorViewModel(
        for recipe: Recipe
    ) -> RecipeEditorViewModel {
        RecipeEditorViewModel(
            recipe: recipe,
            repository: repository,
            didSave: didMutate
        )
    }

    func removeMaximumTimeFilter() {
        maximumTotalMinutes = nil
    }

    func removeMaximumCaloriesFilter() {
        maximumCalories = nil
    }

    func removeMinimumProteinFilter() {
        minimumProtein = nil
    }

    func removeMaximumCarbohydratesFilter() {
        maximumCarbohydrates = nil
    }

    func removeMaximumFatFilter() {
        maximumFat = nil
    }

    func removeFavoritesFilter() {
        favoritesOnly = false
    }

    func showCollection(_ collection: LibraryRecipeCollection) {
        selectedCollection = collection
        searchText = ""
        sort = .recentlyAdded
        favoritesOnly = false
        maximumTotalMinutes = nil
        maximumCalories = nil
        minimumProtein = nil
        maximumCarbohydrates = nil
        maximumFat = nil
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

    private func matchesSelectedCollection(_ recipe: Recipe) -> Bool {
        switch selectedCollection {
        case .all:
            true
        case .quick:
            recipe.totalMinutes.map { $0 <= 30 } ?? false
        case .favorites:
            recipe.isFavorite
        case .uncooked:
            recipe.lastCookedAt == nil
        }
    }
}
