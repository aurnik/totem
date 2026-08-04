import SwiftUI
import TotemKit
import WebKit

/// The shared video surface.
///
/// Two constraints came out of testing this against YouTube, and both are
/// load-bearing: the page must be served from a real HTTP origin (hence
/// `AppModel.playerURL`, not `loadHTMLString`, which fails with player error
/// 152/153), and the web view must be attached to a visible window or playback
/// stalls at "buffering" forever. Everything else is a reconciliation loop:
/// the shared `YouTubeState` is the intent, and the coordinator issues only the
/// commands needed to make the player match it.
@MainActor
struct YouTubePlayerView {
    let initialURL: URL
    let youtube: YouTubeState
    /// Latest position the player reported, so a pause records where playback
    /// really was rather than where the shared clock estimated.
    var onTime: (Double) -> Void
    var onEnded: () -> Void
    var onUnplayable: () -> Void

    /// Beyond this the player is far enough from the shared position to be
    /// worth a visible seek; below it, seeking would be more jarring than the
    /// drift.
    private static let driftTolerance: Double = 3

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func makeWebView(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Without this the player refuses to start without a tap, which would
        // defeat the point of a shared stage.
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
        // Belt and braces with the page's own pointer-events blocking and the
        // SwiftUI hit-test opt-out: nothing about this view is interactive.
        webView.isUserInteractionEnabled = false
        #endif
        context.coordinator.webView = webView
        context.coordinator.applied = .init(videoID: youtube.videoID, isPlaying: youtube.isPlaying)
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
        }

        var parent: YouTubePlayerView
        var webView: WKWebView?
        var applied = Applied(videoID: "", isPlaying: false)
        private var ready = false
        /// Set while a video change is in flight: the player reports the old
        /// previous state briefly, and acting on it would fight the new video.
        private var loading = false

        init(_ parent: YouTubePlayerView) {
            self.parent = parent
        }

        func reconcile(to youtube: YouTubeState) {
            guard ready, let webView else { return }
            if applied.videoID != youtube.videoID {
                applied = .init(videoID: youtube.videoID, isPlaying: youtube.isPlaying)
                loading = true
                let start = youtube.position(at: Date())
                webView.evaluateJavaScript(
                    "cmdLoad('\(youtube.videoID)', \(start), \(youtube.isPlaying))")
                return
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
                // 101 and 150 both mean the owner disabled embedding; 2 and 5
                // are malformed-request and playback failures. None are worth
                // distinguishing to the user.
                parent.onUnplayable()
            default:
                break
            }
        }

        private func handleState(_ state: Int) {
            switch state {
            case 0:
                // Ended. Every client with the chat open reports this; the
                // server keeps the first and rejects the rest.
                parent.onEnded()
            case 1, 2:
                loading = false
                applied.isPlaying = state == 1
            default:
                break
            }
        }

        private func handleTime(_ time: Double) {
            parent.onTime(time)
            guard !loading, parent.youtube.isPlaying, let webView else { return }
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
