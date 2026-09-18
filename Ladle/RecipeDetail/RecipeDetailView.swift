import LadleCore
import SwiftUI

struct ReviewCompletionPresentation: Equatable {
    private(set) var isReviewed = false

    var title: String {
        isReviewed ? "Reviewed" : "Mark reviewed"
    }

    var systemImage: String? {
        isReviewed ? "checkmark" : nil
    }

    mutating func markReviewed() {
        isReviewed = true
    }

    static func navigationDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .zero : .milliseconds(160)
    }
}

/// What a page asks the engagement route about: whose source, and whether
/// the page is the cook's own copy yet.
private struct EngagementRequest: Equatable {
    let sourceID: UUID?
    let access: LibraryRecipeAccess
}

private enum RecipeDetailSection: String, CaseIterable, Identifiable {
    case ingredients = "Ingredients"
    case method = "Method"

    var id: Self { self }
}

struct RecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let statusText: String
    @Bindable var importCoordinator: ImportCoordinator
    let cookingSessions: CookingSessionStore
    let makeEditorViewModel: (Recipe) -> RecipeEditorViewModel
    let recipeDidChange: (Recipe) -> Void
    let reviewDidComplete: () -> Void
    let toggleFavorite: (UUID) -> Bool
    let completeReview: (UUID) -> Recipe?
    let deleteRecipe: (UUID) -> Bool
    let access: LibraryRecipeAccess
    /// The Discover feed's own save path, present only on a page opened as a
    /// preview. Saving through it turns this page into the saved copy.
    let discoverSave: DiscoverSaveModel?
    let openAccount: () -> Void

    @State private var displayedRecipe: Recipe
    @State private var isFavorite: Bool
    /// The count this cook is reading the recipe at. It lives here and
    /// nowhere else: no repository, no sync, no field on the recipe. Leaving
    /// the page destroys the state, which is the whole of the undo.
    @State private var scaling: RecipeScaling
    @State private var isNutritionPresented = false
    @State private var isReimportPresented = false
    @State private var isVideoPresented = false
    @State private var editorViewModel: RecipeEditorViewModel?
    @State private var section: RecipeDetailSection = .ingredients
    @State private var isDeleteConfirmationPresented = false
    @State private var reviewIsPending: Bool
    @State private var reviewPresentation =
        ReviewCompletionPresentation()
    @State private var engagement: RecipeEngagementModel

    /// The access the page has now, which is the access it was opened with
    /// until a save on it lands.
    private var currentAccess: LibraryRecipeAccess {
        discoverSave?.access ?? access
    }

    private var allowsLibraryEdits: Bool { currentAccess == .saved }

    /// Whether there is a player to open. A link whose shape no platform
    /// player accepts has none, and the page then offers no way to watch
    /// rather than a control that opens "Video unavailable".
    private var isVideoPlayable: Bool {
        VideoEmbed.url(for: displayedRecipe) != nil
    }

    /// Which server object can re-sign the header artwork's expired URL.
    /// It follows the page's access, never the id alone: a Discover
    /// preview's recipe id IS the Discover sourceID, which /v1/recipes/{id}
    /// answers with a 404. A save on the page moves both together — the
    /// access becomes `.saved` and the displayed recipe becomes the saved
    /// copy, whose id that endpoint does know.
    var artworkOwner: RemoteImageOwner {
        switch currentAccess {
        case .saved:
            .recipe(id: displayedRecipe.id)
        case .discover:
            .discoverSource(id: displayedRecipe.id)
        }
    }

    init(
        recipe: Recipe,
        statusText: String = "Saved recipe",
        importCoordinator: ImportCoordinator,
        cookingSessions: CookingSessionStore,
        makeEditorViewModel: @escaping (Recipe) -> RecipeEditorViewModel,
        recipeDidChange: @escaping (Recipe) -> Void,
        reviewDidComplete: @escaping () -> Void = {},
        toggleFavorite: @escaping (UUID) -> Bool,
        completeReview: @escaping (UUID) -> Recipe? = { _ in nil },
        deleteRecipe: @escaping (UUID) -> Bool = { _ in false },
        access: LibraryRecipeAccess = .saved,
        discoverSave: DiscoverSaveModel? = nil,
        engagementService: any SourceEngagementServing = DemoDiscoverService(),
        openAccount: @escaping () -> Void
    ) {
        self.statusText = statusText
        self.importCoordinator = importCoordinator
        self.cookingSessions = cookingSessions
        self.makeEditorViewModel = makeEditorViewModel
        self.recipeDidChange = recipeDidChange
        self.reviewDidComplete = reviewDidComplete
        self.toggleFavorite = toggleFavorite
        self.completeReview = completeReview
        self.deleteRecipe = deleteRecipe
        self.access = access
        self.discoverSave = discoverSave
        self.openAccount = openAccount
        _displayedRecipe = State(initialValue: recipe)
        _isFavorite = State(initialValue: recipe.isFavorite)
        _reviewIsPending = State(
            initialValue: recipe.reviewStatus == .needsReview
                || statusText == "Check details"
        )
        _scaling = State(
            initialValue: RecipeScaling(baseServings: recipe.servings)
        )
        // A preview already holds its row's numbers and asks for nothing.
        _engagement = State(
            initialValue: RecipeEngagementModel(
                service: engagementService,
                preview: discoverSave?.source
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                    recipeHeader
                    recipeFacts
                    if showsReviewNotice {
                        reviewNotice
                            .id("recipe-review")
                    }
                    sectionPicker
                    sectionContent

                    if !displayedRecipe.notes.isEmpty {
                        creatorNotes
                    }

                    // Only the cook who saved it may rate a source, and only
                    // once the server has answered for them.
                    if allowsLibraryEdits, engagement.canRate {
                        RecipeRatingCard(model: engagement)
                    }

                    cookingAction {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(
                                "recipe-review",
                                anchor: .center
                            )
                        }
                    }
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                // The hero used to meet the navigation bar edge to edge. A
                // thumbnail there reads as jammed under the back button.
                .padding(.top, LadleTheme.Spacing.medium)
                .padding(.bottom, LadleTheme.Layout.scrollTail)
            }
            .scrollIndicators(.hidden)
        }
        .background(LadleTheme.Surface.porcelain)
        .sensoryFeedback(.selection, trigger: isFavorite)
        .sensoryFeedback(.success, trigger: reviewIsPending) {
            wasPending,
            isPending in
            LadleFeedbackPolicy.didFinishReview(
                wasPending: wasPending,
                isPending: isPending
            )
        }
        .task(id: reviewPresentation.isReviewed) {
            guard reviewPresentation.isReviewed else {
                return
            }
            do {
                try await Task.sleep(
                    for: ReviewCompletionPresentation.navigationDelay(
                        reduceMotion: reduceMotion
                    )
                )
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            reviewDidComplete()
        }
        // Keyed on both, so a save on a preview asks as the saved copy it
        // has just become. A preview itself never asks.
        .task(
            id: EngagementRequest(
                sourceID: displayedRecipe.sourceID,
                access: currentAccess
            )
        ) {
            guard allowsLibraryEdits else { return }
            await engagement.load(sourceID: displayedRecipe.sourceID)
        }
        .accessibilityIdentifier("recipe.detail")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            // One slot, one story: Save until the recipe is the cook's, then
            // the heart in exactly that place, so the button reads as having
            // become the favourite rather than been swapped for it.
            ToolbarItemGroup(placement: .primaryAction) {
                if allowsLibraryEdits {
                    favoriteButton
                        .transition(.scale.combined(with: .opacity))
                    optionsMenu
                        .transition(.opacity)
                } else if let discoverSave {
                    saveButton(discoverSave)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openAccount) {
                    Image(systemName: "person.crop.circle")
                        .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
                }
                .foregroundStyle(LadleTheme.Label.primary)
                .buttonStyle(LadlePressButtonStyle())
                .accessibilityLabel("Account")
            }
        }
        .sheet(isPresented: $isNutritionPresented) {
            if let nutrition = displayedRecipe.nutrition {
                NutritionView(
                    nutrition: nutrition,
                    recipeTitle: displayedRecipe.title,
                    uncountedNote: NutritionNote.uncounted(in: displayedRecipe)
                )
            }
        }
        .sheet(item: $editorViewModel) { editorViewModel in
            RecipeEditorView(viewModel: editorViewModel) { recipe in
                applyChangedRecipe(recipe)
            }
        }
        .sheet(
            isPresented: $isReimportPresented,
            onDismiss: {
                // A swipe-down runs none of the sheet's own cleanup, so
                // every dismissal funnels through the coordinator: a
                // finished reimport left published here would wedge the
                // Add Recipe sheet behind "Re-import in progress".
                importCoordinator.releaseReimport(
                    for: displayedRecipe.id
                )
            }
        ) {
            ReimportSheet(
                currentRecipe: displayedRecipe,
                coordinator: importCoordinator
            ) { recipe in
                applyChangedRecipe(recipe)
            }
        }
        .sheet(isPresented: $isVideoPresented) {
            VideoEmbedSheet(recipe: displayedRecipe)
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Recipe", role: .destructive) {
                if deleteRecipe(displayedRecipe.id) {
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will be removed from your synced Overeasy library.")
        }
    }

    /// The cook chose this recipe from its photo a moment ago, so the photo
    /// is a thumbnail beside the title rather than a hero above it: the
    /// time, the servings and the nutrition open on the first screen.
    private static let thumbnailSide: CGFloat = 96

    private var recipeHeader: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
            // One layout, two arrangements, so the artwork keeps its identity
            // — and its loaded image — when the text size changes. Beside a
            // 96-point square an accessibility-size title gets four letters
            // to a line, so there the photo sits above it instead.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(
                    VStackLayout(
                        alignment: .leading,
                        spacing: LadleTheme.Spacing.medium
                    )
                )
                : AnyLayout(
                    HStackLayout(
                        alignment: .top,
                        spacing: LadleTheme.Spacing.regular
                    )
                )
            layout {
                recipeThumbnail
                // No stack spacing: the link's target already carries the
                // air between its label and the byline above it.
                VStack(alignment: .leading, spacing: 0) {
                    recipeTitle
                    recipeByline
                        .padding(.top, LadleTheme.Spacing.tight)
                    overeasyLine
                    if isVideoPlayable {
                        watchOriginalLink
                    }
                }
            }

            if !displayedRecipe.description.isEmpty {
                Text(displayedRecipe.description)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = discoverSave?.failure {
                saveFailureNotice(report)
            }
        }
    }

    private static let playBadgeSide: CGFloat = 28

    /// The band, the nutrition card, and under whichever comes last the one
    /// note that explains their estimates. Grouped so the note sits against
    /// the card it qualifies rather than a section gap below it.
    private var recipeFacts: some View {
        let notes = displayedRecipe.ladleEstimateNotes
        return VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
            VStack(spacing: LadleTheme.Layout.sectionGap) {
                RecipeMetadataBand(
                    recipe: displayedRecipe,
                    scaling: $scaling
                )
                if let nutrition = displayedRecipe.nutrition {
                    RecipeNutritionSummary(nutrition: nutrition) {
                        isNutritionPresented = true
                    }
                }
            }
            if !notes.isEmpty {
                RecipeEstimatesDisclosure(notes: notes)
            }
        }
    }

    /// A fixed square whatever it holds. `RecipeArtworkView` fills the frame
    /// it is given with a placeholder until the image arrives, so late or
    /// missing artwork never moves the title.
    ///
    /// On a playable recipe it is also a way in to the video, and says so
    /// with a badge; on any other it is only the photo.
    @ViewBuilder
    private var recipeThumbnail: some View {
        let artwork = RecipeArtworkView(
            owner: artworkOwner,
            image: displayedRecipe.images.first
        )
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.thumbnail,
                style: .continuous
            )
        )
        // One element with one name: the artwork's own label describes its
        // load state, which is not what this square is for here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isVideoPlayable ? "Watch original video" : "Recipe photo"
        )

        if isVideoPlayable {
            Button {
                isVideoPresented = true
            } label: {
                artwork.overlay(alignment: .bottomTrailing) { playBadge }
            }
            .buttonStyle(LadlePressButtonStyle(kind: .card))
        } else {
            artwork.accessibilityAddTraits(.isImage)
        }
    }

    /// Material, like the favourite on a grid card, so the glyph keeps its
    /// contrast over whatever the photo puts behind it.
    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: LadleTheme.IconSize.small, weight: .bold))
            .foregroundStyle(LadleTheme.Label.primary)
            .frame(width: Self.playBadgeSide, height: Self.playBadgeSide)
            .background(.ultraThinMaterial, in: Circle())
            .padding(LadleTheme.Spacing.compact)
            .accessibilityHidden(true)
    }

    /// The words, because a badge on a photo is not a label. Tertiary with
    /// no inset, so the glyph lands on the title's leading edge, and held to
    /// its label so the blank row beside it is not a button — except at
    /// accessibility sizes, where the label needs that row to wrap into.
    private var watchOriginalLink: some View {
        let wraps = dynamicTypeSize.isAccessibilitySize
        return Button {
            isVideoPresented = true
        } label: {
            Label {
                Text("Watch original")
            } icon: {
                Image(systemName: "play.fill")
                    .imageScale(.small)
            }
            .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(LadleButtonStyle(role: .tertiary, isFullWidth: true))
        .fixedSize(horizontal: !wraps, vertical: false)
        .accessibilityIdentifier("recipe.watch-original")
    }

    private var recipeTitle: some View {
        Text(displayedRecipe.title)
            .ladleFont(.compactTitle)
            .foregroundStyle(LadleTheme.Label.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engagementText: EngagementText? {
        engagement.engagement.map(EngagementText.init)
    }

    /// One run of text rather than a row of three, so it wraps between
    /// words instead of squeezing the creator's handle into a column. At
    /// accessibility sizes each part takes its own line: wrapped, the
    /// second line would otherwise open on the separator.
    ///
    /// The platform's likes ride here because they are the platform's, not
    /// Overeasy's: "@thecopperpan · TikTok · 24K likes".
    private var recipeByline: some View {
        let parts = [
            displayedRecipe.creatorName,
            displayedRecipe.source.libraryTitle,
            engagementText?.likes,
        ].compactMap(\.self)
        let separator = dynamicTypeSize.isAccessibilitySize ? "\n" : " · "
        return Text(parts.joined(separator: separator))
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(parts.joined(separator: ", "))
    }

    /// Overeasy's own numbers, on their own line under the platform's. A
    /// saved recipe that names its source holds the line's place from the
    /// first frame until the server answers, so the numbers arriving do not
    /// move the page; an answer that never comes gives the place back and
    /// leaves the header as it was before ratings.
    @ViewBuilder
    private var overeasyLine: some View {
        let holdsPlace = allowsLibraryEdits
            && displayedRecipe.sourceID != nil
            && !engagement.isSettled
        Group {
            if let text = engagementText, text.hasLine {
                EngagementLine(text: text)
                    .accessibilityIdentifier("recipe.engagement")
            } else if holdsPlace {
                Text(" ").accessibilityHidden(true)
            }
        }
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.secondary)
        .padding(.top, LadleTheme.Spacing.tight)
    }

    /// Save, in the top-right toolbar group beside the account button — the
    /// spot the heart and the menu take over once the recipe is the cook's.
    /// Same two words as the Discover card, drawn like its toolbar neighbours.
    private func saveButton(_ model: DiscoverSaveModel) -> some View {
        Button {
            save(through: model)
        } label: {
            Label(
                model.isSaved ? "Saved" : "Save",
                systemImage: model.isSaved ? "checkmark" : "plus"
            )
            // Native toolbar sizing is retained, including while saving.
            .labelStyle(.titleAndIcon)
            .opacity(model.isSaving ? 0 : 1)
            .overlay {
                if model.isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent.intent)
                        .accessibilityHidden(true)
                }
            }
            .ladleFont(.metadata)
            .foregroundStyle(model.isSaved ? LadleTheme.Label.primary : accent.label)
            .padding(.horizontal, LadleTheme.Spacing.compact)
            .frame(minHeight: LadleTheme.Control.hitTarget)
        }
        .buttonStyle(LadlePressButtonStyle())
        .disabled(model.isSaving || model.isSaved)
        .accessibilityLabel(
            model.isSaved
                ? "\(displayedRecipe.title) saved"
                : "Save \(displayedRecipe.title)"
        )
        .accessibilityIdentifier("recipe.save")
    }

    private func saveFailureNotice(
        _ report: RemoteFailureReport
    ) -> some View {
        Label(
            "Save: \(report.failure.title). \(report.failure.message)",
            systemImage: report.failure.systemImage
        )
        .ladleFont(.metadata)
        .foregroundStyle(accent.label)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("recipe.save-failure")
    }

    /// The page becomes the recipe it just saved: the preview and the saved
    /// copy are different rows on the server, and every edit affordance the
    /// flip reveals works off the id.
    private func save(through model: DiscoverSaveModel) {
        Task {
            guard let saved = await model.save() else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                displayedRecipe = saved.recipe
                isFavorite = saved.recipe.isFavorite
            }
        }
    }

    private var sectionPicker: some View {
        Picker("Recipe section", selection: $section) {
            ForEach(RecipeDetailSection.allCases) {
                Text($0.rawValue).tag($0)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .ingredients:
            IngredientList(
                ingredients: displayedRecipe.orderedIngredients,
                showsIcons: true,
                scaledBy: scaling.multiplier
            )
        case .method:
            MethodList(steps: displayedRecipe.orderedSteps)
        }
    }

    private var creatorNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Notes from the source")

            VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
                ForEach(
                    Array(displayedRecipe.notes.enumerated()),
                    id: \.offset
                ) { _, note in
                    HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
                        Circle()
                            .fill(LadleTheme.Label.secondary)
                            .frame(width: 5, height: 5)
                            .padding(.top, LadleTheme.Spacing.compact)
                            .accessibilityHidden(true)
                        Text(note)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("recipe.notes")
    }

    private var reviewNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "Check uncertain details",
                systemImage: "pencil.and.list.clipboard"
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.Label.primary)

            Text(
                "Some details are missing or inferred. Check them before cooking."
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.secondary)
            .fixedSize(horizontal: false, vertical: true)

            reviewAction
        }
        .padding(16)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var reviewAction: some View {
        if let systemImage = reviewPresentation.systemImage {
            Label(
                reviewPresentation.title,
                systemImage: systemImage
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.Label.primary)
            .frame(maxWidth: .infinity, minHeight: LadleTheme.Control.primary)
            .background(
                LadleTheme.Intent.success.opacity(0.62),
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .accessibilityIdentifier("recipe.reviewed")
        } else {
            Button(
                reviewPresentation.title,
                action: markReviewed
            )
            .buttonStyle(
                LadleButtonStyle(role: .secondary)
            )
            .accessibilityIdentifier("recipe.complete-review")
        }
    }

    private func markReviewed() {
        guard let reviewed = completeReview(
            displayedRecipe.id
        ) else {
            return
        }
        reviewPresentation.markReviewed()
        reviewIsPending = false
        applyChangedRecipe(reviewed)
    }

    private var favoriteButton: some View {
        Button {
            if toggleFavorite(displayedRecipe.id) {
                isFavorite.toggle()
            }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(
                    isFavorite ? accent.label : LadleTheme.Label.primary
                )
                .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(
            isFavorite
                ? "Remove \(displayedRecipe.title) from favorites"
                : "Add \(displayedRecipe.title) to favorites"
        )
    }

    private func applyChangedRecipe(_ recipe: Recipe) {
        displayedRecipe = recipe
        isFavorite = recipe.isFavorite
        // An edit or a reimport can change the yield the recipe claims, and a
        // ratio against the old one would be meaningless. The scaling starts
        // again from what the recipe now says.
        scaling = RecipeScaling(baseServings: recipe.servings)
        recipeDidChange(recipe)
    }

    private var needsReview: Bool {
        reviewIsPending
    }

    private var showsReviewNotice: Bool {
        needsReview || reviewPresentation.isReviewed
    }

    @ViewBuilder
    private func cookingAction(
        showReview: @escaping () -> Void
    ) -> some View {
        switch cookingReadiness {
        case .ready:
            // The session belongs to the app, not to this page, so a recipe
            // already cooking is resumed rather than started again — and
            // starting a different one while its timers run asks first.
            Button(isCooking ? "Resume cooking" : "Start Cooking") {
                cookingSessions.start(
                    recipe: displayedRecipe,
                    scaling: scaling
                )
            }
            .buttonStyle(LadleButtonStyle(role: .primary))
        case .needsReview:
            Button("Review before cooking", action: showReview)
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
        case .missingIngredients:
            if allowsLibraryEdits {
                Button("Add ingredients before cooking") {
                    editorViewModel = makeEditorViewModel(displayedRecipe)
                }
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
            } else {
                previewUnavailable("Ingredients aren’t available in this preview.")
            }
        case .missingMethod:
            if allowsLibraryEdits {
                Button("Add a method before cooking") {
                    editorViewModel = makeEditorViewModel(displayedRecipe)
                }
                .buttonStyle(
                    LadleButtonStyle(role: .secondary)
                )
            } else {
                previewUnavailable("The method isn’t available in this preview.")
            }
        }
    }

    private func previewUnavailable(_ message: String) -> some View {
        Text(message)
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.Label.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cookingReadiness: RecipeCookingReadiness {
        needsReview ? .needsReview : displayedRecipe.cookingReadiness
    }

    private var isCooking: Bool {
        cookingSessions.isCooking(displayedRecipe.id)
    }

    private var optionsMenu: some View {
        Menu {
            ForEach(recipeOptions.filter { !$0.isDestructive }) { option in
                Button {
                    perform(option)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }

            if let destructive = recipeOptions.first(where: \.isDestructive) {
                Section {
                    Button(role: .destructive) {
                        perform(destructive)
                    } label: {
                        Label(
                            destructive.title,
                            systemImage: destructive.systemImage
                        )
                    }
                    // The menu-wide label tint would otherwise leave the
                    // glyph dark while only the title turned red.
                    .tint(LadleTheme.Intent.destructive)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(
                    width: LadleTheme.Control.hitTarget,
                    height: LadleTheme.Control.hitTarget
                )
        }
        // The app-wide accent tint would paint every menu glyph red, which
        // competes with the genuinely destructive item. Menu glyphs follow
        // the label colour, and the destructive role keeps its own red.
        .tint(LadleTheme.Label.primary)
        .foregroundStyle(LadleTheme.Label.primary)
        .accessibilityLabel("Recipe options")
    }

    private var recipeOptions: [RecipeOption] {
        var options: [RecipeOption] = [.edit, .reimport]
        if displayedRecipe.nutrition != nil {
            options.append(.nutrition)
        }
        if isVideoPlayable {
            options.append(.source)
        }
        options.append(.delete)
        return options
    }

    /// A menu dismisses itself before its action runs, so each option can
    /// present its own sheet directly - no deferred-until-dismiss dance.
    private func perform(_ option: RecipeOption) {
        switch option {
        case .edit:
            editorViewModel = makeEditorViewModel(displayedRecipe)
        case .reimport:
            isReimportPresented = true
        case .nutrition:
            isNutritionPresented = true
        case .source:
            isVideoPresented = true
        case .delete:
            isDeleteConfirmationPresented = true
        }
    }
}
