import LadleCore
import SwiftUI
import UIKit

struct WatchView: View {
    @Bindable var viewModel: LibraryViewModel
    let openRecipe: (Recipe) -> Void
    let openAccount: () -> Void

    @State private var cookingViewModel: CookingViewModel?
    @State private var isMuted = false
    @State private var visibleRecipeID: UUID?

    var body: some View {
        Group {
            if viewModel.watchRecipes.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.watchRecipes) { recipe in
                            WatchRecipePage(
                                recipe: recipe,
                                viewportSize: viewportSize,
                                isVideoActive: activeRecipeID == recipe.id,
                                isMuted: $isMuted,
                                openRecipe: { openRecipe(recipe) },
                                openAccount: openAccount,
                                startCooking: {
                                    cookingViewModel = CookingViewModel(
                                        recipe: recipe
                                    )
                                },
                                toggleFavorite: {
                                    viewModel.toggleFavorite(
                                        recipeID: recipe.id
                                    )
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
        }
        .background(LadleTheme.plum)
        .fullScreenCover(item: $cookingViewModel) {
            FullRecipeView(viewModel: $0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.watch.root")
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

    private var activeRecipeID: UUID? {
        visibleRecipeID ?? viewModel.watchRecipes.first?.id
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No saved videos",
            systemImage: "play.rectangle",
            description: Text("Saved video recipes appear here.")
        )
        .foregroundStyle(LadleTheme.onAccent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WatchRecipePage: View {
    let recipe: Recipe
    let viewportSize: CGSize
    let isVideoActive: Bool
    @Binding var isMuted: Bool
    let openRecipe: () -> Void
    let openAccount: () -> Void
    let startCooking: () -> Void
    let toggleFavorite: () -> Void

    @State private var isPlaybackPaused = false

    var body: some View {
        videoLayout
            .frame(width: viewportSize.width, height: viewportSize.height)
            .background(LadleTheme.plum)
            .recipeContextMenu(
                recipe: recipe,
                openRecipe: openRecipe,
                toggleFavorite: toggleFavorite
            )
            .sensoryFeedback(.selection, trigger: recipe.isFavorite)
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
        .padding(.bottom, 88 + LadleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var playbackActions: some View {
        HStack(spacing: LadleTheme.Spacing.compact) {
            if recipe.canStartCooking {
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
            Text("Watch")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.onAccent)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.black.opacity(0.56), in: Capsule())

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
        [
            recipe.totalMinutes.map { "\($0) min" },
            recipe.libraryNutrition?.proteinGrams.map {
                "\(ladleNumber($0)) g protein"
            },
            recipe.ladleYieldText,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
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
