import LadleCore
import SwiftUI
import UIKit
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

private enum EmbedNavigationPolicy {
    @MainActor
    static func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame != false else {
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

    /// Wrapped in a function expression so the script can run again without
    /// redeclaring anything in the page's global scope.
    static func setMutedScript(muted: Bool) -> String {
        """
        (() => {
            const message = {
                source: 'ladle',
                command: 'set-muted',
                muted: \(muted)
            };
            window.postMessage(message, '*');
            document.querySelectorAll('iframe').forEach((frame) => {
                frame.contentWindow?.postMessage(message, '*');
            });
        })();
        """
    }
}

/// Owns the `WKWebView` for one embedded clip and mirrors its navigation
/// state for SwiftUI.
///
/// Plain WebKit rather than SwiftUI's `WebPage`/`WebView` because those are
/// iOS 26 only and this screen has to reach iOS 18. The view never shows a
/// page of its own: the app decides what loads, swallows anything that would
/// leave the embed, and drives playback from the outside.
@MainActor
@Observable
private final class EmbeddedPlayerPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var isLoading = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: EmbeddedMediaControl.observerScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // WebKit paints white until the first document arrives, which would
        // flash through the loading overlay on a slow embed.
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    func load(_ request: URLRequest) {
        webView.load(request)
    }

    func load(simulatedRequest request: URLRequest, responseHTML html: String) {
        webView.loadSimulatedRequest(request, responseHTML: html)
    }

    func setAllMediaPlaybackSuspended(_ suspended: Bool) async {
        await webView.setAllMediaPlaybackSuspended(suspended)
    }

    /// Fire-and-forget: the scripts here only post messages into the page.
    ///
    /// Deliberately the plain `evaluateJavaScript(_:completionHandler:)`.
    /// Every `callAsyncJavaScript` overload, async or not, is a Swift-overlay
    /// wrapper rather than a compiler-synthesised import, and the iOS 26 SDK
    /// binds that overlay to a separate `libswiftWebKit.dylib` for deployment
    /// targets below 18.5. iOS 18.5 does not ship that library, so the app
    /// would abort at launch before running a line of its own code.
    func evaluate(_ script: String) {
        webView.evaluateJavaScript(script) { _, _ in }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _: WKWebView,
        didStartProvisionalNavigation _: WKNavigation!
    ) {
        isLoading = true
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        isLoading = false
    }

    func webView(
        _: WKWebView,
        didFail _: WKNavigation!,
        withError _: any Error
    ) {
        isLoading = false
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError _: any Error
    ) {
        isLoading = false
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (EmbedNavigationPolicy.decide(navigationAction), preferences)
    }
}

private struct EmbeddedPlayerView: UIViewRepresentable {
    let page: EmbeddedPlayerPage
    let accessibilityIdentifier: String

    func makeUIView(context _: Context) -> WKWebView {
        page.webView.accessibilityIdentifier = accessibilityIdentifier
        return page.webView
    }

    func updateUIView(_ webView: WKWebView, context _: Context) {
        webView.accessibilityIdentifier = accessibilityIdentifier
    }
}

@MainActor
struct InlineVideoPlayer: View {
    @Environment(\.scenePhase) private var scenePhase

    let recipe: Recipe
    let isPaused: Bool
    let isMuted: Bool

    @State private var page = EmbeddedPlayerPage()
    @State private var didLoad = false

    init(
        recipe: Recipe,
        isPaused: Bool = false,
        isMuted: Bool = false
    ) {
        self.recipe = recipe
        self.isPaused = isPaused
        self.isMuted = isMuted
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

    /// Demo and UI-review builds never reach a video platform.
    ///
    /// Embedding the creator's clip is the whole point of this screen, but it
    /// makes a seeded build depend on the network and on content that is not
    /// ours: a review pass shows whatever the platform decides to serve that
    /// day — including, when a demo ID does not resolve, the platform's own
    /// recommendations — and a store screenshot of it would publish a video
    /// nobody gave us the right to publish. Under `-ui-testing` the player is
    /// the recipe's own photograph, dressed as a paused clip.
    private static let isDemoBuild = ProcessInfo.processInfo.arguments
        .contains("-ui-testing")

    private static func demoPlayerDocument(for recipe: Recipe) -> String? {
        guard isDemoBuild else { return nil }

        // A recipe from the demo Discover feed carries a remote image rather
        // than an asset name. It still must not reach a platform, so it falls
        // back to the play chrome over a flat ground: never a real embed.
        let artwork = recipe.images.first?.localName
            .flatMap(UIImage.init(named:))
            .flatMap { $0.jpegData(compressionQuality: 0.82) }
        let backdrop = artwork.map {
            #"<img src="data:image/jpeg;base64,\#($0.base64EncodedString())">"#
        } ?? ""

        return """
        <!DOCTYPE html>
        <html>
          <head>
            <meta name="viewport"
                  content="width=device-width, initial-scale=1,
                           viewport-fit=cover">
            <style>
              html, body {
                margin: 0; height: 100%;
                background: #14100e; overflow: hidden;
              }
              .stage { position: relative; height: 100%; display: grid;
                       place-items: center;
                       background: radial-gradient(120% 80% at 50% 30%,
                                     #2a211c 0%, #14100e 100%); }
              .stage img { position: absolute; inset: 0; width: 100%;
                           height: 100%; object-fit: cover; }
              .scrim {
                position: absolute; inset: 0;
                background: linear-gradient(180deg,
                  rgba(0,0,0,0.40) 0%, rgba(0,0,0,0) 26%,
                  rgba(0,0,0,0) 64%, rgba(0,0,0,0.70) 100%);
              }
              .play {
                position: relative; width: 96px; height: 96px;
                border-radius: 50%; background: rgba(0,0,0,0.42);
                -webkit-backdrop-filter: blur(6px);
                display: grid; place-items: center;
              }
              .play::after {
                content: ""; width: 0; height: 0; margin-left: 8px;
                border-left: 30px solid #fff;
                border-top: 19px solid transparent;
                border-bottom: 19px solid transparent;
              }
              .bar {
                position: absolute; left: 0; right: 0; bottom: 0;
                height: 3px; background: rgba(255,255,255,0.28);
              }
              .bar span { display: block; height: 100%; width: 34%;
                          background: #fff; }
            </style>
          </head>
          <body>
            <div class="stage">
              \(backdrop)
              <div class="scrim"></div>
              <div class="play"></div>
              <div class="bar"><span></span></div>
            </div>
          </body>
        </html>
        """
    }

    private static func load(
        _ url: URL,
        for recipe: Recipe,
        into page: EmbeddedPlayerPage
    ) {
        if let demo = demoPlayerDocument(for: recipe),
           let origin = URL(
               string: "https://\(EmbedPlayerHost.name)/demo"
           ) {
            page.load(
                simulatedRequest: URLRequest(url: origin),
                responseHTML: demo
            )
            return
        }
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
                EmbeddedPlayerView(
                    page: page,
                    accessibilityIdentifier: "watch.player.\(recipe.librarySlug)"
                )
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
                            Self.load(url, for: recipe, into: page)
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
        page.evaluate(EmbeddedMediaControl.setMutedScript(muted: isMuted))
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
