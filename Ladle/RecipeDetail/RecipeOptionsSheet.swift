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

    var buttonRole: LadleButtonRole {
        self == .delete ? .destructive : .tertiary
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
                            HStack(spacing: LadleTheme.Layout.iconGap) {
                                Image(systemName: option.systemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(
                                        option == .delete
                                            ? option.buttonRole.label
                                            : LadleTheme.Label.accent
                                    )
                                    .frame(width: 36, height: 36)
                                    .background(
                                        option == .delete
                                            ? option.buttonRole.label.opacity(0.16)
                                            : LadleTheme.Surface.steel,
                                        in: Circle()
                                    )
                                Text(option.title)
                                    .foregroundStyle(
                                        option == .delete
                                            ? option.buttonRole.label
                                            : LadleTheme.Label.primary
                                    )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(
                                        option == .delete
                                            ? option.buttonRole.label.opacity(0.72)
                                            : LadleTheme.Label.secondary
                                    )
                            }
                            .frame(minHeight: 64)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(
                            LadleButtonStyle(
                                role: option.buttonRole,
                                isFullWidth: true
                            )
                        )
                        .overlay(alignment: .bottom) {
                            if option != .delete {
                                Divider().overlay(LadleTheme.Stroke.separator)
                            }
                        }
                    }
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Recipe options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                        .padding(
                            .leading,
                            LadleTheme.Layout.sheetToolbarInset
                        )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.Surface.porcelain)
    }
}
