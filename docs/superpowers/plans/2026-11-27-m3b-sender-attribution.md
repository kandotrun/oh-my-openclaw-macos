# Milestone 3b: Sender Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a shared session, show who wrote each message. Other people's messages sit on the left with their name and an initials avatar. Mine stay on the right. Single-user sessions look unchanged.

**Architecture:**

- **Core** (`OhMyOpenClawCore`):
  - `MessageSender` parses the sender that the Gateway recorded on a user row.
  - `ViewerIdentity` resolves who "me" is.
  - `ChatMessage.sender` and `ConversationStore.viewerProfileID` are optional, so stores saved before 3b still load.
- **Platform** (`OhMyOpenClawPlatform`): `SenderStyle` decides own, peer, or agent, and computes the initials and the Control UI hue.
- **State:** `AppModel` resolves the viewer from `hello-ok` presence, or from `users.self`, and caches it per Gateway.
- **Views:** a peer row variant in the transcript.

The rules are in the spec under "Shared sessions". The protocol facts are under "Protocol facts this design relies on".

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing, XCTest UI tests, and the Python fixture.

## Tasks

### Task 1: `MessageSender` (Core, TDD)

`MessageSender.parse(_ record: JSONValue) -> MessageSender?` reads:

- **From `__openclaw`:** `senderId`, `senderName`, `senderUsername`, and `senderIdentity`.
  - Only `profile`, `remote`, and `observation` identities are accepted. Each must be a closed shape whose string parts are non-blank and at most 512 characters.
  - `observation.senderKind` must be `human`, `bot`, or `unknown`.
  - Any other identity is dropped. The other fields are kept.
- **From the top level:** `senderLabel`, trimmed, with a trailing ` (<uuid>)` removed.
- **Agent openings:** a user row whose `provenance` is `inter_session` with `sourceTool` `sessions_create` or `sessions_spawn` gets `agentID`, the agent part of `sourceSessionKey`.
- **Nil** when nothing is present.

**Fields:**

- Fields are plain optional strings: `identityKind`, `identityID`, `id`, `name`, `username`, `label`, and `agentID`.
- `profileID` is `identityID` when the kind is `profile`.
- `displayName` is `label ?? name ?? username ?? <local part of an email-shaped id> ?? id`.
- `colorSeed` is the trimmed `id`, else `displayName`.

**Decoding:** `init(from:)` never throws, so an unreadable saved sender becomes empty instead of locking the saved store.

**Tests:**

- profile with name
- observation from a channel
- agent and legacy identities rejected; a blank part, a 513-character part, an extra key, and `senderKind: "robot"` each rejected
- the label with a UUID suffix
- an agent opening
- a plain row gives nil
- an email-only id gives its local part
- decoding a malformed sender gives empty fields

### Task 2: `ViewerIdentity` (Core, TDD)

`ViewerIdentity` has three cases: `unresolved`, `profileless`, and `profile(id)`.

- **`fromHello(_:)`:**
  - Finds the `snapshot.presence` row whose `connectionId == server.connId` and whose `reason` is not `disconnect`.
  - Gives `.profile(id)` when that row's `user.identity` is `{type: "profile", id}`. Anything else gives `.unresolved`.
- **`fromUsersSelf(_:)`:** gives `.profile(profile.id)`, or `.unresolved`.

**Tests:**

- the matching row
- a disconnect row
- a user with no identity
- a missing `connId`
- `users.self` with and without a profile

### Task 3: Store fields (Core, TDD)

- **`ChatMessage.sender`:** an optional field, added as the init's last parameter.
- **`ConversationStore.parseMessage`:** attaches `MessageSender.parse` to user rows only.
- **`ConversationStore.viewerProfileID`:** an optional field.

**Tests:**

- History and pending inputs carry the sender.
- Assistant rows carry none.
- A literal pre-3b store JSON decodes, with no sender and no viewer.
- A store whose sender is malformed still decodes.

### Task 4: `SenderStyle` (Platform, TDD)

**Functions:**

- `fnv1a(_:)`: 32-bit FNV-1a over UTF-16 units.
- `hue(for:)`: the seed modulo 360.
- `initials(_:)`: the first grapheme of each of the first two words, uppercased; `?` when there are none.
- `attribution(of:viewer:)`:
  - Non-user rows are `.agentReply`.
  - An agent opening is `.agent(id)`.
  - With `.profile(me)`, the row's profile `me` is `.own`, any other sender is `.peer`, and no sender is `.own`.
  - With `.profileless`, any sender is `.peer`.
  - With `.unresolved`, every row is `.own`.

**Tests:**

- `fnv1a("a") == 3826002220` and `fnv1a("") == 2166136261`
- hue 179 for seed `demo-hana`
- initials `佐花`, `AM`, `A`, and `?`
- every attribution case

### Task 5: Viewer resolution (State, TDD)

- **After `hello-ok`:**
  - `viewer = .fromHello`.
  - A profile is saved as `store.viewerProfileID`.
- **When the hello leaves the viewer `.unresolved`:** if the Gateway lists `users.self`, the model calls it without blocking the connection.
  - A profile resolves it.
  - `FORBIDDEN` gives `.profileless` and clears the cache.
  - Any other error leaves it unresolved.
- **`timelineViewer`:** `viewer`, except that `.unresolved` falls back to `.profile(cached id)` when one is saved.
- **`retireConnection`:** resets `viewer`.

**Tests:**

- hello presence resolves and saves
- `FORBIDDEN` gives `.profileless`
- another error keeps the cached id
- a reconnect falls back to the cache

### Task 6: Transcript rows (Views)

- **`MessageRow`** takes an `Attribution`:
  - `.own`: today's right-aligned bubble, identified as `ownMessage`.
  - `.peer`: a 24 pt circle avatar with white initials on HSL(hue, 48%, 42%), the name as a caption, and a `.quaternary` bubble on the left, identified as `peerMessage`. It has no delivery or retry controls.
  - `.agent`: the same layout as a peer, with a `cpu` symbol and the agent's name.
  - `.agentReply`: today's Markdown reply.

### Task 7: Demo and fixture

**Demo:**

- `hello-ok` carries `server.connId` and a presence row for the profile `demo-you`.
- `chat.send` and the seeded welcome row carry `demo-you`.
- A new thread, `チームの作業`, holds a message from `佐藤 花子` (profile `demo-hana`), a reply, my message, and a reply.

**Fixture:**

- `hello-ok` presence names the `fixture-owner` profile.
- `chat.send` stamps that sender.
- `--shared` seeds a `Peer Person` message in the main thread.

**Python tests:**

- presence
- the stamped sender
- the shared seed

### Task 8: Proof

- `just test`, `just lint`, `just build`, and `just uitest`.
- **Demo UI test:** in `チームの作業`, the `peerMessage` named `佐藤 花子` sits left of the transcript's center, and `ownMessage` sits right of it.
- **Fixture UI test (`--shared`):** `Peer Person` is on the left. After I send a message and it settles through history, my message is still on the right.
- **Run the demo** and look at both sides.
