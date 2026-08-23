import SwiftUI

struct OnboardingWalkthroughView: View {
    private enum Step: Int, CaseIterable {
        case share
        case review
        case cook

        var title: String {
            switch self {
            case .share:
                "Share from any recipe video"
            case .review:
                "Check what Overeasy rescued"
            case .cook:
                "Cook one clear step at a time"
            }
        }

        var message: String {
            switch self {
            case .share:
                "From TikTok, Instagram, or YouTube, tap Share and choose Add to Overeasy."
            case .review:
                "Ingredients and steps arrive ready to review. Overeasy marks anything worth a closer look."
            case .cook:
                "Start Cooking keeps one instruction in focus, with timers close at hand."
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var step = Step.share

    let onComplete: () -> Void

    var body: some View {
        ZStack {
            LadleTheme.paper
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: LadleTheme.Spacing.generous) {
                        illustration
                            .frame(
                                minHeight: dynamicTypeSize.isAccessibilitySize
                                    ? 330
                                    : 290
                            )

                        VStack(spacing: LadleTheme.Spacing.medium) {
                            Text(step.title)
                                .ladleFont(.title)
                                .foregroundStyle(LadleTheme.ink)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(step.message)
                                .ladleFont(.body)
                                .foregroundStyle(LadleTheme.mutedInk)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 360)
                    }
                    .id(step)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.top, LadleTheme.Spacing.medium)
                    .padding(.bottom, LadleTheme.Spacing.generous)
                    .transition(.opacity)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
    }

    private var header: some View {
        HStack {
            Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
                .accessibilityLabel(
                    "Step \(step.rawValue + 1) of \(Step.allCases.count)"
                )

            Spacer()

            Button(action: onComplete) {
                Text("Skip")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, LadleTheme.Spacing.compact)
    }

    @ViewBuilder
    private var illustration: some View {
        switch step {
        case .share:
            shareIllustration
        case .review:
            reviewIllustration
        case .cook:
            cookIllustration
        }
    }

    private var shareIllustration: some View {
        ZStack {
            Circle()
                .fill(LadleTheme.celery.opacity(0.58))
                .frame(width: 230, height: 230)

            VStack(spacing: LadleTheme.Spacing.medium) {
                HStack(spacing: LadleTheme.Spacing.medium) {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                        .fill(LadleTheme.plum)

                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(LadleTheme.onAccent)
                    }
                    .frame(width: 52, height: 64)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lemon orzo tonight")
                            .ladleFont(.bodyStrong)
                            .foregroundStyle(LadleTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Instagram · @miacooks")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.mutedInk)
                    }

                    Spacer(minLength: LadleTheme.Spacing.compact)

                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(LadleTheme.paprika)
                        .frame(width: 44, height: 44)
                }
                .padding(LadleTheme.Spacing.regular)
                .background(
                    LadleTheme.paper,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )

                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(LadleTheme.paprika)
                    .accessibilityHidden(true)

                HStack(spacing: LadleTheme.Spacing.medium) {
                    Image("OvereasyMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )

                    Text("Add to Overeasy")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                .padding(LadleTheme.Spacing.regular)
                .background(
                    LadleTheme.paper,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )
            }
            .frame(maxWidth: 340)
            .shadow(color: LadleTheme.ink.opacity(0.08), radius: 18, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Share a recipe video, then choose Add to Overeasy"
        )
    }

    private var reviewIllustration: some View {
        VStack(spacing: 0) {
            Image("RecipeOrzo")
                .resizable()
                .scaledToFill()
                .frame(height: 128)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    LadlePill(
                        text: "Review",
                        systemImage: "sparkles",
                        tint: LadleTheme.ube
                    )
                    .padding(LadleTheme.Spacing.medium)
                }

            VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
                Text("One-Pot Lemon Orzo with Feta")
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("35 min · 8 ingredients")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)

                Divider()
                    .overlay(LadleTheme.ink.opacity(0.1))

                reviewRow(
                    icon: "checkmark.circle.fill",
                    text: "Lemon, feta, orzo, and spinach",
                    tint: LadleTheme.celery
                )
                reviewRow(
                    icon: "questionmark.circle.fill",
                    text: "Check the amount of vegetable stock",
                    tint: LadleTheme.ube
                )
            }
            .padding(LadleTheme.Spacing.regular)
        }
        .frame(maxWidth: 340)
        .background(
            LadleTheme.oat,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
            .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func reviewRow(
        icon: String,
        text: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.compact) {
            Image(systemName: icon)
                .foregroundStyle(LadleTheme.plum)
                .frame(width: 22, height: 22)
                .background(tint, in: Circle())

            Text(text)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cookIllustration: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
            HStack {
                Text("STEP 3 OF 6")
                    .ladleFont(.eyebrow)
                    .foregroundStyle(LadleTheme.focusAccent)

                Spacer()

                Image(systemName: "flame.fill")
                    .foregroundStyle(LadleTheme.paprika)
            }

            Text("Simmer the orzo")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.onAccent)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Stir in the stock and orzo. Simmer gently until tender, stirring often."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.onAccent.opacity(0.84))
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("12:00", systemImage: "timer")
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.onAccent)

                Spacer()

                Text("Start timer")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 44)
                    .background(LadleTheme.celery, in: Capsule())
            }
        }
        .padding(LadleTheme.Spacing.generous)
        .frame(maxWidth: 340, minHeight: 270, alignment: .leading)
        .background(
            LadleTheme.plum,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(
                            index < 3
                                ? LadleTheme.focusAccent
                                : LadleTheme.onAccent.opacity(0.18)
                        )
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 4)
            .padding(LadleTheme.Spacing.regular)
            .accessibilityHidden(true)
        }
        .shadow(color: LadleTheme.ink.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            HStack(spacing: LadleTheme.Spacing.compact) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(
                            item == step
                                ? LadleTheme.brick
                                : LadleTheme.ink.opacity(0.14)
                        )
                        .frame(
                            width: item == step ? 24 : 8,
                            height: 8
                        )
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: step
            )
            .accessibilityHidden(true)

            Button(
                step == .cook ? "Start saving recipes" : "Next",
                action: advance
            )
            .buttonStyle(LadlePrimaryButtonStyle())
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, LadleTheme.Spacing.medium)
        .padding(.bottom, LadleTheme.Spacing.regular)
        .background(LadleTheme.paper)
    }

    private func advance() {
        guard step != .cook else {
            onComplete()
            return
        }

        let nextStep = Step(rawValue: step.rawValue + 1) ?? .cook
        if reduceMotion {
            step = nextStep
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                step = nextStep
            }
        }
    }
}
