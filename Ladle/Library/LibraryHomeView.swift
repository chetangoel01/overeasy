import LadleCore
import SwiftUI

struct LibraryHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let viewModel: LibraryViewModel
    let addRecipe: () -> Void
    let openRecipe: (Recipe) -> Void
    let openCollection: (LibraryRecipeCollection) -> Void
    let openImportInbox: () -> Void
    let openWatch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isImportInboxHidden = false

    private var homeCardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LadleTheme.Corner.card,
            style: .continuous
        )
    }

    private var collectionPanelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LadleTheme.Corner.card,
            style: .continuous
        )
    }

    var body: some View {
        ScrollView {
            if viewModel.recipes.isEmpty && viewModel.importJobs.isEmpty {
                firstRecipeState
            } else {
                VStack(
                    alignment: .leading,
                    spacing: LadleTheme.Spacing.generous
                ) {
                    if !viewModel.actionableImportJobs.isEmpty,
                       !isImportInboxHidden {
                        importInbox
                    }
                    watch
                    savedThisWeek
                    collections
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, 44)
            }
        }
        .scrollIndicators(.hidden)
        .simultaneousGesture(inboxVisibilityGesture)
        .onChange(of: viewModel.actionableImportJobs.map(\.id)) {
            oldIDs,
            newIDs in
            if newIDs.isEmpty || !Set(newIDs).isSubset(of: Set(oldIDs)) {
                isImportInboxHidden = false
            }
        }
        .accessibilityIdentifier("library.home")
    }

    private var inboxVisibilityGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard !viewModel.actionableImportJobs.isEmpty else {
                    return
                }
                if value.translation.height < -40 {
                    isImportInboxHidden = true
                } else if value.translation.height > 40 {
                    isImportInboxHidden = false
                }
            }
    }

    private var firstRecipeState: some View {
        VStack(spacing: LadleTheme.Spacing.generous) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 68, height: 68)
                .background(LadleTheme.ube, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: LadleTheme.Spacing.compact) {
                Text("Save your first recipe")
                    .ladleFont(.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.ink)

                Text(
                    "Paste a TikTok, Instagram, or YouTube link. Overeasy turns it into ingredients and steps you can cook from."
                )
                .ladleFont(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(LadleTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Add your first recipe", action: addRecipe)
                .buttonStyle(LadlePrimaryButtonStyle())

            HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                Text(
                    "While scrolling, you can also use Share and choose Add to Overeasy."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: 480)
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, 54)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.empty")
    }

    private var importInbox: some View {
        Button(action: openImportInbox) {
            HStack(spacing: 14) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 44, height: 44)
                    .background(LadleTheme.review, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import inbox")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)
                    Text(importInboxDetail)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(LadleTheme.mutedInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .ladleCard()
        }
        .buttonStyle(LadlePressButtonStyle(kind: .card))
        .contentShape(.interaction, homeCardShape)
        .clipShape(homeCardShape)
        .zIndex(1)
        .accessibilityIdentifier("library.import-inbox")
    }

    private var importInboxDetail: String {
        let count = viewModel.importAttentionCount
        if count > 0 {
            return "\(count) need\(count == 1 ? "s" : "") attention"
        }
        let active = viewModel.actionableImportJobs.count
        return active == 1
            ? "1 import in progress"
            : "\(active) imports in progress"
    }

    private var watch: some View {
        Button(action: openWatch) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Watch")
                        .ladleFont(.section)
                        .foregroundStyle(LadleTheme.onAccent)
                    Spacer()
                    Image(systemName: "play.fill")
                        .foregroundStyle(LadleTheme.plum)
                        .frame(width: 44, height: 44)
                        .background(LadleTheme.onAccent, in: Circle())
                }
                HStack(spacing: 8) {
                    ForEach(
                        viewModel.watchRecipes.prefix(columnCount)
                    ) { recipe in
                        watchThumbnail(recipe)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(LadleTheme.plum, in: homeCardShape)
        .buttonStyle(LadlePressButtonStyle(kind: .card))
        .contentShape(.interaction, homeCardShape)
        .clipShape(homeCardShape)
        .accessibilityIdentifier("library.watch")
    }

    @ViewBuilder
    private func watchThumbnail(_ recipe: Recipe) -> some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .clipped()
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LadleTheme.onAccent.opacity(0.12))
                .frame(height: 78)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(LadleTheme.onAccent)
                }
                .accessibilityHidden(true)
        }
    }

    private var savedThisWeek: some View {
        VStack(alignment: .leading, spacing: 12) {
            collapsibleHeader(
                title: "Saved this week",
                detail: countText(viewModel.savedThisWeek.count),
                isCollapsed: viewModel.isSavedThisWeekCollapsed,
                toggle: viewModel.toggleSavedThisWeekCollapsed
            )

            if !viewModel.isSavedThisWeekCollapsed {
                Group {
                    if viewModel.savedThisWeek.isEmpty {
                        Text("New saves will collect here for quick return.")
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.mutedInk)
                            .padding(.vertical, 18)
                    } else {
                        LazyVGrid(
                            columns: savedColumns,
                            spacing: 12
                        ) {
                            ForEach(
                                viewModel.savedThisWeek.prefix(3)
                            ) { recipe in
                                HomeRecipeThumbnail(
                                    recipe: recipe,
                                    action: { openRecipe(recipe) }
                                )
                            }
                        }
                    }
                }
                .transition(sectionTransition)
            }
        }
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsibleHeader(
                title: "Collections",
                detail: nil,
                isCollapsed: viewModel.isComeBackToCollapsed,
                toggle: viewModel.toggleComeBackToCollapsed
            )
            .padding(.bottom, 6)

            if !viewModel.isComeBackToCollapsed {
                VStack(spacing: 0) {
                    ForEach(
                        viewModel.collectionRows,
                        id: \.identifier
                    ) { row in
                        collectionRow(row)
                    }
                }
                .background(LadleTheme.oat, in: collectionPanelShape)
                .overlay {
                    collectionPanelShape
                        .stroke(
                            LadleTheme.ink.opacity(0.08),
                            lineWidth: 1
                        )
                }
                .clipShape(collectionPanelShape)
                .transition(sectionTransition)
            }
        }
    }

    private func collapsibleHeader(
        title: String,
        detail: String?,
        isCollapsed: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.22, extraBounce: 0)
            ) {
                toggle()
            }
        } label: {
            HStack(spacing: 8) {
                LadleSectionHeader(
                    title: title,
                    detail: isCollapsed ? nil : detail
                )
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LadleTheme.mutedInk)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint("Double tap to toggle")
    }

    private func collectionRow(
        _ row: LibraryCollectionRowPresentation
    ) -> some View {
        Button {
            openCollection(row.collection)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: row.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 36, height: 36)
                    .background(LadleTheme.ube, in: Circle())
                    .accessibilityHidden(true)

                Text(row.title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Text("\(row.count)")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                        .frame(minWidth: 24, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LadleTheme.mutedInk)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(LadlePressButtonStyle(kind: .card))
        .overlay(alignment: .bottom) {
            if row.showsDivider {
                Divider()
                    .overlay(LadleTheme.ink.opacity(0.08))
                    .padding(.leading, 60)
            }
        }
        .accessibilityLabel(row.title)
        .accessibilityValue(countText(row.count))
        .accessibilityIdentifier(
            "library.collection.\(row.identifier)"
        )
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private var sectionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var savedColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: columnCount
        )
    }

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 3
    }
}

private struct HomeRecipeThumbnail: View {
    let recipe: Recipe
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                recipeImage
                Text(recipe.title)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(LadlePressButtonStyle(kind: .card))
        .accessibilityLabel("Open \(recipe.title)")
    }

    @ViewBuilder
    private var recipeImage: some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .clipped()
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
            .fill(LadleTheme.field)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(systemName: "frying.pan")
                    .foregroundStyle(LadleTheme.paprika)
            }
            .accessibilityHidden(true)
        }
    }
}
