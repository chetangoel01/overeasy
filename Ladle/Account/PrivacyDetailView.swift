import SwiftUI

struct PrivacyDetailView: View {
    var body: some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: LadleTheme.Spacing.cooking
            ) {
                transparencySection(
                    title: "What Overeasy stores",
                    introduction:
                        "To make imports and sync work, Overeasy keeps:",
                    items: Copy.storedDataItems
                )
                transparencySection(
                    title: "How imports are processed",
                    introduction:
                        "Overeasy sends only the data needed for the feature:",
                    items: Copy.processingItems
                )
                transparencySection(
                    title: "Retention & deletion",
                    items: Copy.retentionItems
                )
                transparencySection(
                    title: "What Overeasy doesn’t do",
                    items: Copy.notTrackedItems
                )
            }
            .padding(.horizontal, LadleTheme.Spacing.generous)
            .padding(.top, LadleTheme.Spacing.regular)
            .padding(.bottom, LadleTheme.Spacing.cooking)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.Surface.porcelain)
        .navigationTitle("Privacy & data")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.privacy-detail")
    }

    private func transparencySection(
        title: String,
        introduction: String? = nil,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            LadleSectionHeader(title: title)

            if let introduction {
                Text(introduction)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(items.enumerated()),
                    id: \.offset
                ) { index, item in
                    transparencyRow(item)

                    if index < items.count - 1 {
                        Divider()
                            .overlay(LadleTheme.Label.primary.opacity(0.08))
                            .padding(
                                .leading,
                                LadleTheme.dividerInset(
                                    iconWidth: Self.bulletWidth
                                )
                            )
                    }
                }
            }
        }
    }

    /// Width of the bullet leading a transparency row. The divider between
    /// rows derives its inset from this; it used to be a literal 22 against
    /// a label origin of 18.
    private static let bulletWidth: CGFloat = 6

    private func transparencyRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
            Circle()
                .fill(LadleTheme.Label.secondary)
                .frame(width: Self.bulletWidth, height: Self.bulletWidth)
                .padding(.top, 8)
                .accessibilityHidden(true)

            Text(item)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, LadleTheme.Spacing.medium)
    }

    private enum Copy {
        static let storedDataItems = [
            """
            The links you import and the recipes extracted from them — \
            ingredients, steps, timers, and estimated nutrition — synced to \
            your account.
            """,
            """
            A copy of each video's thumbnail, so your library keeps its \
            artwork after the original expires.
            """,
            """
            Correction notes and pasted recipe text you add during recovery, \
            stored encrypted and used only to re-run your import.
            """,
            """
            An anonymous account identifier. Guests are keyed to this install; \
            Apple or Google sign-in adds the account identifier that provider \
            supplies.
            """,
            """
            The display name and profile picture link your provider supplies \
            at sign-in, so Settings can show you your own account. The name \
            is yours to edit, and both are deleted with your account.
            """,
        ]

        static let notTrackedItems = [
            """
            No ads, no cross-app tracking, and no sale of personal data.
            """,
            "No tracking across other apps or websites.",
            """
            Timers, notifications, and Health export run entirely on this \
            device — nutrition leaves the app only when you explicitly export \
            a serving to Apple Health.
            """,
        ]

        static let processingItems = [
            """
            Imported public links, captions, media evidence, correction notes, \
            or pasted text may be processed by our contracted transcription \
            and recipe-extraction providers.
            """,
            """
            Recipe images and encrypted service data are stored with our \
            hosting, database, and object-storage providers. Apple and Google \
            process sign-in only when you choose them.
            """,
            """
            Service logs use request, job, and pseudonymous account identifiers \
            for security and reliability; they do not contain recipe text or \
            authentication secrets.
            """,
        ]

        static let retentionItems = [
            """
            Recovery text is removed shortly after an import finishes. Import \
            diagnostics, expired sessions, cache records, and sync history each \
            follow a documented time limit.
            """,
            """
            Delete account permanently removes or anonymizes your recipes, \
            imports, sign-in identity, sessions, devices, and unreferenced \
            images. Sign in with Apple credentials are revoked first.
            """,
            """
            Account deletion cannot be undone. Service backups age out on their \
            published schedule and are not used to restore individual deleted \
            accounts.
            """,
        ]
    }
}
