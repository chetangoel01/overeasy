import LadleCore
import SwiftUI
import WebKit

enum VideoEmbed {
    /// Platform embed-player URL for a recipe's source video, falling back
    /// to the original page when no embed form is known.
    static func url(for recipe: Recipe) -> URL {
        embedURL(
            for: recipe.originalURL,
            source: recipe.source
        ) ?? recipe.originalURL
    }

    static func embedURL(for url: URL, source: RecipeSource) -> URL? {
        switch source {
        case .tiktok:
            guard let videoID = pathComponent(after: "video", in: url) else {
                return nil
            }
            return URL(string: "https://www.tiktok.com/embed/v2/\(videoID)")
        case .youtube:
            guard let videoID = youtubeVideoID(from: url) else {
                return nil
            }
            return URL(
                string:
                    "https://www.youtube.com/embed/\(videoID)?playsinline=1"
            )
        case .instagram:
            guard
                let shortcode = pathComponent(after: "reel", in: url)
                    ?? pathComponent(after: "p", in: url)
            else {
                return nil
            }
            return URL(
                string: "https://www.instagram.com/reel/\(shortcode)/embed"
            )
        case .other:
            return nil
        }
    }

    private static func pathComponent(
        after marker: String,
        in url: URL
    ) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: marker),
              components.indices.contains(index + 1) else {
            return nil
        }
        let value = components[index + 1]
        return value.isEmpty ? nil : value
    }

    private static func youtubeVideoID(from url: URL) -> String? {
        if url.host?.lowercased() == "youtu.be" {
            let identifier = url.pathComponents.dropFirst().first
            return identifier?.isEmpty == false ? identifier : nil
        }
        if let identifier = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first(where: { $0.name == "v" })?.value,
            !identifier.isEmpty {
            return identifier
        }
        return pathComponent(after: "shorts", in: url)
            ?? pathComponent(after: "embed", in: url)
    }
}

struct VideoEmbedSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @State private var page = WebPage()

    var body: some View {
        NavigationStack {
            WebView(page)
                .ignoresSafeArea(edges: .bottom)
                .background(LadleTheme.ink)
                .navigationTitle(recipe.source.libraryTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: dismiss.callAsFunction)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: recipe.originalURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share original video")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            page.load(URLRequest(url: VideoEmbed.url(for: recipe)))
        }
    }
}
