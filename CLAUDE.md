# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Totem is an AIM-style buddy-list app: a Vapor server plus a SwiftUI multiplatform client (iOS 17+, macOS 14+). `buddylistspec.md` is the original product spec, but several deliberate deviations are listed below — the spec loses when they conflict.

## Commands

```sh
# Shared package tests (presence state machine, reconnect policy)
cd TotemKit && swift test

# Server: build, sign, and serve on 0.0.0.0:9047 (requires redis-server running)
Server/run.sh

# Regenerate the Xcode project — REQUIRED after adding/removing files in Apps/Sources
cd Apps && xcodegen generate

# Build apps
xcodebuild -project Apps/Totem.xcodeproj -scheme Totem-macOS -configuration Debug build
xcodebuild -project Apps/Totem.xcodeproj -scheme Totem-iOS -destination "generic/platform=iOS" -configuration Debug -allowProvisioningUpdates build

# Build and install on the iPhone (device must be unlocked; retries tunnel errors)
Apps/install.sh
```

**Never glob `DerivedData/Totem-*` to find the built app.** This machine has
more than one DerivedData directory for this project, so the glob can resolve
to a build from hours ago and install it silently — which presents as the app
failing against a current server for reasons that make no sense (a stale client
hitting changed DTOs). `Apps/install.sh` asks `xcodebuild -showBuildSettings`
for `BUILT_PRODUCTS_DIR` instead. Relatedly, a Debug build keeps its real code
in `Totem-iOS.debug.dylib`, not the `Totem-iOS` launcher stub — check the dylib
when confirming an edit actually made it into a build.

Distribution is **TestFlight** (`Server/onboard/testflight.sh` → external group
public link, bundle `com.deadsimple.totem`); invoke that script with an absolute
path, since cwd drifts. Signing is API-driven manual signing: `provision.py`
ensures the bundle ID, an Apple Distribution certificate, and the "Totem
AppStore" profile, and needs `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`. It
runs wherever there's macOS + Xcode (production topology in `MINI_SETUP.md`,
server on Railway via the root `Dockerfile`). Build numbers auto-stamp from the
clock; `MARKETING_VERSION` in `Apps/project.yml` is bumped by hand per
meaningful release only — each new marketing version re-triggers external Beta
App Review. The iOS target is iPhone-only and portrait-locked for App Store
validation; don't reintroduce iPad or landscape support.

