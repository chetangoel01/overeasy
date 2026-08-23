import SwiftUI

enum LibrarySection: Hashable {
    case home
    case discover
    case all
}

struct LibraryTopBar: View {
    let openSearch: (() -> Void)?
    var openAccount: (() -> Void)?
    let addRecipe: () -> Void
    var isAddEnabled = true

    var body: some View {
        HStack {
            Text("Overeasy")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
            Spacer()
            if let openAccount {
                iconButton(
                    "person",
                    label: "Account",
                    action: openAccount
                )
            }
            if let openSearch {
                iconButton("magnifyingglass", label: "Search", action: openSearch)
            }
            iconButton(
                "plus",
                label: "Add Recipe",
                tint: LadleTheme.brick,
                foreground: LadleTheme.onAccent,
                isEnabled: isAddEnabled,
                action: addRecipe
            )
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.top, 10)
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        tint: Color = LadleTheme.field,
        foreground: Color = LadleTheme.ink,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background(tint, in: Circle())
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(label)
        .accessibilityHint(
            isEnabled ? "" : "Connecting to Overeasy"
        )
        .disabled(!isEnabled)
    }
}

struct LibrarySectionPicker: View {
    @Binding var selection: LibrarySection
    let recipeCount: Int

    var body: some View {
        Picker("Recipe destination", selection: $selection) {
            Text("Home").tag(LibrarySection.home)
            Text("Discover").tag(LibrarySection.discover)
            Text("All \(recipeCount)").tag(LibrarySection.all)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.vertical, 12)
    }
}

struct LibraryDestinationHeader: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(LadleTheme.field, in: Circle())
            }
            .foregroundStyle(LadleTheme.ink)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.ink)
                if let detail {
                    Text(detail)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
            }
            Spacer()
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.vertical, 10)
    }
}

struct LibraryLoadStateView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let message {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(LadleTheme.paprika)
                Text("Couldn’t load recipes")
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.ink)
                Text(message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            } else {
                ProgressView("Loading recipes")
                    .tint(LadleTheme.paprika)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
