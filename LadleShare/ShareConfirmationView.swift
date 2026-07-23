import SwiftUI

enum ShareConfirmationState: Equatable {
    case loading
    case success(sourceName: String)
    case failure(message: String)
}

struct ShareConfirmationView: View {
    let state: ShareConfirmationState
    let close: () -> Void

    var body: some View {
        ZStack {
            ShareTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 34)
                confirmation
                Spacer(minLength: 38)
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("share.confirmation")
    }

    private var header: some View {
        HStack {
            Label {
                Text("Ladle")
                    .font(
                        .system(
                            size: 19,
                            weight: .semibold,
                            design: .serif
                        )
                    )
            } icon: {
                Image(systemName: "flame.fill")
                    .foregroundStyle(ShareTheme.paprika)
            }
            .foregroundStyle(ShareTheme.ink)

            Spacer()

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShareTheme.ink.opacity(0.68))
                    .frame(width: 42, height: 42)
                    .background(ShareTheme.field, in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var confirmation: some View {
        VStack(spacing: 20) {
            statusIcon

            VStack(spacing: 10) {
                Text(eyebrow)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(ShareTheme.paprika)

                Text(title)
                    .font(
                        .system(
                            size: 36,
                            weight: .semibold,
                            design: .serif
                        )
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.system(size: 17))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .success(sourceName) = state {
                Label(sourceName, systemImage: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShareTheme.ink.opacity(0.72))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 40)
                    .background(
                        ShareTheme.field,
                        in: Capsule()
                    )
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(ShareTheme.paprika)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Saving shared recipe")
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 86, height: 86)
                .background(ShareTheme.paprika, in: Circle())
                .accessibilityLabel("Recipe link saved")
        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(ShareTheme.paprika)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Recipe link was not saved")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if case .success = state {
                Text("SAFE TO CLOSE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(ShareTheme.paprika)
            }

            Text(footerMessage)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(ShareTheme.ink.opacity(0.48))
        }
    }

    private var eyebrow: String {
        switch state {
        case .loading:
            "ADDING TO LADLE"
        case .success:
            "SAVED FOR LATER"
        case .failure:
            "COULDN’T SAVE"
        }
    }

    private var title: String {
        switch state {
        case .loading:
            "Catching that recipe…"
        case .success:
            "Recipe link saved"
        case .failure:
            "One more try?"
        }
    }

    private var message: String {
        switch state {
        case .loading:
            "Hold on for just a moment while the link is secured."
        case .success:
            "Head back to what you were watching. Ladle will finish the import in the app."
        case let .failure(message):
            message
        }
    }

    private var footerMessage: String {
        switch state {
        case .loading:
            "This should only take a moment."
        case .success:
            "No need to wait for the recipe to be parsed."
        case .failure:
            "Close this sheet and share the link again."
        }
    }
}

private enum ShareTheme {
    static let paper = Color(
        red: 0.985,
        green: 0.976,
        blue: 0.954
    )
    static let field = Color(
        red: 0.944,
        green: 0.929,
        blue: 0.900
    )
    static let review = Color(
        red: 0.970,
        green: 0.897,
        blue: 0.838
    )
    static let paprika = Color(
        red: 0.720,
        green: 0.243,
        blue: 0.105
    )
    static let ink = Color(
        red: 0.105,
        green: 0.094,
        blue: 0.083
    )
}
