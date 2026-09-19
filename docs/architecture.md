# Architecture

Three pieces share one wire protocol.

- **TotemKit** is a dependency-free Swift package used by both the server and
  the apps: DTOs (`User`, `Buddy`, `ChatSession`, `Presence`), the WebSocket
  frames (`ClientFrame`/`ServerFrame`, JSON with ISO-8601 dates), the
  peer-to-peer frames (`PeerFrame`, length-prefixed by `PeerWire`), the
  stage reducer and host (`StageReducer`, `StageHost`), the client presence
  state machine, the reconnect policy, and the WebSocket client. Everything
  with logic in it is a pure value type that never reads a clock, so the
  tests drive it with events.
- **Server** is Vapor with Fluent/SQLite for durable records (users, tokens,
  buddyships, conversations, bots, push tokens) and Redis for everything with
  a lifetime (presence, sittings, throttles). Stateless HTTP handles auth,
  buddies, and sessions; a stateful WebSocket gateway handles presence,
  introductions, sittings, bots, pushes, and badges. It never sees the
  contents of a conversation.
- **Apps** is an xcodegen project with shared SwiftUI sources and `#if os()`
  splits. `AppModel` is the single observable state holder: it feeds the UI,
  applies state-machine effects, and routes socket and peer frames.

## Glossary

- **Sign on / sign off**: the user's deliberate presence transitions. Signing
  off clears every transcript.
- **Sitting**: a conversation being live, kept in Redis. A pair's sitting opens
  on the first message and a group's when someone creates it; either ends when
  fewer than two participants remain online.
- **Stage**: the shared area at the top of a chat that holds an extension
  (YouTube, Four). The participant who fills it from empty is its owner.
- **Renderers** of a user: accepted buddies plus co-participants of live group
  sittings, which is everyone who draws that user's avatar or presence.
- **Unreachable mark**: an `away` presence with no message, which only the
  server writes. Clients derive `away` from having a message, so the shape is
  unambiguous.

## Identity and conversations

A conversation *is* its participant set. Its ID is the UUIDv5 of the sorted
participant IDs (`ConversationID.derive`, namespace frozen and pinned by a
golden test), for pairs and groups alike. Both ends compute it locally, so
tapping a buddy opens a chat with no round trip, and a lookup can never return a
conversation of the wrong shape. Rows in `conversations` are permanent and
idempotent. A derived ID is computable by anyone, so it is not a capability:
every frame naming one is membership-checked on the server
(`usableConversation`) and on the client (`AppModel.canReceive`).

Groups are single-sitting: they end when everyone leaves, drop off the buddy
list, and revive under the same ID when the same combination is started again.

## Presence

Presence lives only in Redis: one key per user with a 90 s TTL refreshed by
30 s client heartbeats. Key expiry is the offline timeout. Three mechanisms keep
it honest, all in `GatewayController`:

1. Explicit sign-off and app-termination handlers fan out offline immediately.
2. A 30 s liveness sweep reaps connected users whose key has expired, because a
   suspended iOS app never closes its socket.
3. An `unreachable` report from a client is verified with a WebSocket ping
   before anyone is marked.

A dropped socket gets a 90 s grace period (a generation counter guards against
reconnect races) and the client shows itself as reconnecting, never offline.
Reachability and presence are separate questions: a failed ping is strong
evidence we cannot reach someone now and weak evidence they left, so it writes
the unreachable mark rather than offline. The mark is written with
`SET XX KEEPTTL` so a server-side observation never extends a user's liveness.

Offline is the expensive transition: transcripts are cleared on the next
sign-on via the `freshSignOn` flag on `welcome`, sittings end, and buddies get a
sign-on alert on the way back.

## Peer-to-peer conversations

Each signed-on device binds an iroh endpoint (`PeerLink`) with one QUIC
connection per peer. Voice is one Opus packet per datagram; everything that
must arrive in order is a `PeerFrame` on a stream. Each side opens its own
unidirectional stream, because a QUIC stream does not exist at the far end
until bytes flow on it.

The server introduces peers: a client announces its ticket once the endpoint is
online and again after every reconnect, and the gateway forwards it to that
user's renderers. That user-to-endpoint map is the whole access control.
`PeerLink` refuses connections from endpoints the server never named and
stamps every inbound frame with the user the connection was accepted for.

A completed QUIC write is not delivery. Message writes are fired best-effort;
delivery is the recipient's `ack`, which lights the sender's half-opacity
bubble. There is no failure timer, because QUIC delivers across a brief outage
and a late ack should light the bubble rather than contradict a "not delivered"
notice. A 1:1 message unacked after 5 s asks the server to ping-verify the peer
so the buddy list can catch up.

