import SwiftUI

enum RecipeOption: Identifiable {
    case edit
    case reimport
    case nutrition
    case source
    case delete

    var id: Self { self }

    var title: String {
        switch self {
        case .edit: "Edit recipe"
        case .reimport: "Re-import from source"
        case .nutrition: "View nutrition"
        case .source: "Watch original video"
        case .delete: "Delete recipe"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "square.and.pencil"
        case .reimport: "arrow.triangle.2.circlepath"
        case .nutrition: "chart.bar"
        case .source: "play.rectangle"
        case .delete: "trash"
        }
    }
}

struct RecipeOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let options: [RecipeOption]
    let select: (RecipeOption) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button {
                            select(option)
                            dismiss()
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: option.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(
                                        option == .delete
                                            ? Color.red
                                            : LadleTheme.Label.accent
                                    )
                                    .frame(width: 36, height: 36)
                                    .background(
                                        LadleTheme.Surface.steel,
                                        in: Circle()
                                    )
                                Text(option.title)
                                    .ladleFont(.bodyStrong)
                                    .foregroundStyle(LadleTheme.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(LadleTheme.mutedInk)
                            }
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            Divider().overlay(LadleTheme.ink.opacity(0.08))
                        }
                    }
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .navigationTitle("Recipe options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
    }
}
