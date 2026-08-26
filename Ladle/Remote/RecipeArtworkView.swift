import LadleCore
import SwiftUI
import UIKit

private struct RemoteImageCacheEnvironmentKey: EnvironmentKey {
    static let defaultValue: RemoteImageCache? = nil
}

extension EnvironmentValues {
    var remoteImageCache: RemoteImageCache? {
        get { self[RemoteImageCacheEnvironmentKey.self] }
        set { self[RemoteImageCacheEnvironmentKey.self] = newValue }
    }
}

enum RecipeArtworkLoadState: Equatable {
    case placeholder
    case loading
    case loaded
    case failed

    var systemImage: String {
        switch self {
        case .placeholder, .loaded:
            "frying.pan"
        case .loading:
            "photo"
        case .failed:
            "photo.badge.exclamationmark"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .placeholder:
            "Recipe image placeholder"
        case .loading:
            "Loading recipe image"
        case .loaded:
            "Recipe image"
        case .failed:
            "Recipe image unavailable"
        }
    }
}

struct RecipeArtworkView: View {
    @Environment(\.remoteImageCache) private var imageCache

    let recipeID: UUID
    let image: RecipeImage?

    @State private var downloadedImage: UIImage?
    @State private var loadState = RecipeArtworkLoadState.placeholder

    var body: some View {
        Group {
            if let localName = image?.localName {
                Image(localName)
                    .resizable()
                    .scaledToFill()
            } else if let downloadedImage {
                Image(uiImage: downloadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(LadleTheme.Surface.raised)
                    .overlay {
                        artworkPlaceholder
                    }
            }
        }
        .task(id: image?.id) {
            downloadedImage = nil
            guard
                let image,
                let remoteURL = image.remoteURL,
                let imageCache
            else {
                loadState = .placeholder
                return
            }
            loadState = .loading
            do {
                let localURL = try await imageCache.localURL(
                    recipeID: recipeID,
                    image: RemoteRecipeImageDTO(
                        id: image.id,
                        remoteURL: remoteURL
                    )
                )
                guard let loaded = UIImage(
                    contentsOfFile: localURL.path
                ) else {
                    loadState = .failed
                    return
                }
                downloadedImage = loaded
                loadState = .loaded
            } catch is CancellationError {
                return
            } catch {
                downloadedImage = nil
                loadState = .failed
            }
        }
    }

    @ViewBuilder
    private var artworkPlaceholder: some View {
        if loadState == .loading {
            ProgressView()
                .tint(LadleTheme.Label.accent)
                .accessibilityLabel(loadState.accessibilityLabel)
        } else {
            Image(systemName: loadState.systemImage)
                .foregroundStyle(LadleTheme.Label.accent)
                .accessibilityLabel(loadState.accessibilityLabel)
        }
    }
}
