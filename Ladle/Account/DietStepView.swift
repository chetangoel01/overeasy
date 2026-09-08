import LadleCore
import SwiftUI

/// The second question onboarding asks, straight after the name.
///
/// A diet is who the cook is rather than what they are browsing for, so it
/// is asked once, here, and changed afterwards in Profile beside the name.
/// The filter menu can put it down for an evening and that is all it can do
/// — which is only fair if the cook was asked properly in the first place.
///
/// It stands in `NameStepView`'s register on purpose: the same porcelain,
/// the same Skip in the header, the same primary button pinned at the
/// bottom, because these are two questions in one flow and should not look
/// like two apps.
///
/// "No, I eat everything" is selected on arrival and is a real answer — most
/// cooks will tap Continue without touching anything, and nobody is nagged
/// for skipping. More than one may be chosen, because gluten-free
/// vegetarians exist.
struct DietStepView: View {
    let filters: RecipeFilterStore
    let onComplete: () -> Void

    @Environment(\.ladleAccent) private var accent
    @State private var selection: Set<DietTag>

    init(filters: RecipeFilterStore, onComplete: @escaping () -> Void) {
        self.filters = filters
        self.onComplete = onComplete
        // Prefilled from what is stored, so a cook who quit part-way through
        // and came back is looking at their own answer rather than at a
        // blank question they have already answered once.
        _selection = State(initialValue: filters.diets)
    }

    var body: some View {
        ZStack {
            LadleTheme.Surface.porcelain
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // Centred in what is left between the header and the button,
                // and scrollable when the type is large enough to need it —
                // the shape the name step and Welcome both use.
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: LadleTheme.Spacing.generous) {
                            message
                            options
                        }
                        .frame(maxWidth: 360)
                        .padding(.horizontal, LadleTheme.Spacing.generous)
                        .padding(.vertical, LadleTheme.Spacing.generous)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                    }
                    .scrollIndicators(.hidden)
                }

                footer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diet-step.root")
    }

    private var header: some View {
        HStack {
            Spacer()

            Button(action: onComplete) {
                Text("Skip")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .frame(
                        minWidth: 44,
                        minHeight: LadleTheme.Control.hitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diet-step.skip")
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, LadleTheme.Spacing.compact)
    }

    private var message: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            Text("Do you follow a diet?")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Overeasy keeps it in mind everywhere — your library, Discover and Watch. You can change it any time in your profile."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One card of rows, the way the Collections card and the grouped forms
    /// elsewhere are built: a row is the full width, its state is a
    /// checkmark, and nothing here is a toggle switch — these are choices
    /// rather than settings.
    private var options: some View {
        VStack(spacing: 0) {
            ForEach(DietTag.allCases, id: \.self) { diet in
                optionRow(
                    title: diet.title,
                    isSelected: selection.contains(diet),
                    identifier: "diet-step.option.\(diet.rawValue)"
                ) {
                    if selection.contains(diet) {
                        selection.remove(diet)
                    } else {
                        selection.insert(diet)
                    }
                }

                // A drawn line rather than `Divider()`: six rows of a
                // fractional height put the hairlines on subpixel
                // boundaries, and two of the five vanished on the device
                // while three survived, which read as a grouping nobody
                // meant.
                Rectangle()
                    .fill(LadleTheme.Label.primary.opacity(0.1))
                    .frame(height: 1)
            }

            optionRow(
                title: "No, I eat everything",
                isSelected: selection.isEmpty,
                identifier: "diet-step.option.none"
            ) {
                selection = []
            }
        }
        .background(
            LadleTheme.Surface.raised,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func optionRow(
        title: String,
        isSelected: Bool,
        identifier: String,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: LadleTheme.Spacing.medium) {
                Text(title)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: LadleTheme.Spacing.compact)

                Image(systemName: "checkmark")
                    .font(
                        .system(
                            size: LadleTheme.IconSize.medium,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(accent.label)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
            .frame(minHeight: LadleTheme.Control.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var footer: some View {
        // Never disabled, unlike the name step's: eating everything is an
        // answer, and the default one.
        Button("Continue", action: submit)
            .buttonStyle(LadleButtonStyle(role: .primary))
            .accessibilityIdentifier("diet-step.continue")
            .padding(.horizontal, LadleTheme.Spacing.generous)
            .padding(.top, LadleTheme.Spacing.medium)
            .padding(.bottom, LadleTheme.Spacing.regular)
            .background(LadleTheme.Surface.porcelain)
    }

    private func submit() {
        filters.diets = selection
        onComplete()
    }
}
