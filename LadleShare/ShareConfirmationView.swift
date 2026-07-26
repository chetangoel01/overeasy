import SwiftUI

enum ShareConfirmationState: Equatable {
    case loading
    case success(sourceName: String)
    case failure(message: String)
}

struct ShareConfirmationView: View {
    static let brandName = "Overeasy"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let state: ShareConfirmationState
    let close: () -> Void

    var body: some View {
        ZStack {
            ShareTheme.paper.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    header
                    confirmation
                    footer
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("share.confirmation")
    }

    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    brand
                }
            } else {
                HStack {
                    brand
                    Spacer()
                    closeButton
                }
            }
        }
    }

    private var brand: some View {
        Label {
            Text(Self.brandName)
                .font(.headline.weight(.bold))
        } icon: {
            Image(systemName: "frying.pan.fill")
                .foregroundStyle(ShareTheme.brick)
        }
        .foregroundStyle(ShareTheme.ink)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(ShareTheme.ink.opacity(0.68))
                .frame(width: 44, height: 44)
                .background(ShareTheme.field, in: Circle())
        }
        .accessibilityLabel("Close")
        .accessibilityIdentifier("share.close")
    }

    private var confirmation: some View {
        VStack(spacing: 20) {
            statusIcon

            VStack(spacing: 10) {
                Text(title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .success(sourceName) = state {
                Label(sourceName, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShareTheme.ink.opacity(0.72))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
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
                .tint(ShareTheme.brick)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Saving shared recipe")
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 86, height: 86)
                .background(ShareTheme.brick, in: Circle())
                .accessibilityLabel("Recipe link saved")
        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(ShareTheme.brick)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Recipe link was not saved")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if case .success = state {
                Text("Safe to close")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ShareTheme.ink.opacity(0.58))
            }

            Text(footerMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(ShareTheme.ink.opacity(0.48))
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
            "Head back to what you were watching. Overeasy will finish the import in the app."
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
        red: 0.980,
        green: 0.965,
        blue: 0.937
    )
    static let field = Color(
        red: 0.949,
        green: 0.925,
        blue: 0.894
    )
    static let review = Color(
        red: 0.965,
        green: 0.925,
        blue: 0.851
    )
    static let brick = Color(
        red: 0.678,
        green: 0.314,
        blue: 0.239
    )
    static let ink = Color(
        red: 0.188,
        green: 0.153,
        blue: 0.176
    )
}