The server is still told three things: `conversationActive` on the first
message in a pair, so it can open the sitting; `unreachable`, as evidence to
verify; and `botQuery` for a message that tags a bot.

### Things that were measured

- `Endpoint.online()` must be awaited before publishing the ticket; binding
  alone never registers with a relay.
- iroh 1.1.0's address watcher panics when called from Swift, so `PeerLink`
  polls the address every 15 s.
- An `AVAudioEngine` input tap delivers about 100 ms per callback whatever
  buffer size is requested, so every tap is five packets. `PacketPacer` spaces
  them on a strict 20 ms timer; one-shot dispatch delays were coalesced on
  macOS and the bunching came through as stutter.
- The receiver holds three frames before playing (`JitterBuffer`) and drops
  past 15 queued, because a player node drains at exactly real time and a burst
  would otherwise be a permanent delay. The cap is loose because Bluetooth
  outputs report playback in ~100 ms batches.
- On this network, phone on LTE to Mac at home: direct IPv6 path within
  seconds, 0.4% loss, 60 ms round trip. The relay carries only the first
  seconds.
- Removing a player node from a live voice-processing graph asserts inside
  `AVAudioEngine`, so nodes are pooled per sender and never detached.

## The stage

Actions are absolute (`setPlaying(true)`), never toggles, so concurrent
identical intents converge. Conditional actions carry the stage version they
targeted and are dropped if it moved. `seek` is separate from `setPlaying`
because the latter is a no-op when the state already matches.
`StageState.preservesState` says whether losing the stage would destroy
something the participants cannot recreate, so a song pick cannot bulldoze a
game in progress. `StageReducer.reduce` takes the authenticated actor as a
parameter rather than reading it from the action.

The starter owns the stage. Only the owner's device runs the reducer; everyone
else forwards actions to the owner, who broadcasts the result. A refused action
gets a quiet re-sync to its sender alone. When two people fill an empty stage at
once, the lower user ID keeps it, a rule every participant applies alone. The
stage dies with its owner's presence.

**Four** is Connect Four on that stage. The starter is red, the next person to
tap Join is yellow, and off-turn drops are refused by the reducer. A win is an
updated stage carrying the outcome, never a cleared one, so it can be
attributed in the transcript; a separate `expire` action takes the board down
after a countdown every client runs, and the version check keeps only the
first.

**YouTube** embedding constraints: `loadHTMLString` cannot work (YouTube requires
a real origin, player errors 152/153), so the server hosts the player page at
`GET /player`. A web view that is not in a visible window stalls at buffering
forever. Player chrome appears for several seconds at every playback start and
no parameter removes it, so the iframe is rendered taller than the visible box
and cropped.

## Bots

Bots are tagged in a message and always produce exactly one reply:
`BotBackend.respond` returns text or throws, and `BotDispatcher` turns every
throw, timeout, and rate limit into a bot bubble. Bots are services, not
personas, and never speak in the first person. Markdown is stripped in the
dispatcher so every backend inherits the guarantee. A tag ending in an
underscore (`@gemini_`) also sends the conversation so far, supplied by the
sender's client since the server holds no transcript; it is fenced in the prompt
as quoted material.

## Evolving the wire protocol

Adding an optional associated value to an existing frame case is compatible in
both directions: the encoder omits nil keys, absent keys decode as nil, and
unknown keys are ignored. Required new fields and new cases need the server
deployed before client builds ship. `PeerFrame` follows the same rules between
client builds; a frame that does not decode at all is skipped, because the
length prefix keeps the stream readable around it.

Removing a non-optional field from a shared DTO breaks every installed build,
and the two paths fail differently: `GET /buddies` hard-fails sign-in, while the
`welcome` frame is decoded with `try?` and silently dropped. Server and client
ship together, and older TestFlight builds are expired on release.

State that other users render (avatars) rides the `User` DTO, never `Presence`,
because offline buddies still have to render. The `welcome` frame carries the
account's own copy and `avatarChanged` patches everyone else's.

## Product decisions

- Fewest taps to the outcome: auto sign-on at launch, sign-in flows straight
  into presence, no intermediate menus.
- Messages are never stored. Offline recipients are refused client-side, and
  offline group members miss messages.
- Read state is never sent on the wire; local unread indicators are fine.
- The iOS badge is how many buddies are online. It is recomputed from presence
  on every transition and pushed as a badge-only APNs message.
- Sign-on alerts are opt-in and off by default. Pushes are throttled to one per
  buddy per 15 minutes, claimed in Redis with `SET NX`; local alerts are not
  throttled, because they only reach someone already looking at the list.
- Never show a default rendering of another user's data. A default is only
  ever shown to its owner in Settings.
- Testers are not emailed about builds. The `welcome` frame carries the newest
  build number and the app shows an update banner when it is behind.
