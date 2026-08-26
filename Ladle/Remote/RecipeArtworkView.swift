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

struct RecipeArtworkView: View {
    @Environment(\.remoteImageCache) private var imageCache

    let recipeID: UUID
    let image: RecipeImage?

    @State private var downloadedImage: UIImage?

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
                        Image(systemName: "frying.pan")
                            .foregroundStyle(LadleTheme.paprika)
                    }
            }
        }
        .task(id: image?.id) {
            guard
                let image,
                let remoteURL = image.remoteURL,
                let imageCache
            else {
                return
            }
            do {
                let localURL = try await imageCache.localURL(
                    recipeID: recipeID,
                    image: RemoteRecipeImageDTO(
                        id: image.id,
                        remoteURL: remoteURL
                    )
                )
                downloadedImage = UIImage(
                    contentsOfFile: localURL.path
                )
            } catch {
                downloadedImage = nil
            }
        }
    }
}
