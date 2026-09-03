# Peer-to-peer conversations

Move everything conversation-shaped — messages, typing, stage actions for
YouTube and Four, mute state — onto the iroh links that already carry voice.
The server keeps identity, buddies, presence, introductions, sittings, bots,
pushes and badges, and the YouTube player page. It stops seeing the contents
of any conversation.

## Where things stand (2026-09-02)

Shipped today, in order:

- Build 202609021120: iOS icon badge = number of buddies online, pushed as a
  badge-only APNs message on every offline↔online transition; sign-on alerts
  became an opt-in setting, off by default (see CLAUDE.md). Server deployed.
- Build 202609022102: one-time explainer page before the local network
  prompt (`LocalNetworkExplainerView`).

Committed but **not released**, waiting for this migration so the copy is
true when testers read it:

- `9677fb5` Explainer reworded around *chat data* going straight between
  devices. Today only voice does; that is why it waits.
- `c460f5a` Update banner deep-links to Totem's TestFlight page
  (`itms-beta://beta.itunes.apple.com/v1/app/6796788149`) instead of the
  public join link, which told existing testers the beta wasn't accepting
  anyone.

Decisions taken, with the reasons, so they aren't reopened:

- **Stay on iroh.** WebRTC was evaluated and would avoid the iOS local
  network prompt (Apple's rule, TN3179: only traffic to a *directly
  reachable* address, multicast or broadcast counts; anything a router
  forwards doesn't — so a WebRTC build that never exchanges host candidates
  never prompts). It lost anyway: it needs a TURN service we'd manage
  (Railway has no public UDP; Cloudflare TURN was the pick), its signaling is
  far heavier than `connect(ticket)`, and iroh's n0 relay is free and global.
  The prompt is handled by explaining it instead. iroh's own issue about the
  prompt is n0-computer/iroh#3474, open, no lead; the ffi exposes no knob.
- **Pear / Hyperswarm rejected**: JavaScript runtime embedded via Bare Kit,
  DHT-based traversal with no documented relay fallback, buys nothing over
  iroh.
- **Stage arbitration**: whoever starts a stage owns it (details below), not a
  lowest-ID coordinator. Four's turn rule already serialises drops; ownership
  covers the races around them.
- **Test buddy**: `buddybot` on production (`Server/onboard/buddybot.py`) can
  be signed on/off to flip presence remotely. It speaks only the server
  socket, so it will never receive a peer-to-peer message — it's for presence
  and badge tests only.

## Design

### Transport: `VoiceLink` becomes `PeerLink`

One iroh connection per peer, as today. Voice keeps its unreliable datagrams
(`send(_:in:)`, 20-byte header, sequence-checked). Add **one long-lived
bidirectional QUIC stream per connection** for everything that must arrive,
in order: length-prefixed frames encoded with `WireCoder`, so the same
compatibility rules as `ClientFrame`/`ServerFrame` apply (optional new fields
are safe; new cases need both ends updated).

```swift
// TotemKit/PeerFrame.swift
public enum PeerFrame: Codable, Sendable {
    case message(ChatMessage)                       // sender-minted id + sentAt
    case typing(conversationID: UUID)
    case audioMuted(conversationID: UUID, muted: Bool)
    case stageAction(conversationID: UUID, action: StageAction, expectedVersion: Int?)
    case stageRequest(conversationID: UUID)
    case stage(conversationID: UUID, stage: Stage?)  // owner → everyone
}
```

`ChatMessage.sessionID` keeps carrying the conversation ID (JSON key frozen).
The receiver already trusts `senderID` = the authenticated connection's user,
never the frame's contents — keep that: `PeerLink` stamps the sender.

Access control is unchanged and is the whole model: a connection is accepted
only from an endpoint the server introduced (`endpoint` frame), and a frame
is applied only for a conversation the sender is actually in (client-side
check against the roster / group sitting, mirroring `usableConversation`).

**Dialling.** Voice dials when `setRecipients` is set. Add: dial a peer when
their conversation is opened (`viewing`), so the link is warm before the
first keystroke; dial on first send otherwise. Links stay up while both are
signed on; `removePeer` on their offline presence as today.

### Messages

- **Send**: mint `ChatMessage(id:, sentAt: now)` locally, append to the
  transcript as pending, write to each recipient's stream. Delivered when the
  write completes; the existing "not delivered" bubble (`pendingSends`) fires
  if no link is up within ~5 s or the write fails. 1:1: refuse locally when
  `presences[peer]` is offline, the check the server does today. Groups:
  best effort per peer, exactly like offline members miss messages today.
