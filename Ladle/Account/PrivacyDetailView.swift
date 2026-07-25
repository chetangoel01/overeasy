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
                    title: "What Overeasy doesn’t do",
                    items: Copy.notTrackedItems
                )
            }
            .padding(.horizontal, LadleTheme.Spacing.generous)
            .padding(.top, LadleTheme.Spacing.regular)
            .padding(.bottom, LadleTheme.Spacing.cooking)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.paper)
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
                    .foregroundStyle(LadleTheme.ink.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(items.enumerated()),
                    id: \.offset
                ) { index, item in
                    transparencyRow(item)

                    if index < items.count - 1 {
                        Divider()
                            .overlay(LadleTheme.ink.opacity(0.08))
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private func transparencyRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
            Circle()
                .fill(LadleTheme.paprika)
                .frame(width: 6, height: 6)
                .padding(.top, 8)
                .accessibilityHidden(true)

            Text(item)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.75))
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
            Sign in with Apple adds only the identifier Apple provides.
            """,
        ]

        static let notTrackedItems = [
            """
            No ads, no analytics SDKs, no selling or sharing data with third \
            parties.
            """,
            "No tracking across other apps or websites.",
            """
            Timers, notifications, and Health export run entirely on this \
            device — nutrition leaves the app only when you explicitly export \
            a serving to Apple Health.
            """,
        ]
    }
}