To *see* a visual change rather than just compile it: accessibility can't see Totem's windows and
screenshots grab the wrong space. Build a throwaway SwiftUI harness that compiles the real source
files and renders them — `ImageRenderer` for plain views, a real window when the view is an
`NSViewRepresentable` (which `ImageRenderer` can't rasterize).

Commit as the user "aurnik" (git config already set); no Claude attribution.

## Dev-machine networking constraints (will bite you)

- **Never use port 8080.** Local proxy/filter software on this Mac inspects the well-known http-alt port and corrupts inbound WebSocket frames (server closes 1011 on every client frame). Dev port is **9047**.
- **The server binary must be codesigned** or the macOS application firewall silently blocks LAN connections after every rebuild (loopback still works, so only the phone breaks). `Server/run.sh` signs with a stable identity so the firewall allowance persists.
- Use `127.0.0.1`, not `localhost` (resolves to `::1` first; server binds IPv4 only). The phone reaches the Mac at `http://Aurniks-MacBook-Pro.local:9047` (defaults live in `APIClient.defaultServerURL`).

## Architecture

Three pieces, one wire protocol:

- **TotemKit/** — shared SPM package used by both server and apps: DTOs (`User`, `Buddy`, `ChatSession`, `Presence`), the WebSocket frame enums (`ClientFrame`/`ServerFrame` in `WireProtocol.swift`, JSON with ISO-8601 dates via `WireCoder`), the client-side `PresenceStateMachine` (pure value type that never reads a clock — keep it that way; it's the unit-tested core), `ReconnectPolicy` (1s→30s backoff), and `SocketClient` (URLSessionWebSocketTask wrapper owning heartbeat + auto-reconnect).
- **Server/** — Vapor + Fluent/SQLite + Redis. Stateless HTTP for auth/buddies/sessions (`Controllers/`), stateful WebSocket gateway (`Gateway/`). Presence lives only in Redis: one key per user, 90s TTL refreshed by 30s client heartbeats; key expiry *is* the offline timeout. `ConnectionManager` (actor) holds one socket per user and fans out directly (no pub/sub — 100-buddy cap). Auth is a dev-only handle login issuing bearer tokens; Sign in with Apple is a TODO. A migration that seeds rows through a model type is coupled to that model's *current* columns, not the schema the migration creates — it passes locally forever because the migration was already recorded before the column was added, then dies in the migrator on any fresh database. Production is the only fresh database in the system, so this class of bug always surfaces there first: verify migrations against a fresh DB, and make later column-adding migrations tolerate an existing column.
- **Apps/** — xcodegen project (`project.yml`), shared SwiftUI sources with `#if os()` splits. `AppModel` (@Observable, MainActor) is the single client-side state holder: it feeds UI, applies `PresenceStateMachine` effects, and routes socket frames. macOS uses one window per conversation (`WindowGroup(for: UUID.self)`) plus a menu bar extra; iOS pushes conversations in a NavigationStack.

### Evolving the wire protocol

Adding an **optional** associated value to an existing `ClientFrame`/`ServerFrame` case is compatible in both directions: the encoder omits nil keys entirely, absent keys decode as nil, and unknown keys are ignored. Only **required** new fields and entirely new cases force deploying the server before shipping client builds.

**Removing** a non-optional field from a shared DTO breaks every installed build, and the two paths fail differently: `GET /buddies` hard-fails sign-in with `keyNotFound`, while the `welcome` frame decodes with `try?` and is silently dropped — the app comes up empty with no error anywhere. Ship server and client together, and expire older TestFlight builds so a stale client can't be reinstalled.

State that other users render (avatars) lives on the durable user record and rides the `User` DTO — never in `Presence`, which is a 90s Redis TTL, because offline buddies still have to render. Deliver it over the socket that is already open and authenticated: the `welcome` frame carries the account's own copy, and a fan-out frame (`avatarChanged`, to accepted buddies plus group co-participants) patches everyone else's cached copies. Prefer that to new HTTP round trips or refetching lists on presence transitions.

### Bots and chat extensions

**Bots** (`Server/Sources/App/Bots/`, `TotemKit/Bot.swift`) are tagged in a message and always
produce a reply: `BotBackend.respond` returns non-optional or throws, and `BotDispatcher` turns every
throw, timeout, and rate-limit into a bot bubble — no path returns silently. Bots are services, not
personas: never first person. Bubbles carry icon+name only in groups, never in 1:1, and bots never
show typing status. Markdown is stripped server-side in the dispatcher (`plainText()`) so every
future backend inherits the guarantee; clients render plain text.

**The shared stage** (`Gateway/StageStore.swift`, `TotemKit/Stage.swift`) is deliberately not
last-write-wins. Actions are absolute (`setPlaying(true/false)`), never toggles, so concurrent
identical intents converge; conditional actions carry the stage version they targeted and are dropped
if it moved. The read-reduce-write must stay in one actor-isolated step with no suspension point, or
two actions both pass the version check and both write. Seek is a separate action because
`setPlaying` no-ops when the state already matches. `preservesState` says whether losing the stage
would destroy something the participants can't recreate, so a song pick can't bulldoze a game — and
it hangs off `StageState`, not the extension ID, because a *finished* game is as disposable as a
video. `StageReducer.reduce` takes the authenticated `actorID` as a parameter rather than reading it
out of the action, since a client that names its own identity can name someone else's.

**Four** (`TotemKit/Stage.swift`, `Apps/Sources/FourStage.swift`) is Connect 4 on that stage, and the
first extension to use any of the above. Whoever starts is red, the next person to tap Join is
yellow, and drops are refused off-turn — the version check serialises actions but can't tell whose
turn it is. Two consequences worth keeping: a win is an `.updated` stage carrying the outcome, never
`.cleared`, because the gateway broadcasts `.cleared` unattributed and clients derive transcript
notices from the before/after pair, so a clearing win could neither be attributed ("`_` won") nor
seen; and the board is then taken down by a separate `expire` action every client's countdown fires,
which converges because the version check keeps only the first. Pieces are drawn *under* the plate,
which is a single even-odd fill of a rounded rect minus 42 circles — that's what lets an empty hole
show the chat behind it and makes a falling piece read right. The falling piece is found by diffing
the old and new board (exactly one column can have grown) and animated from `onAppear`, the same
render-then-animate shape as `PopInEffect`; kicking it off where the diff happens would let SwiftUI
coalesce both states into one frame and the piece would just appear where it landed. A game needs
both players, so `goOffline` clears it — `clearPairs` covers 1:1, `clearGames(involving:)` covers
groups and has to fan out itself, since nothing else tells the rest of the group.

**YouTube embedding** constraints, all measured: `loadHTMLString` cannot work (player errors 152/153
— YouTube requires a real origin), so Vapor hosts the player page at `GET /player`. A web view that
isn't in a visible window stalls at buffering forever. Player chrome appears for ~4-8s at every
playback start and no parameter removes it (`showinfo` gone, `modestbranding` deprecated) — it's
hidden by rendering the iframe taller than the visible box and cropping, which crops non-16:9 video.
`AVPlayer` is not an option; YouTube's own `youtube-ios-player-helper` is a WKWebView around the same
IFrame API.

### Presence liveness (three mechanisms, all server-side in `GatewayController`)

1. Explicit sign-off / app-termination handlers → immediate offline fan-out.
2. Liveness sweep every 30s: connected users whose Redis key expired get reaped and fanned out offline (a suspended iOS app never closes its socket).
3. Ping-verify on message send: WebSocket protocol ping with 3s timeout before trusting a nominally-connected recipient (skipped if inbound traffic in the last 5s).

Non-deliberate socket drops get a 90s grace period (generation counter in `ConnectionManager` guards against reconnect races) and clients show themselves as reconnecting, never offline.

Reachability and presence are deliberately separate questions. A failed ping is certain evidence we can't reach someone *now* and weak evidence they left — a wifi handoff is indistinguishable from a walk-out — so it never crosses anyone offline. Offline is the expensive transition (transcripts cleared via `freshSignOn`, 1:1 sessions archived, a sign-on alert to every buddy on the way back), and the grace period exists precisely so a tunnel doesn't pay it. Instead `markUnreachable` writes **away with no away message** and fans it out, so the buddy list stops contradicting the "not delivered" the sender just got. Two rules make that shape safe:

- It's written with `SET XX KEEPTTL` (`PresenceStore.annotate`), never `set`. The TTL *is* the offline timeout; a server-side observation about a user is not evidence they're alive, so refreshing it would let repeated send attempts keep a vanished user online forever. `XX` means an already-expired key stays expired rather than being resurrected.
- A message-less away is unambiguously the server's mark, because clients derive `away` from having a message and reject an empty one (`PresenceStateMachine.displayState`, pinned by `UnreachableMarkTests`). So `signOn` clears it on reconnect while preserving an away the user wrote. Don't add a client path that goes away without a message, and don't add a `PresenceState` case for this — an unknown enum case fails to decode and takes the whole frame with it.

### Messages are never stored (product decision, overrides spec §5/§6)

The server is a pure relay: no messages table, nothing message-shaped persisted. Offline recipients are refused (no "leave a message"), offline group members miss messages, and client transcripts are scoped to the local user's own online session: the `freshSignOn` flag on `welcome` clears them on any offline→online transition, including an unintended >90s drop with the app open. Do not reintroduce server-side message storage or restoration of prior-session history.

### Conversation keying

Client transcripts are keyed by **conversation ID**: the peer's user ID for 1:1 chats, the session ID for groups (`AppModel.transcripts`, `groupSessions`). 1:1 sessions auto-archive when either party goes offline; group sessions (N-participant, JSON `participants` column on `sessions`) outlive individual presence and are re-sent in the `welcome` frame. Transcript items are messages plus centered system notices (sign on/off, away changes).

## Product decisions that override the spec

- Minimize interactions: fewest taps to the outcome (auto sign-on at launch, one-tap flows, no intermediate menus). Sign-in flows straight into presence; the Sign On button appears only after a manual sign-off.
- Group chats exist in v1 (spec deferred them to v1.1).
- No server-side message storage (see above).
- Read state is never sent on the wire, but local unread indicators are fine (bold handle + dark chevron).
- Sign-on notifications are local while the app is connected (`NotificationManager`; permission requested only once buddies exist, never at launch — spec §7). Buddies who aren't connected get an APNs push instead (`Pusher` in `PushController.swift`, which also sends friend-request pushes, per-user `signOnPushes` toggle in Settings), disabled unless `APNS_KEY_PEM`/`APNS_KEY_ID` are in the server env. macOS signs off on sleep so dark wakes can't spam pushes.
- Sign-on **pushes** are throttled to one per buddy per rolling 15 minutes (`Limits.signOnPushThrottle`; spec §7 asked for 30); **local** alerts are not throttled at all. The asymmetry is the point: a push interrupts someone who isn't using the app, while a local alert only reaches a user already watching the buddy list. The server claims the window in Redis (`SET NX` with a 15m TTL, so a repeat sign-on can't extend a window it's being refused by) rather than in memory, where a deploy would reset it. It's claimed only for buddies actually being pushed to, so it never has to stay in step with anything the client does.
- Never show a default or placeholder rendering of another user's data — a default is only ever shown to its owner in Settings. Where the element also carried information (presence dot, speaker identity), fall back to the pre-feature affordance rather than to nothing.
- Sounds are stubbed in `SoundPlayer` pending the sound-design pass.
