import SwiftUI

struct SyncConflictPresentation: Equatable {
    let title: String
    let localTitle: String
    let remoteTitle: String
    let detail: String
    let keepLocalTitle = "Keep My Version"
    let acceptRemoteTitle: String

    init(conflict: RecipeSyncConflict) {
        localTitle = conflict.localRecipe.title
        if let remote = conflict.remoteRecipe {
            title = "Changed on another device"
            remoteTitle = remote.title
            acceptRemoteTitle = "Use Other Version"
        } else {
            title = "Deleted on another device"
            remoteTitle = "No longer in your account"
            acceptRemoteTitle = "Remove Local Copy"
        }
        detail = "Your saved recipe stays safe on this device until you choose which change to keep."
    }
}

struct SyncConflictBanner: View {
    @Environment(\.ladleAccent) private var accent

    let count: Int
    let review: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LadleTheme.Layout.iconGap) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(
                    size: LadleTheme.IconSize.medium,
                    weight: .semibold
                ))
                .foregroundStyle(accent.label)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text("Recipe changes need review")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(
                    count == 1
                        ? "Your saved version is safe."
                        : "\(count) saved versions are safe."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
            }
            Spacer(minLength: LadleTheme.Spacing.compact)
            Button("Review", action: review)
                .ladleFont(.bodyStrong)
                .foregroundStyle(accent.label)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, LadleTheme.Layout.screenMargin)
        .padding(.vertical, LadleTheme.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.steel)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.Stroke.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.conflict-banner")
    }
}

struct SyncConflictReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let conflicts: [RecipeSyncConflict]
    let resolve: (UUID, RecipeSyncConflictResolution) -> Bool

    @State private var resolvingRecipeID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: LadleTheme.Spacing.regular) {
                    ForEach(conflicts) { conflict in
                        conflictCard(conflict)
                    }
                }
                .padding(.horizontal, LadleTheme.Layout.sheetMargin)
                .padding(.vertical, LadleTheme.Spacing.regular)
            }
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Review Recipe Changes")
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.Surface.porcelain)
        .onChange(of: conflicts.isEmpty) { _, isEmpty in
            if isEmpty {
                dismiss()
            }
        }
        .accessibilityIdentifier("sync.conflict-review")
    }

    private func conflictCard(_ conflict: RecipeSyncConflict) -> some View {
        let presentation = SyncConflictPresentation(conflict: conflict)
        let isResolving = resolvingRecipeID == conflict.id
        return VStack(
            alignment: .leading,
            spacing: LadleTheme.Spacing.medium
        ) {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text(presentation.title)
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(presentation.detail)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            version(
                label: "On this device",
                title: presentation.localTitle
            )
            version(
                label: "Other device",
                title: presentation.remoteTitle
            )
            VStack(spacing: LadleTheme.Spacing.compact) {
                Button(presentation.keepLocalTitle) {
                    resolve(conflict, as: .keepLocal)
                }
                .buttonStyle(LadleButtonStyle(role: .primary))

                Button(presentation.acceptRemoteTitle) {
                    resolve(conflict, as: .acceptRemote)
                }
                .buttonStyle(
                    LadleButtonStyle(
                        role: conflict.remoteRecipe == nil
                            ? .destructive
                            : .secondary
                    )
                )
            }
            .disabled(resolvingRecipeID != nil)
            .opacity(isResolving ? 0.65 : 1)
        }
        .padding(LadleTheme.Layout.cardPadding)
        .background(LadleTheme.Surface.raised, in: cardShape)
        .overlay {
            cardShape.stroke(LadleTheme.Stroke.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync.conflict.\(conflict.id.uuidString)")
    }

    private func version(label: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
            Text(label.uppercased())
                .ladleFont(.eyebrow)
                .foregroundStyle(LadleTheme.Label.secondary)
            Text(title)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LadleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.steel, in: cardShape)
    }

    private func resolve(
        _ conflict: RecipeSyncConflict,
        as resolution: RecipeSyncConflictResolution
    ) {
        resolvingRecipeID = conflict.id
        _ = resolve(conflict.id, resolution)
        resolvingRecipeID = nil
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LadleTheme.Corner.card,
            style: .continuous
        )
    }
}
