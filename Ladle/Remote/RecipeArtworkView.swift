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

/// Decoded artwork held in memory, keyed by image id.
///
/// Without it every reappearance re-read the file and re-decoded it: a row
/// recycled by a LazyVStack, or a tab the reader came back to, blanked to a
/// placeholder and then faded the same picture back in. NSCache is
/// thread-safe on its own and evicts under memory pressure, so this needs no
/// isolation and no eviction policy of its own.
enum RecipeArtworkMemoryCache {
    nonisolated(unsafe) private static let images: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    static func image(for id: UUID) -> UIImage? {
        images.object(forKey: id as NSUUID)
    }

    static func store(_ image: UIImage, for id: UUID) {
        images.setObject(image, forKey: id as NSUUID)
    }
}

struct RecipeArtworkView: View {
    @Environment(\.remoteImageCache) private var imageCache

    let owner: RemoteImageOwner
    let image: RecipeImage?

    @State private var downloadedImage: UIImage?
    @State private var loadState = RecipeArtworkLoadState.placeholder

    init(owner: RemoteImageOwner, image: RecipeImage?) {
        self.owner = owner
        self.image = image
        // Seeded here rather than in the task: a value set in .task lands
        // after the first render, which is one frame of placeholder.
        let cached = image.flatMap { RecipeArtworkMemoryCache.image(for: $0.id) }
        _downloadedImage = State(initialValue: cached)
        _loadState = State(initialValue: cached == nil ? .placeholder : .loaded)
    }

    /// Artwork owned by a recipe saved in the caller's own library.
    init(recipeID: UUID, image: RecipeImage?) {
        self.init(owner: .recipe(id: recipeID), image: image)
    }

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
            guard
                let image,
                let remoteURL = image.remoteURL,
                let imageCache
            else {
                downloadedImage = nil
                loadState = .placeholder
                return
            }
            if let cached = RecipeArtworkMemoryCache.image(for: image.id) {
                downloadedImage = cached
                loadState = .loaded
                return
            }
            // Whatever is on screen stays until the replacement is ready.
            // Clearing first is what made a revisit flash to a placeholder.
            loadState = .loading
            do {
                let localURL = try await imageCache.localURL(
                    owner: owner,
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
                RecipeArtworkMemoryCache.store(loaded, for: image.id)
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
                .tint(LadleTheme.Intent.accent)
                .accessibilityLabel(loadState.accessibilityLabel)
        } else {
            Image(systemName: loadState.systemImage)
                .foregroundStyle(LadleTheme.Label.accent)
                .accessibilityLabel(loadState.accessibilityLabel)
        }
    }
}