- **`messageSent` goes away** — the sender already has the message.
- **Unreachable stays a server judgement.** When a 1:1 send fails, the client
  sends a new `ClientFrame.unreachable(userID)`; the server ping-verifies
  (existing `verifyAlive`) and, only if that fails, `markUnreachable` writes
  the message-less away with `SET XX KEEPTTL` as it does now. A client
  claiming someone is unreachable is never enough on its own.
- **Pair sittings** open on traffic today (`sittings.open` in `relay`). Add
  `ClientFrame.conversationActive(conversationID)`, sent by either party on
  the first message sent *or received* in a pair; the server opens the
  sitting. Everything downstream (sign-off ends it, `sessionClosed`, ephemera
  cleared) is untouched.
- **Bots** are server services and stay there. A message that tags a bot is
  sent peer-to-peer to the humans *and* to the server as
  `ClientFrame.botQuery(conversationID, body, context)`; the server runs
  `BotDispatcher` and fans `botMessage` out as today. Bots never see untagged
  traffic any more, which is the point.
- **Typing and mute** move to `PeerFrame`. `viewing` stays on the server: it
  is presence-like and the server derives its transitions.

### Stage: the starter owns it

`Stage` gains `ownerID: UUID`. The user who sends the first action for a
conversation (`.four(.start)`, `.youtube(.setVideo)`) becomes owner and holds
the authoritative `Stage`. Everyone else sends actions **to the owner only**;
the owner runs `StageReducer.reduce` (already pure, already takes the
authenticated `actorID`) and broadcasts `.stage(conversationID, stage)` to
every participant. One writer means the version check is trivially serial;
`expectedVersion` still travels so a stale conditional action is dropped
rather than applied to a moved stage.

- **Join race** (two tap Join): owner applies the first to arrive; the second
  gets the broadcast and sees they're a spectator.
- **Replacing a stage**: an action for a different extension goes to the
  current owner, who refuses it while `preservesState` is true. Same rule as
  today, enforced by the owner instead of the store.
- **Owner leaves** (offline presence, or their link drops past the grace
  period): everyone clears the stage locally. Today a group video survives
  the starter leaving because the server holds it; under this rule it
  doesn't. Accepting that for v1; ownership hand-off to the lowest remaining
  ID is the follow-up if it annoys anyone.
- **Four expire**: each client's countdown clears its own copy; the owner
  broadcasts `.stage(nil)` so late arrivals agree. No coordination needed.
- **Late joiner / reconnect**: `.stageRequest` to the owner, who replies
  with the current stage. If nobody answers as owner, there is no stage.
- **`goOffline` on the server** stops clearing stages (it no longer has
  any); clients already clear pairs off the offline presence frame and now
  clear group stages the same way.

### Server after the migration

Removed once the compatibility window closes: `relay` (human fan-out),
`StageStore`, `applyStageAction`, `requestStage`, `closeStage`, `messageSent`,
`typing`, `setMuted`/`audioMuted`. Added: `botQuery`, `unreachable`,
`conversationActive`. `usableConversation` guards all three.

## Rollout

Client and server ship together; older builds are expired on release.

1. **TotemKit**: `PeerFrame`, `Stage.ownerID`, new `ClientFrame` cases.
   Tests: `PeerFrame` round-trip through the length-prefixed coder; an owner
   host test pinning join-race and preserve-state refusal; Four's off-turn
   drop refused by the reducer (already pinned — keep it).
2. **Server**: add the three new frames. Keep `relay` and the stage store
   working for one release so a straggler build still functions; delete in
   the release after.
3. **Client**: `PeerLink` stream; `AppModel` routes peer frames into the same
   handlers server frames use today (`.message`, `.typing`, `.stage`);
   `StageHost` (owner logic); local offline check; `conversationActive` and
   `unreachable` reporting; `botQuery` alongside tagged sends.
4. **Release** with the two waiting commits. Tester note, plain language:
   messages and games now travel straight between devices; the network
   permission page explains why.
5. **Following release**: remove the server's relay and stage paths; update
   CLAUDE.md's architecture section (messages, stage, "who's looking").

Estimate: three to five working days, most of it the client.

## Verification

- `cd TotemKit && swift test` for the coder, the stage host, and the reducer.
- Two devices, phone on LTE and Mac at home, against the local server: text
  both ways, typing, a Four game with a deliberate off-turn tap, a YouTube
  play/pause race, then the Mac signs off mid-game (stage clears on the
  phone). Repeat with a three-person group (`buddybot` can't take part; a
  third real device or a second Mac account is needed).
- Kill the phone's radio mid-message: "not delivered" appears, the server
  marks the phone away only after its own ping fails.
- Confirm no message body appears in `railway logs` at any point.

## Open questions

- Warm links on conversation open, or only on first send? Warm is proposed;
  it costs a connection per open chat, nothing else.
- Group stage owner leaving kills the stage. Accept, or build hand-off now?
- Keep `send` relaying on the server for exactly one release, or longer?
