import LadleCore
import SwiftUI
import UIKit

private enum WatchFeed: String, CaseIterable, Identifiable {
    case myRecipes = "My Recipes"
    case discover = "Discover"

    var id: Self { self }
}

struct WatchView: View {
    @Bindable var viewModel: LibraryViewModel
    let refreshVersion: Int
    let openSavedRecipe: (Recipe) -> Void
    let openDiscoverRecipe: (Recipe) -> Void
    let saveRecipe: (SavedDiscoverRecipe) -> Void
    let openAccount: () -> Void

    @State private var discoverViewModel: DiscoverViewModel
    @State private var cookingViewModel: CookingViewModel?
    @State private var isMuted = false
    @State private var visibleRecipeID: UUID?
    @State private var feed = WatchFeed.discover

    init(
        viewModel: LibraryViewModel,
        discoverService: any DiscoverServing,
        refreshVersion: Int,
        openSavedRecipe: @escaping (Recipe) -> Void,
        openDiscoverRecipe: @escaping (Recipe) -> Void,
        saveRecipe: @escaping (SavedDiscoverRecipe) -> Void,
        openAccount: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.refreshVersion = refreshVersion
        self.openSavedRecipe = openSavedRecipe
        self.openDiscoverRecipe = openDiscoverRecipe
        self.saveRecipe = saveRecipe
        self.openAccount = openAccount
        _discoverViewModel = State(
            initialValue: DiscoverViewModel(
                service: discoverService,
                removesSavedRecipeImmediately: false
            )
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if feed == .discover {
                    discoverContent
                } else if viewModel.watchRecipes.isEmpty {
                    emptyState(
                        title: "No saved videos",
                        message: "Saved video recipes appear here."
                    )
                } else {
                    recipeFeed(viewModel.watchRecipes)
                }
            }

            feedPicker
                .padding(.leading, LadleTheme.Spacing.regular)
                .padding(.top, 60)
                .zIndex(1)
        }
        .background(LadleTheme.plum)
        .fullScreenCover(item: $cookingViewModel) {
            FullRecipeView(viewModel: $0)
        }
        .task(id: refreshVersion) {
            await discoverViewModel.load()
        }
        .onChange(of: feed) { _, newFeed in
            visibleRecipeID = nil
            if newFeed == .discover {
                Task { await discoverViewModel.load() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.watch.root")
    }

    @ViewBuilder
    private var discoverContent: some View {
        switch discoverViewModel.state {
        case .idle, .loading:
            loadingState
        case .failed:
            emptyState(
                title: "Couldn’t load Discover",
                message: "Your saved recipe videos are still available.",
                retry: { Task { await discoverViewModel.load() } }
            )
        case let .loaded(recipes) where recipes.isEmpty:
            emptyState(
                title: "Nothing new to watch",
                message: "Saved discoveries stay out of your feed."
            )
        case let .loaded(recipes):
            recipeFeed(recipes.map(\.watchPreview))
        }
    }

    private func recipeFeed(_ recipes: [Recipe]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(recipes) { recipe in
                    WatchRecipePage(
                        recipe: recipe,
                        viewportSize: viewportSize,
                        isVideoActive: activeRecipeID(in: recipes) == recipe.id,
                        isMuted: $isMuted,
                        discoverRecipe: discoverRecipe(id: recipe.id),
                        isSaving: discoverRecipe(id: recipe.id).map(
                            discoverViewModel.isSaving
                        ) ?? false,
                        isSaved: discoverRecipe(id: recipe.id).map(
                            discoverViewModel.isSaved
                        ) ?? false,
                        openRecipe: { open(recipe) },
                        openAccount: openAccount,
                        save: { save(recipe) },
                        startCooking: {
                            cookingViewModel = CookingViewModel(recipe: recipe)
                        },
                        toggleFavorite: {
                            viewModel.toggleFavorite(recipeID: recipe.id)
                        }
                    )
                    .clipped()
                    .id(recipe.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleRecipeID)
        .ignoresSafeArea()
    }

    private func open(_ recipe: Recipe) {
        guard let discovered = discoverRecipe(id: recipe.id) else {
            openSavedRecipe(recipe)
            return
        }
        Task {
            if let detail = await discoverViewModel.detail(for: discovered) {
                openDiscoverRecipe(detail)
            }
        }
    }

    private func save(_ recipe: Recipe) {
        guard let discovered = discoverRecipe(id: recipe.id) else { return }
        Task {
            if let saved = await discoverViewModel.save(discovered) {
                saveRecipe(saved)
            }
        }
    }

    private func discoverRecipe(id: UUID) -> DiscoverRecipe? {
        guard feed == .discover else { return nil }
        guard case let .loaded(recipes) = discoverViewModel.state else {
            return nil
        }
        return recipes.first { $0.sourceID == id }
    }

    private var viewportSize: CGSize {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        if let windowSize = scene?.windows
            .first(where: \.isKeyWindow)?
            .frame
            .size {
            return windowSize
        }
        guard let screen = scene?.screen else {
            return CGSize(width: 1, height: 1)
        }
        let nativeSize = screen.nativeBounds.size
        return CGSize(
            width: min(nativeSize.width, nativeSize.height) / screen.nativeScale,
            height: max(nativeSize.width, nativeSize.height) / screen.nativeScale
        )
    }

    private func activeRecipeID(in recipes: [Recipe]) -> UUID? {
        visibleRecipeID ?? recipes.first?.id
    }

    private func emptyState(
        title: String,
        message: String,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            ContentUnavailableView(
                title,
                systemImage: "play.rectangle",
                description: Text(message)
            )
            .foregroundStyle(LadleTheme.onAccent)

            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(
                        LadlePrimaryButtonStyle(isProminent: false)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        ProgressView("Loading Discover")
            .tint(LadleTheme.onAccent)
            .foregroundStyle(LadleTheme.onAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var feedPicker: some View {
        Picker("Watch feed", selection: $feed) {
            ForEach(WatchFeed.allCases) { feed in
                Text(feed.rawValue).tag(feed)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 190)
        .accessibilityIdentifier("watch.feed")
    }
}

private extension DiscoverRecipe {
    var watchPreview: Recipe {
        Recipe(
            id: sourceID,
            title: title,
            description: description,
            creatorName: creatorName,
            source: source,
            originalURL: originalURL,
            images: imageURL.map { [RecipeImage(id: sourceID, remoteURL: $0)] } ?? [],
            servings: 1
        )
    }
}

private struct WatchRecipePage: View {
    let recipe: Recipe
    let viewportSize: CGSize
    let isVideoActive: Bool
    @Binding var isMuted: Bool
    let discoverRecipe: DiscoverRecipe?
    let isSaving: Bool
    let isSaved: Bool
    let openRecipe: () -> Void
    let openAccount: () -> Void
    let save: () -> Void
    let startCooking: () -> Void
    let toggleFavorite: () -> Void

    @State private var isPlaybackPaused = false

    var body: some View {
        contextualVideoLayout
            .frame(width: viewportSize.width, height: viewportSize.height)
            .background(LadleTheme.plum)
            .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    @ViewBuilder
    private var contextualVideoLayout: some View {
        if discoverRecipe != nil {
            videoLayout
                .contextMenu {
                    Button("View Recipe", systemImage: "book.pages", action: openRecipe)
                    if !isSaved {
                        Button("Save Recipe", systemImage: "plus", action: save)
                    }
                } preview: {
                    WatchRecipeContextPreview(recipe: recipe)
                }
        } else {
            videoLayout
                .recipeContextMenu(
                    recipe: recipe,
                    openRecipe: openRecipe,
                    toggleFavorite: toggleFavorite
                )
        }
    }

    private var videoLayout: some View {
        ZStack {
            Group {
                if isVideoActive {
                    InlineVideoPlayer(
                        recipe: recipe,
                        isPaused: isPlaybackPaused,
                        isMuted: isMuted
                    )
                } else {
                    WatchRecipeImage(recipe: recipe)
                        .accessibilityHidden(true)
                }
            }
                .frame(
                    width: viewportSize.width,
                    height: viewportSize.height
                )
                .ignoresSafeArea()

            playbackScrim

            VStack(spacing: 0) {
                topBar(topInset: 48)
                Spacer(minLength: 120)
                playbackRecipePanel
            }
            .frame(
                width: viewportSize.width,
                height: viewportSize.height
            )
        }
    }

    private var playbackScrim: some View {
        LinearGradient(
            stops: [
                .init(
                    color: LadleTheme.fixedInk.opacity(0.98),
                    location: 0
                ),
                .init(
                    color: LadleTheme.fixedInk.opacity(0.92),
                    location: 0.16
                ),
                .init(color: .clear, location: 0.3),
                .init(color: .clear, location: 0.56),
                .init(
                    color: LadleTheme.fixedInk.opacity(0.58),
                    location: 0.72
                ),
                .init(
                    color: LadleTheme.fixedInk.opacity(0.98),
                    location: 1
                ),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var playbackRecipePanel: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
            sourceBar

            Text(recipe.title)
                .ladleFont(.recipeTitle)
                .foregroundStyle(LadleTheme.onAccent)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !metadata.isEmpty {
                Text(metadata)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.onAccent.opacity(0.78))
                    .lineLimit(1)
            }

            playbackActions
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.top, LadleTheme.Spacing.medium)
        .padding(.bottom, LadleTheme.Layout.overlayBarClearance)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var playbackActions: some View {
        HStack(spacing: LadleTheme.Spacing.compact) {
            if discoverRecipe != nil {
                Button(action: save) {
                    Group {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label(
                                isSaved ? "Saved" : "Save",
                                systemImage: isSaved ? "checkmark" : "plus"
                            )
                        }
                    }
                }
                .buttonStyle(LadlePrimaryButtonStyle())
                .disabled(isSaving || isSaved)

                Button("View recipe", action: openRecipe)
                    .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            } else if recipe.canStartCooking {
                Button("Open recipe", action: openRecipe)
                    .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
                Button("Start cooking", action: startCooking)
                    .buttonStyle(LadlePrimaryButtonStyle())
            } else {
                Button("Review recipe", action: openRecipe)
                    .buttonStyle(LadlePrimaryButtonStyle())
            }
        }
    }

    private func topBar(topInset: CGFloat) -> some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            Spacer()

            LadleIconButton(
                systemImage: isPlaybackPaused ? "play.fill" : "pause.fill",
                accessibilityLabel: isPlaybackPaused
                    ? "Resume video"
                    : "Pause video",
                tone: .onDark
            ) {
                isPlaybackPaused.toggle()
            }
            .accessibilityIdentifier("watch.\(recipe.librarySlug)")
            .background(.black.opacity(0.48), in: Circle())

            LadleIconButton(
                systemImage: isMuted
                    ? "speaker.slash.fill"
                    : "speaker.wave.2.fill",
                accessibilityLabel: isMuted
                    ? "Unmute video"
                    : "Mute video",
                tone: .onDark
            ) {
                isMuted.toggle()
            }
            .background(.black.opacity(0.48), in: Circle())

            LadleIconButton(
                systemImage: "person.crop.circle",
                accessibilityLabel: "Account",
                tone: .onDark,
                action: openAccount
            )
            .background(.black.opacity(0.48), in: Circle())
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.top, topInset + LadleTheme.Spacing.medium)
    }

    private var sourceBar: some View {
        HStack(spacing: LadleTheme.Spacing.compact) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(LadleTheme.focusAccent)

            Text(recipe.creatorAccountLabel)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.onAccent)
                .lineLimit(1)

            Text(recipe.source.libraryTitle)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.onAccent.opacity(0.66))
                .lineLimit(1)

            Spacer(minLength: LadleTheme.Spacing.compact)
        }
    }

    private var metadata: String {
        if let discoverRecipe {
            return discoverRecipe.savedCount == 1
                ? "Saved by 1 cook"
                : "Saved by \(discoverRecipe.savedCount) cooks"
        }
        return [
            recipe.libraryNutrition?.calories.map {
                let prefix = recipe.libraryNutrition?.isEstimated == true
                    ? "≈ "
                    : ""
                return "\(prefix)\(ladleNumber($0, maximumFractionDigits: 0)) cal"
            },
            recipe.libraryNutrition?.proteinGrams.map {
                "\(ladleNumber($0)) g protein"
            },
            recipe.ladleYieldText,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }
}

private struct WatchRecipeContextPreview: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .frame(height: 210)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
            Text(recipe.creatorAccountLabel)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.accentText)
            Text(recipe.title)
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 300)
        .background(LadleTheme.paper)
    }
}

private struct WatchRecipeImage: View {
    let recipe: Recipe

    @ViewBuilder
    var body: some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
        } else {
            Rectangle()
                .fill(LadleTheme.plum)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 38))
                        .foregroundStyle(LadleTheme.onAccent.opacity(0.72))
                }
        }
    }
}
