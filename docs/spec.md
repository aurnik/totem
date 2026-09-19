# Buddy List — Project Spec (v1)

Native Swift app for iOS and macOS. Recreates the AIM buddy-list experience: deliberate presence, away messages, ephemeral conversations with a defined beginning and end.

---

## 0. Pre-build gate

Before writing client code, validate that people will deliberately sign on. Run a one-week fake-door test with 8–15 target users: a group chat where members post "on" / "off" / away-message-style status and nothing else. Ship criteria: median user signs on ≥3 days that week unprompted. If this fails, the product fails regardless of implementation.

---

## 1. Scope

**In scope (v1):** buddy list with presence, away messages, in-app 1:1 chat, sign-on/sign-off push notifications, sound design, macOS menu bar presence.

**Out of scope (v1):** group chat, media/attachments, message search, Android, web, iMessage export, widgets, Live Activities. (iMessage export and widgets are v1.1 — see §11.)

---

## 2. Core model decisions

These constrain everything below and should not be revisited mid-build.

1. **Presence is deliberate, not ambient.** iOS cannot run a background heartbeat. Do not attempt silent-push loops or location workarounds. Signing on is an explicit user act.
2. **Conversations are session-scoped.** A conversation opens, exists, and closes. When either party signs off, the window closes and the transcript is archived out of the primary UI.
3. **Away message is a first-class field**, not a profile bio. It is the primary expressive surface and the main reason to open the app when not chatting.
4. **Buddy lists are mutual and small.** Both parties must accept. Cap at 100 buddies in v1 to keep presence fan-out trivial.

---

## 3. Presence state machine

Four states. Server is authoritative; client proposes transitions.

| State | Entered when | Exited when |
|---|---|---|
| `offline` | Explicit sign-off, or 90s without heartbeat | Explicit sign-on |
| `online` | Explicit sign-on (app foreground) | Backgrounded >5 min, or sign-off |
| `idle` | App backgrounded >5 min, or macOS system idle >5 min | App returns to foreground |
| `away` | User sets an away message | User clears it, or signs off |

`away` overrides `online`/`idle` for display purposes but does not affect deliverability.

**Heartbeat:** while the app is foregrounded, client sends a heartbeat every 30s over the open WebSocket. Server marks `offline` after 90s of silence. On `applicationWillTerminate` / `applicationDidEnterBackground`, client sends an explicit state change so the common case doesn't wait for timeout.

**Sign-off is an event.** Explicit sign-off closes the socket, plays the door-slam sound, and clears all open conversation windows. This is a designed feature, not cleanup.

---

## 4. Architecture

```
iOS app ─┐
         ├─ WebSocket (presence + messages) ─┐
macOS app ┘                                  ├─ Presence Service
         └─ HTTPS (auth, buddy mgmt, history)┘        │
                                                      └─ APNs
```

**Client:** single SwiftUI multiplatform target, `#if os(iOS)` / `#if os(macOS)` for platform divergence (§7). Minimum: iOS 17, macOS 14 — required for SwiftData and current Observation.

**Transport:** `URLSessionWebSocketTask` for the live channel. No third-party networking dependency. Reconnect with exponential backoff (1s → 30s cap) plus immediate retry on `NWPathMonitor` reporting network return.

**Server:** stateless HTTP for auth/buddy management; stateful WebSocket gateway holding presence in Redis (key per user, TTL 90s, refreshed by heartbeat). Language is an open choice; Vapor keeps it one language end to end.

**Presence fan-out:** on state change, server looks up the user's mutual buddies and pushes to each connected socket. With a 100-buddy cap this is a direct loop, no pub/sub topology needed in v1.

---

## 5. Data model

```
User        id, handle, displayName, avatarURL, createdAt
Buddy       userID, buddyID, status(pending|accepted), createdAt   // one row per direction
Presence    userID, state, awayMessage, lastSeenAt                 // Redis, not durable
Session     id, participantIDs[2], startedAt, endedAt
Message     id, sessionID, senderID, body, sentAt
```

