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
    @Environment(\.ladleAccent) private var accent

    let owner: RemoteImageOwner
    let image: RecipeImage?

    @State private var downloadedImage: UIImage?
    @State private var loadState = RecipeArtworkLoadState.placeholder

    init(owner: RemoteImageOwner, image: RecipeImage?) {
        self.owner = owner
        self.image = image
    }

    /// Artwork owned by a recipe saved in the caller's own library.
    init(recipeID: UUID, image: RecipeImage?) {
        self.init(owner: .recipe(id: recipeID), image: image)
    }

    /// The cached image is adopted in `task`, deliberately not seeded into
    /// `@State` from `init`. Seeding it put a `scaledToFill` image into the
    /// very first layout pass, where the placeholder `Rectangle` used to be:
    /// the rectangle accepts whatever size it is offered, a filled image does
    /// not, and at call sites that constrain only one axis the artwork grew
    /// to its own aspect ratio and covered the surrounding rows. One frame of
    /// placeholder is the price of a grid that lays out correctly.
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
            guard let image, let remoteURL = image.remoteURL else {
                downloadedImage = nil
                loadState = .placeholder
                return
            }
            // Before the download cache is needed at all: a context-menu
            // preview of a row already on screen finds the decoded image
            // here, whatever its host managed to pass down.
            if let cached = RecipeArtworkMemoryCache.image(for: image.id) {
                downloadedImage = cached
                loadState = .loaded
                return
            }
            guard let imageCache else {
                downloadedImage = nil
                loadState = .placeholder
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
                .tint(accent.intent)
                .accessibilityLabel(loadState.accessibilityLabel)
        } else {
            Image(systemName: loadState.systemImage)
                .foregroundStyle(accent.label)
                .accessibilityLabel(loadState.accessibilityLabel)
        }
    }
}
