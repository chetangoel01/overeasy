import LadleCore
import SwiftUI
import WebKit

enum VideoEmbed {
    static let unavailableTitle = "Video unavailable"
    static let unavailableMessage =
        "This saved link doesn’t contain a playable video ID."

    /// Platform player URL only. Unknown URL shapes deliberately return nil
    /// instead of loading the original social page inside or outside the app.
    static func url(for recipe: Recipe) -> URL? {
        embedURL(
            for: recipe.originalURL,
            source: recipe.source
        )
    }

    static func embedURL(for url: URL, source: RecipeSource) -> URL? {
        switch source {
        case .tiktok:
            guard let videoID = pathComponent(after: "video", in: url) else {
                return nil
            }
            return URL(
                string:
                    "https://www.tiktok.com/player/v1/\(videoID)?controls=1&progress_bar=0&volume_control=0&fullscreen_button=0&timestamp=0&closed_caption=0&rel=0&native_context_menu=0"
            )
        case .youtube:
            guard let videoID = youtubeVideoID(from: url) else {
                return nil
            }
            return URL(
                string:
                    "https://www.youtube.com/embed/\(videoID)?playsinline=1&rel=0"
            )
        case .instagram:
            let kind: String
            if pathComponent(after: "reel", in: url) != nil {
                kind = "reel"
            } else if pathComponent(after: "p", in: url) != nil {
                kind = "p"
            } else {
                return nil
            }
            guard let shortcode = pathComponent(after: kind, in: url) else {
                return nil
            }
            return URL(
                string: "https://www.instagram.com/\(kind)/\(shortcode)/embed/"
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

/// Keeps playback inside Overeasy. Provider links and unsupported main-frame
/// navigations are swallowed instead of escaping to another app or browser.
/// Host claimed by the synthetic document the YouTube embed is framed in.
/// The embed must be inside an iframe on some host page, and YouTube will
/// not play when that host page is youtube.com itself.
private enum EmbedPlayerHost {
    static let name = "player.ladle.localhost"
}

private struct EmbedNavigationDecider: WebPage.NavigationDeciding {
    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences _: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard action.target?.isMainFrame != false else {
            return .allow
        }
        if action.navigationType == .linkActivated {
            return .cancel
        }
        guard let url = action.request.url else {
            return .cancel
        }
        if url.scheme == "about" {
            return .allow
        }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              Self.allowedDomains.contains(where: {
                  host == $0 || host.hasSuffix(".\($0)")
              }) else {
            return .cancel
        }
        return .allow
    }

    private static let allowedDomains = [
        "instagram.com",
        "tiktok.com",
        "youtube.com",
        "youtube-nocookie.com",
        // The synthetic host document the YouTube embed is framed in.
        EmbedPlayerHost.name,
    ]
}

private enum EmbeddedMediaControl {
    static let observerScript = """
        (() => {
            if (window.__ladleMediaControlsInstalled) return;
            window.__ladleMediaControlsInstalled = true;

            let muted = false;
            const applyMutedState = () => {
                document.querySelectorAll('video, audio').forEach((media) => {
                    media.muted = muted;
                    media.defaultMuted = muted;
                });
            };
            const forwardToChildFrames = (message) => {
                document.querySelectorAll('iframe').forEach((frame) => {
                    frame.contentWindow?.postMessage(message, '*');
                });
            };

            window.addEventListener('message', (event) => {
                const message = event.data;
                if (message?.source !== 'ladle'
                    || message.command !== 'set-muted') return;
                muted = Boolean(message.muted);
                applyMutedState();
                forwardToChildFrames(message);
            });

            new MutationObserver(applyMutedState).observe(
                document.documentElement,
                { childList: true, subtree: true }
            );
            applyMutedState();
        })();
        """

    static let setMutedScript = """
        const message = {
            source: 'ladle',
            command: 'set-muted',
            muted: Boolean(muted)
        };
        window.postMessage(message, '*');
        document.querySelectorAll('iframe').forEach((frame) => {
            frame.contentWindow?.postMessage(message, '*');
        });
        """
}

@MainActor
struct InlineVideoPlayer: View {
    @Environment(\.scenePhase) private var scenePhase

    let recipe: Recipe
    let isPaused: Bool
    let isMuted: Bool

    @State private var page: WebPage
    @State private var didLoad = false

    init(
        recipe: Recipe,
        isPaused: Bool = false,
        isMuted: Bool = false
    ) {
        self.recipe = recipe
        self.isPaused = isPaused
        self.isMuted = isMuted
        var configuration = WebPage.Configuration()
        configuration.mediaPlaybackBehavior = .allowsInlinePlayback
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: EmbeddedMediaControl.observerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        _page = State(
            initialValue: WebPage(
                configuration: configuration,
                navigationDecider: EmbedNavigationDecider()
            )
        )
    }

    /// YouTube's `/embed/` endpoint is built to run inside an iframe on a
    /// host page. Navigating straight to it as the top-level document makes
    /// the player answer "Video player configuration error / Error 153", so
    /// it is framed in a minimal host document on the platform's own origin.
    private static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func youtubeHostDocument(embedding url: URL) -> String {
        """
        <!DOCTYPE html>
        <html>
          <head>
            <meta name="viewport"
                  content="width=device-width, initial-scale=1,
                           viewport-fit=cover">
            <style>
              html, body {
                margin: 0; height: 100%;
                background: #000; overflow: hidden;
              }
              iframe { display: block; border: 0; width: 100%; height: 100%; }
            </style>
          </head>
          <body>
            <iframe src="\(url.absoluteString)"
                    allow="autoplay; encrypted-media; picture-in-picture"
                    allowfullscreen></iframe>
          </body>
        </html>
        """
    }

    private static func load(_ url: URL, into page: WebPage) {
        guard isYouTube(url),
              let origin = URL(
                  string: "https://\(EmbedPlayerHost.name)/player"
              ) else {
            page.load(URLRequest(url: url))
            return
        }
        page.load(
            simulatedRequest: URLRequest(url: origin),
            responseHTML: youtubeHostDocument(embedding: url)
        )
    }

    var body: some View {
        Group {
            if let url = VideoEmbed.url(for: recipe) {
                WebView(page)
                    .scrollDisabled(true)
                    .accessibilityIdentifier(
                        "watch.player.\(recipe.librarySlug)"
                    )
                    .overlay {
                        if page.isLoading {
                            ZStack {
                                Color.black

                                ProgressView()
                                    .tint(LadleTheme.Label.onAccent)
                                    .padding(LadleTheme.Spacing.regular)
                                    .background(
                                        .black.opacity(0.66),
                                        in: Circle()
                                    )
                                    .accessibilityIdentifier(
                                        "watch.player.loading"
                                    )
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .onAppear {
                        if !didLoad {
                            didLoad = true
                            Self.load(url, into: page)
                        }
                        updatePlaybackSuspension()
                        applyMutedState()
                    }
            } else {
                ContentUnavailableView(
                    VideoEmbed.unavailableTitle,
                    systemImage: "play.slash",
                    description: Text(VideoEmbed.unavailableMessage)
                )
                .foregroundStyle(LadleTheme.Label.onAccent)
            }
        }
        .background(.black)
        .onChange(of: page.isLoading) { _, isLoading in
            guard !isLoading else { return }
            updatePlaybackSuspension()
            applyMutedState()
        }
        .onChange(of: isPaused) { _, _ in
            updatePlaybackSuspension()
        }
        .onChange(of: isMuted) { _, _ in
            applyMutedState()
        }
        .onChange(of: scenePhase) { _, _ in
            updatePlaybackSuspension()
        }
        .onDisappear {
            setPlaybackSuspended(true)
        }
    }

    private func updatePlaybackSuspension() {
        setPlaybackSuspended(
            isPaused || scenePhase != .active
        )
    }

    private func setPlaybackSuspended(_ suspended: Bool) {
        Task {
            await page.setAllMediaPlaybackSuspended(suspended)
        }
    }

    private func applyMutedState() {
        Task {
            _ = try? await page.callJavaScript(
                EmbeddedMediaControl.setMutedScript,
                arguments: ["muted": isMuted]
            )
        }
    }
}

struct VideoEmbedSheet: View {
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    var body: some View {
        NavigationStack {
            InlineVideoPlayer(recipe: recipe)
                .ignoresSafeArea(edges: .bottom)
                .background(LadleTheme.Label.primary)
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
    }
}
