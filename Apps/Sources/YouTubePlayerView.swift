import SwiftUI
import TotemKit
import WebKit

/// The shared video surface. The page must be served from a real HTTP origin
/// (`AppModel.playerURL`, not `loadHTMLString`, which fails with player error
/// 152/153), and the web view must be in a visible window or playback stalls at
/// buffering forever. The rest is a reconciliation loop: `YouTubeState` is the
/// intent and the coordinator issues the commands that make the player match.
@MainActor
struct YouTubePlayerView {
    let initialURL: URL
    let youtube: YouTubeState
    /// Latest position the player reported, so a pause records where it really was.
    var onTime: (Double) -> Void
    var onEnded: () -> Void
    var onUnplayable: () -> Void

    /// Drift beyond this is corrected with a seek, below it tolerated.
    private static let driftTolerance: Double = 3

    /// Player states a play command can still move: unstarted, paused, cued.
    private static let stalledStates: Set<Int> = [-1, 2, 5]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func makeWebView(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Otherwise the player refuses to start without a tap.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
        configuration.userContentController.add(context.coordinator, name: "player")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.isUserInteractionEnabled = false
        #endif
        context.coordinator.webView = webView
        // isPlaying starts false whatever the stage says: the page's autoplay is
        // one shot, so seeding the intent would make the first reconcile a no-op.
        context.coordinator.applied = .init(videoID: youtube.videoID, isPlaying: false,
                                           positionAt: youtube.positionAt)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    private func update(_ webView: WKWebView, _ context: Context) {
        context.coordinator.parent = self
        context.coordinator.reconcile(to: youtube)
    }

    private static func teardown(_ coordinator: Coordinator) {
        coordinator.webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "player")
        coordinator.webView = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        struct Applied {
            var videoID: String
            var isPlaying: Bool
            /// A new stamp means a skip, not the playhead advancing on its own.
            var positionAt: Date
        }

        var parent: YouTubePlayerView
        var webView: WKWebView?
        var applied = Applied(videoID: "", isPlaying: false, positionAt: .distantPast)
        private var ready = false
        /// The player's own last report, unlike `applied`. -1 is "unstarted".
        private var playerState = -1
        /// Set while a video change is in flight and the player still reports the
        /// old state.
        private var loading = false

        init(_ parent: YouTubePlayerView) {
            self.parent = parent
        }

        func reconcile(to youtube: YouTubeState) {
            guard ready, let webView else { return }
            if applied.videoID != youtube.videoID {
                applied = .init(videoID: youtube.videoID, isPlaying: youtube.isPlaying,
                                positionAt: youtube.positionAt)
                loading = true
                let start = youtube.position(at: Date())
                webView.evaluateJavaScript(
                    "cmdLoad('\(youtube.videoID)', \(start), \(youtube.isPlaying))")
                return
            }
            // Seek before transport, so a resume picks up from where the skip put
            // the playhead.
            if applied.positionAt != youtube.positionAt {
                applied.positionAt = youtube.positionAt
                webView.evaluateJavaScript("cmdSeek(\(youtube.position(at: Date())))")
            }
            guard applied.isPlaying != youtube.isPlaying else { return }
            applied.isPlaying = youtube.isPlaying
            webView.evaluateJavaScript(youtube.isPlaying ? "cmdPlay()" : "cmdPause()")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                reconcile(to: parent.youtube)
            case "state":
                handleState(body["state"] as? Int ?? -1)
            case "time":
                handleTime(body["t"] as? Double ?? 0)
            case "error":
                // 101/150 embedding disabled, 2/5 request and playback failures.
                parent.onUnplayable()
            default:
                break
            }
        }

        private func handleState(_ state: Int) {
            playerState = state
            switch state {
            case 0:
                // Ended. Every client reports this; the owner keeps the first.
                parent.onEnded()
            case 1, 2, 5:
                // Cued (5) counts as settled: leaving `loading` set would gate the
                // retry in handleTime off forever.
                loading = false
                applied.isPlaying = state == 1
            default:
                break
            }
        }

        private func handleTime(_ time: Double) {
            parent.onTime(time)
            guard !loading, parent.youtube.isPlaying, let webView else { return }
            // A play that never took (window not yet visible, or autoplay refused)
            // leaves the stage playing and this player still; the tick is the only
            // thing that runs without a re-render, so the retry lives here.
            if YouTubePlayerView.stalledStates.contains(playerState) {
                webView.evaluateJavaScript("cmdPlay()")
                return
            }
            let target = parent.youtube.position(at: Date())
            if abs(target - time) > YouTubePlayerView.driftTolerance {
                webView.evaluateJavaScript("cmdSeek(\(target))")
            }
        }
    }
}

#if os(iOS)
extension YouTubePlayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context) }
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        teardown(coordinator)
    }
}
#else
extension YouTubePlayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context) }
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        teardown(coordinator)
    }
}
#endif
