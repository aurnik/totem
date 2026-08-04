import Vapor

/// Hosts the stage's YouTube player page.
///
/// This exists because YouTube refuses to embed into a page that has no real
/// HTTP origin: a `WKWebView` fed HTML via `loadHTMLString` fails with player
/// error 152/153 no matter what `baseURL` it claims. Serving the page from the
/// Totem server gives the embed a genuine origin and Referer, which is the only
/// arrangement that plays. Unauthenticated by necessity — a web view carries no
/// bearer token — and harmless, since the page is static and takes only a video
/// ID that the client already had.
struct PlayerPageController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        routes.get("player", use: page)
    }

    func page(req: Request) async throws -> Response {
        let videoID = (try? req.query.get(String.self, at: "v")) ?? ""
        let start = (try? req.query.get(Double.self, at: "t")) ?? 0
        let autoplay = (try? req.query.get(String.self, at: "playing")) == "1"

        let response = Response(status: .ok, body: .init(string: html(
            videoID: videoID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
            start: max(0, start),
            autoplay: autoplay)))
        response.headers.contentType = .html
        // The page is per-video and trivially cheap; never let a proxy pin a
        // stale one in front of a client that just changed videos.
        response.headers.cacheControl = .init(noStore: true)
        return response
    }

    private func html(videoID: String, start: Double, autoplay: Bool) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
          html,body{margin:0;padding:0;background:#000;overflow:hidden;height:100%}
          #stage{position:absolute;inset:0;overflow:hidden}
          /* YouTube draws its title, channel, share and watch-on-YouTube
             chrome against the top and bottom edges of the player, for a few
             seconds on every playback start. No player parameter turns it off
             (showinfo was removed in 2018, modestbranding since deprecated),
             so instead the frame is made taller than the box we show. The
             video letterboxes inside it, which puts the chrome on the black
             bars above and below — outside the crop — while the picture,
             sized to the container's width at 16:9, still fills it exactly.
             Nothing is lost from the image itself.
             pointer-events is off as well: taps would otherwise pause
             playback for one person and desync everyone else. */
          #p{position:absolute;top:50%;left:0;width:100%;height:180%;
             transform:translateY(-50%);border:0;pointer-events:none}
        </style></head>
        <body><div id="stage"><div id="p"></div></div>
        <script>
        function post(m){
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.player) {
            window.webkit.messageHandlers.player.postMessage(m);
          }
        }
        var player, ready = false;
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {
            videoId: '\(videoID)',
            playerVars: {
              controls: 0, playsinline: 1, disablekb: 1, rel: 0, fs: 0,
              cc_load_policy: 0, iv_load_policy: 3,
              modestbranding: 1, start: Math.floor(\(start)), origin: location.origin
            },
            events: {
              onReady: function(){
                ready = true;
                hideCaptions();
                post({type:'ready'});
                if (\(autoplay ? "true" : "false")) { player.playVideo() } else { player.pauseVideo() }
              },
              onStateChange: function(e){ hideCaptions(); post({type:'state', state:e.data}); postTime() },
              onError: function(e){ post({type:'error', code:e.data}) }
            }
          });
          // Swift corrects drift and records pause positions from these, so
          // it never has to round-trip a getCurrentTime() at action time.
          setInterval(postTime, 2000);
        }
        function postTime(){
          if (ready) post({type:'time', t: player.getCurrentTime()});
        }
        // cc_load_policy alone doesn't win against a viewer's "always show
        // captions" preference, and each new video re-enables them, so unload
        // the caption modules outright. 'cc' is the HTML5 player's name for it,
        // 'captions' the older one; unloading a module that isn't there is a
        // no-op, so both are safe to call every time.
        function hideCaptions(){
          if (!player || !player.unloadModule) return;
          try { player.unloadModule('cc'); player.unloadModule('captions'); } catch (e) {}
        }
        // Driven from Swift. Video changes go through cmdLoad so switching
        // videos never reloads the page and restarts the iframe API.
        function cmdLoad(id, start, play){
          if (!ready) return;
          if (play) { player.loadVideoById(id, start) } else { player.cueVideoById(id, start) }
        }
        function cmdPlay(){ if (ready) player.playVideo() }
        function cmdPause(){ if (ready) player.pauseVideo() }
        function cmdSeek(t){ if (ready) player.seekTo(t, true) }
        function cmdTime(){ return ready ? player.getCurrentTime() : 0 }
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}