**Retention:** messages persist server-side for 24h to cover reconnects and offline delivery, then hard-delete. Client keeps its own local archive in SwiftData indefinitely, reachable only from a separate History view. The ephemerality is in the UI, not enforced deletion — do not market it as private messaging.

---

## 6. Client feature requirements

**Buddy list (primary screen).** Grouped by state: online, away, idle, then offline collapsed by default. Row shows handle, state dot, and away message inline when set. Sorted alphabetically within group — no algorithmic ordering.

**Sign on / sign off.** Prominent, one tap. Sign-on plays the door-open sound; sign-off plays door-slam. Signing off is available from the buddy list and the macOS menu bar without opening the app.

**Away message.** Set from a sheet on the buddy list. Free text, 140 char cap. Persists across sessions within the same sign-on. Clearing returns to `online`.

**Conversation.** Opens on tapping a buddy. Requires the buddy to be non-`offline` — tapping an offline buddy offers "leave a message" which delivers on their next sign-on, but does not open a live window. Typing indicator sent over the socket (throttled to one event per 3s). Read state is not tracked or displayed — deliberate omission; it reintroduces obligation debt.

**Auto-archive.** When either party transitions to `offline`, the conversation window closes with a visible transition and the transcript moves to History.

**Sounds.** Six required assets: sign-on, sign-off (self), buddy-in, buddy-out, message-received, message-sent. Respect the system silent switch on iOS. Per-buddy sound toggle in v1.1.

---

## 7. Platform divergence

**iOS**
- Presence is bound to app foreground state. `scenePhase` drives the state machine.
- APNs for buddy sign-on alerts. **Throttle: at most one sign-on notification per buddy per 30 minutes, and suppress entirely while the app is foregrounded.** Unthrottled this feature is uninstall-inducing.
- Notification permission requested contextually after the first buddy is added, never at launch.

**macOS**
- Menu bar extra showing online buddy count; click for the list, sign-on/off, and away message without focusing the app.
- **One window per conversation.** This is the AIM interaction model and macOS supports it natively — do not force a unified inbox on desktop.
- Presence remains bound to explicit sign-on, but layer system idle detection (`CGEventSourceSecondsSinceLastEventType`) to auto-transition `online` → `idle` at 5 min.
- App stays signed on when all windows are closed; quitting signs off.

---

## 8. Auth and onboarding

Sign in with Apple, handle chosen at signup (unique, 3–16 chars, immutable in v1). Buddy discovery by handle only — no contact upload in v1. Invite flow generates a universal link that opens the app to a pre-filled buddy request, falling back to the App Store.

Both parties must accept before either sees the other's presence. There is no one-way follow.

---

## 9. Build sequence

1. Server: auth, buddy CRUD, WebSocket gateway, Redis presence with TTL.
2. Shared Swift package: models, socket client, presence state machine, reconnect logic. Unit-test the state machine against clock skew and reconnect races before any UI.
3. iOS: buddy list, sign on/off, away message. No chat yet — dogfood presence alone for one week.
4. Chat: live session, typing indicator, auto-archive.
5. APNs: sign-on alerts with throttling; offline message delivery.
6. macOS: menu bar, multi-window conversations, idle detection.
7. Sound design pass and transition polish. This is not optional finish work — the felt quality of sign-on/sign-off is a substantial part of the product.

---

## 10. Known risks

- **Presence liveness on flaky mobile networks.** A user in a tunnel appears offline to buddies. Mitigation: 90s TTL rather than something tighter, and a "reconnecting" client state that does not immediately show self as offline.
- **Cold-start emptiness.** A buddy list with nobody on it is worse than no app. Onboarding must not complete until at least one mutual buddy exists.
- **Notification fatigue.** See the §7 throttle. Instrument it before scaling past the test group.

---

## 11. v1.1 candidates

- iMessage export: `MSMessagesAppViewController` extension, or simpler, a share-sheet handoff that opens a transcript in Messages. Its role is an escape hatch for conversations that need to outlive the session — never the primary channel.
- WidgetKit widget showing who is on. Treat as a glance surface only; refresh budget is coarse and it will lag actual presence.
- Group conversations, per-buddy sounds, buddy list custom groups.
