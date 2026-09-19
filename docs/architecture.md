# Architecture

Three pieces share one wire protocol.

- **TotemKit** is a dependency-free Swift package used by both the server and
  the apps: DTOs, the WebSocket frames (`ClientFrame`/`ServerFrame`), the
  peer-to-peer frames (`PeerFrame`, length-prefixed by `PeerWire`), the stage
  reducer and host, the presence state machine, and the WebSocket client.
  Everything with logic in it is a pure value type that never reads a clock, so
  the tests drive it with events.
- **Server** is Vapor with Fluent/SQLite for durable records (users, tokens,
  buddyships, conversations, bots, push tokens) and Redis for everything with a
  lifetime (presence, sittings, throttles). Stateless HTTP handles auth, buddies,
  and sessions; a stateful WebSocket gateway handles presence, introductions,
  sittings, bots, pushes, and badges. It never sees the contents of a
  conversation.
- **Apps** is an xcodegen project with shared SwiftUI sources and `#if os()`
  splits. `AppModel` is the single observable state holder: it feeds the UI,
  applies state-machine effects, and routes socket and peer frames.

## Glossary

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

## Conversations

A conversation *is* its participant set. Its ID is the UUIDv5 of the sorted
participant IDs (`ConversationID.derive`, namespace frozen and pinned by a
golden test), for pairs and groups alike. Both ends compute it locally, so
opening a chat needs no round trip, and a lookup can never return a
conversation of the wrong shape. A derived ID is computable by anyone, so it
is not a capability: every frame naming one is membership-checked on the
server (`usableConversation`) and on the client (`AppModel.canReceive`).

Messages are never stored. Transcripts live in memory for the local user's own
online session and are cleared by the `freshSignOn` flag on the next `welcome`.
Offline recipients are refused client-side and offline group members miss
messages. Groups are single-sitting: they end when everyone leaves and revive
under the same ID when the same combination is started again.

## Presence

Presence lives only in Redis: one key per user with a 90 s TTL refreshed by
30 s client heartbeats. Key expiry is the offline timeout. Three mechanisms in
`GatewayController` keep it honest: explicit sign-off fans out offline at once;
a 30 s sweep reaps connected users whose key expired, because a suspended iOS
app never closes its socket; and an `unreachable` report from a client is
verified with a WebSocket ping before anyone is marked.

A dropped socket gets a 90 s grace period, guarded by a generation counter
against reconnect races, and the client shows itself as reconnecting rather
than offline. A failed ping is strong evidence we cannot reach someone now and
weak evidence they left, so it writes the unreachable mark rather than offline.
The mark is written with `SET XX KEEPTTL`, so a server-side observation never
extends a user's liveness.

The iOS icon badge is how many buddies are online, recomputed from presence on
every transition and pushed as a badge-only APNs message. Sign-on alerts are
opt-in and throttled to one push per buddy per 15 minutes, claimed in Redis with
`SET NX`.

## Peer-to-peer conversations

Each signed-on device binds an iroh endpoint (`PeerLink`) with one QUIC
connection per peer. Voice is one Opus packet per datagram; everything that
must arrive in order is a `PeerFrame` on a stream. Each side opens its own
unidirectional stream, because a QUIC stream does not exist at the far end
until bytes flow on it.

The server only introduces peers: a client announces its ticket once the
endpoint is online and after every reconnect, and the gateway forwards it to
that user's renderers. That user-to-endpoint map is the whole access control.
`PeerLink` refuses connections from endpoints the server never named and
stamps every inbound frame with the user the connection was accepted for.

A completed QUIC write is not delivery. Message writes are fired best-effort;
delivery is the recipient's `ack`, which lights the sender's half-opacity
bubble. There is no failure timer, because QUIC delivers across a brief outage
and a late ack should light the bubble rather than contradict a failure notice.
A 1:1 message unacked after 5 s asks the server to ping-verify the peer so the
buddy list can catch up.

## The stage

Actions are absolute (`setPlaying(true)`), never toggles, so concurrent
identical intents converge. Conditional actions carry the stage version they
targeted and are dropped if it moved. `StageState.preservesState` stops a song
pick from replacing a game in progress. `StageReducer.reduce` takes the
authenticated actor as a parameter rather than reading it from the action.

Only the owner's device runs the reducer; everyone else forwards actions to the
owner, who broadcasts the result. When two people fill an empty stage at once,
the lower user ID keeps it, a rule every participant applies alone. The stage
dies with its owner's presence.

## Bots

Bots are tagged in a message and always produce exactly one reply:
`BotBackend.respond` returns text or throws, and `BotDispatcher` turns every
throw, timeout, and rate limit into a bot bubble. Markdown is stripped in the
dispatcher so every backend inherits the guarantee. A tag ending in an
underscore also sends the conversation so far, supplied by the sender's client
and fenced in the prompt as quoted material.

## Evolving the wire protocol

Adding an optional associated value to an existing frame case is compatible in
both directions: nil keys are omitted, absent keys decode as nil, unknown keys
are ignored. Required new fields and new cases need the server deployed before
client builds ship. A `PeerFrame` that does not decode is skipped, because the
length prefix keeps the stream readable around it. Removing a non-optional
field from a shared DTO breaks every installed build, so server and client ship
together and older TestFlight builds are expired on release.

State that other users render (avatars) rides the `User` DTO, never
`Presence`, because offline buddies still have to render.

## Constraints found in testing

- `Endpoint.online()` must be awaited before publishing the ticket; binding
  alone never registers with a relay.
- iroh 1.1.0's address watcher panics when called from Swift, so `PeerLink`
  polls the address every 15 s.
- An `AVAudioEngine` input tap delivers about 100 ms per callback whatever
  buffer size is requested. `PacketPacer` spaces packets on a strict 20 ms
  timer; one-shot dispatch delays get coalesced and arrive as stutter.
- The receiver holds three frames before playing and drops past 15 queued,
  because a player node drains at real time and a burst would become a
  permanent delay. The cap is loose because Bluetooth outputs report playback
  in ~100 ms batches.
- Removing a player node from a live voice-processing graph asserts inside
  `AVAudioEngine`, so nodes are pooled per sender and never detached.
- YouTube refuses `loadHTMLString` (player errors 152/153), so the server hosts
  the player page at `GET /player`. A web view outside a visible window stalls
  at buffering forever. Player chrome cannot be disabled, so the iframe is
  rendered taller than the visible box and cropped.
- Phone on LTE to Mac at home: direct IPv6 path within seconds, 0.4% loss,
  60 ms round trip. The relay carries only the first seconds.
