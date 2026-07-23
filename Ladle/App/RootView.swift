import LadleCore
import SwiftUI

struct RootView: View {
    let accountSession: AccountSession

    init(accountSession: AccountSession = AccountSession()) {
        self.accountSession = accountSession
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryBackdropView()
                .blur(
                    radius: accountSession.shouldPresentWelcome ? 2.5 : 0
                )
                .allowsHitTesting(!accountSession.shouldPresentWelcome)

            if accountSession.shouldPresentWelcome {
                LadleTheme.ink
                    .opacity(0.28)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                WelcomeView(accountSession: accountSession)
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
            }
        }
        .background(LadleTheme.paper)
        .animation(
            .snappy(duration: 0.34),
            value: accountSession.shouldPresentWelcome
        )
    }
}

private struct LibraryBackdropView: View {
    private let columns = [
        GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
        GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LadleTheme.Spacing.generous) {
                    libraryHeader
                    searchField
                    parsingCard
                    recipes
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.root")
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LADLE")
                    .font(LadleTypography.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(LadleTheme.paprika)
                Text("My Recipes")
                    .font(LadleTypography.title)
                    .foregroundStyle(LadleTheme.ink)
            }

            Spacer()

            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(LadleTheme.paprika, in: Circle())
            }
            .accessibilityLabel("Add Recipe")
        }
        .padding(.top, 18)
    }

    private var searchField: some View {
        Label("Search your recipes", systemImage: "magnifyingglass")
            .font(LadleTypography.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.46))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
    }

    private var parsingCard: some View {
        HStack(spacing: 14) {
            ProgressView()
                .tint(LadleTheme.paprika)
            VStack(alignment: .leading, spacing: 3) {
                Text("Parsing green curry")
                    .font(LadleTypography.bodyStrong)
                Text("From TikTok · Just added")
                    .font(LadleTypography.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.56))
            }
            Spacer()
            LadlePill(
                text: "Parsing",
                systemImage: "sparkles",
                tint: LadleTheme.review
            )
        }
        .foregroundStyle(LadleTheme.ink)
        .padding(14)
        .ladleCard()
    }

    private var recipes: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
            LadleSectionHeader(title: "Recently added", detail: "6 recipes")
            LazyVGrid(columns: columns, spacing: LadleTheme.Spacing.generous) {
                ForEach(PreviewFixtures.recipes.prefix(4)) { recipe in
                    RecipeBackdropCard(recipe: recipe)
                }
            }
        }
    }
}

private struct RecipeBackdropCard: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(recipe.images.first?.localName ?? "")
                .resizable()
                .scaledToFill()
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )
                .clipped()

            Text(recipe.title)
                .font(LadleTypography.recipeTitle)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(
                    "\(recipe.totalMinutes ?? 0) min",
                    systemImage: "clock"
                )
                if let calories = recipe.nutrition?.calories {
                    Text("·")
                    Text("\(calories.formatted()) cal")
                }
            }
            .font(LadleTypography.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.56))
        }
    }
}
