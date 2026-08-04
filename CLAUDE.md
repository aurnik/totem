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

# Install on the iPhone (device must be unlocked; retry on tunnel errors)
xcrun devicectl device install app --device 4FABDBEF-E20F-5818-9026-83C0F0502A78 \
  "$HOME/Library/Developer/Xcode/DerivedData/Totem-"*/Build/Products/Debug-iphoneos/Totem-iOS.app
```

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

Commit as the user "aurnik" (git config already set); no Claude attribution.

## Dev-machine networking constraints (will bite you)

- **Never use port 8080.** Local proxy/filter software on this Mac inspects the well-known http-alt port and corrupts inbound WebSocket frames (server closes 1011 on every client frame). Dev port is **9047**.
- **The server binary must be codesigned** or the macOS application firewall silently blocks LAN connections after every rebuild (loopback still works, so only the phone breaks). `Server/run.sh` signs with a stable identity so the firewall allowance persists.
- Use `127.0.0.1`, not `localhost` (resolves to `::1` first; server binds IPv4 only). The phone reaches the Mac at `http://Aurniks-MacBook-Pro.local:9047` (defaults live in `APIClient.defaultServerURL`).

## Architecture

Three pieces, one wire protocol:

- **TotemKit/** — shared SPM package used by both server and apps: DTOs (`User`, `Buddy`, `ChatSession`, `Presence`), the WebSocket frame enums (`ClientFrame`/`ServerFrame` in `WireProtocol.swift`, JSON with ISO-8601 dates via `WireCoder`), the client-side `PresenceStateMachine` (pure value type, all time injected through events — keep it that way; it's the unit-tested core), `ReconnectPolicy` (1s→30s backoff), and `SocketClient` (URLSessionWebSocketTask wrapper owning heartbeat + auto-reconnect).
- **Server/** — Vapor + Fluent/SQLite + Redis. Stateless HTTP for auth/buddies/sessions (`Controllers/`), stateful WebSocket gateway (`Gateway/`). Presence lives only in Redis: one key per user, 90s TTL refreshed by 30s client heartbeats; key expiry *is* the offline timeout. `ConnectionManager` (actor) holds one socket per user and fans out directly (no pub/sub — 100-buddy cap). Auth is a dev-only handle login issuing bearer tokens; Sign in with Apple is a TODO.
- **Apps/** — xcodegen project (`project.yml`), shared SwiftUI sources with `#if os()` splits. `AppModel` (@Observable, MainActor) is the single client-side state holder: it feeds UI, applies `PresenceStateMachine` effects, and routes socket frames. macOS uses one window per conversation (`WindowGroup(for: UUID.self)`) plus a menu bar extra; iOS pushes conversations in a NavigationStack.

### Evolving the wire protocol

Adding an **optional** associated value to an existing `ClientFrame`/`ServerFrame` case is compatible in both directions: the encoder omits nil keys entirely, absent keys decode as nil, and unknown keys are ignored. Only **required** new fields and entirely new cases force deploying the server before shipping client builds.

State that other users render (avatars) lives on the durable user record and rides the `User` DTO — never in `Presence`, which is a 90s Redis TTL, because offline buddies still have to render. Deliver it over the socket that is already open and authenticated: the `welcome` frame carries the account's own copy, and a fan-out frame (`avatarChanged`, to accepted buddies plus group co-participants) patches everyone else's cached copies. Prefer that to new HTTP round trips or refetching lists on presence transitions.

### Presence liveness (three mechanisms, all server-side in `GatewayController`)

1. Explicit sign-off / app-termination handlers → immediate offline fan-out.
2. Liveness sweep every 30s: connected users whose Redis key expired get reaped and fanned out offline (a suspended iOS app never closes its socket).
3. Ping-verify on message send: WebSocket protocol ping with 3s timeout before trusting a nominally-connected recipient (skipped if inbound traffic in the last 5s).

Non-deliberate socket drops get a 90s grace period (generation counter in `ConnectionManager` guards against reconnect races) and clients show themselves as reconnecting, never offline.

### Messages are never stored (product decision, overrides spec §5/§6)

The server is a pure relay: no messages table, nothing message-shaped persisted. Offline recipients are refused (no "leave a message"), offline group members miss messages, and client transcripts are scoped to the local user's own online session: the `freshSignOn` flag on `welcome` clears them on any offline→online transition, including an unintended >90s drop with the app open. Do not reintroduce server-side message storage or restoration of prior-session history.

### Conversation keying

Client transcripts are keyed by **conversation ID**: the peer's user ID for 1:1 chats, the session ID for groups (`AppModel.transcripts`, `groupSessions`). 1:1 sessions auto-archive when either party goes offline; group sessions (N-participant, JSON `participants` column on `sessions`) outlive individual presence and are re-sent in the `welcome` frame. Transcript items are messages plus centered system notices (sign on/off, away changes).

## Product decisions that override the spec

- Minimize interactions: fewest taps to the outcome (auto sign-on at launch, one-tap flows, no intermediate menus). Sign-in flows straight into presence; the Sign On button appears only after a manual sign-off.
- Group chats exist in v1 (spec deferred them to v1.1).
- No server-side message storage (see above).
- Read state is never sent on the wire, but local unread indicators are fine (bold handle + dark chevron).
- Sign-on notifications are local while the app is connected (`NotificationManager`, one per buddy per 30 minutes; permission requested only once buddies exist, never at launch — spec §7). Buddies who aren't connected get an APNs push instead (`SignOnPusher` in `PushController.swift`, same 30-minute throttle server-side, per-user `signOnPushes` toggle in Settings), disabled unless `APNS_KEY_PEM`/`APNS_KEY_ID` are in the server env. macOS signs off on sleep so dark wakes can't spam pushes.
- Never show a default or placeholder rendering of another user's data — a default is only ever shown to its owner in Settings. Where the element also carried information (presence dot, speaker identity), fall back to the pre-feature affordance rather than to nothing.
- Sounds are stubbed in `SoundPlayer` pending the sound-design pass.
