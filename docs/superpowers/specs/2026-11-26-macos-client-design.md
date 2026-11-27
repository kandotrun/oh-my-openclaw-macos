# Oh My OpenClaw for Mac — Design

Date: 2026-11-26 (revised the same day for development work)
Status: approved for implementation

## Goal

A native macOS client for a personal OpenClaw Gateway, built for having the agent do software development. The interaction model follows [T3 Code](https://github.com/pingdotgg/t3code):

- Threads live under projects and run in parallel.
- Each turn's agent work (commands, edits, reads, diffs) is visible in a dense work log.
- Approvals happen inline, and notifications report finished or blocked threads.

It is an independent client. It hosts no AI service, manages no Gateway, and embeds no administration console. The shared Gateway layer comes from the iOS client [oh-my-openclaw-ios](https://github.com/kandotrun/oh-my-openclaw-ios). The iOS conversation model (a main chat plus side chats) is replaced by projects and threads.

## Decisions

| Topic | Decision |
| --- | --- |
| Relationship to the iOS client | Independent repository. The shared logic is copied, not shared through a package. |
| Copy source | `kandotrun/oh-my-openclaw-ios` at `e9a5515823c56473958fcd2047ca41754747cf8b` |
| Minimum OS | macOS 27 |
| Toolchain | Xcode 27, Swift 6.4 (`swift-tools-version: 6.4`), Swift 6 language mode |
| Distribution | Local builds only for now. The app is App Sandbox ready so TestFlight or Developer ID can be added later. |
| Repository | `kandotrun/oh-my-openclaw-macos`, public, English documentation and commits |
| Bundle identifier | `run.kandot.oh-my-openclaw.mac` |
| v0.1 scope | T3 Code-style development client: projects and threads, work log, inspector, notifications for every thread. One main window. |
| UI language | Japanese |

## Non-goals for v0.1

- A dedicated diff panel. Diffs appear inside work log entries.
- A terminal, Git actions (commit, push, pull request), and a file browser
- Command palette and slash-command completion
- Child-session lineage views, a browser panel, multiple windows, Quick Chat
- Bonjour discovery and TLS certificate pinning
- Custom dictation (macOS system dictation works in the composer) and QR scanning
- Node capabilities, Gateway installation or management, administration screens

## T3 Code concepts on OpenClaw

| T3 Code | OpenClaw Gateway |
| --- | --- |
| Project | `projects.list` record (`id`, `displayName`, `source`). Sessions outside a project are grouped under "No project". |
| Thread | Session (`sessions.subscribe` roster). Project sessions work in their own managed checkout and branch. |
| New worktree / current checkout | `projects.checkoutOptions` (`worktree`, `current`) and `sessions.create` |
| Working state and elapsed time | `hasActiveRun` and `activeRunIds` on session rows |
| Running thread subtitle | `sessions.messages.subscribe` with `mode: "narration"` (`session.narration` snapshots and tool identity) |
| Work log | `agent` events with `stream: "tool"` for the selected thread, persisted tool records in `chat.history`, and full outputs through `chat.message.get` |
| Approvals and questions | `exec.approval.*`, `plugin.approval.*`, `question.*` |

## Protocol facts this design relies on

Checked against OpenClaw `main` at `b1d355f` (2026-11-26, release 2026.11.10):

- Operator clients negotiate protocol v4 exactly (`minProtocol` and `maxProtocol` are both 4).
- Requested scopes stay as in iOS: `operator.read`, `operator.write`, `operator.approvals`, `operator.questions`.
- Paired device metadata (platform, device family) is pinned. The Mac client therefore sends `platform: "macos"` and `deviceFamily: "Mac"` with its own device identity and pairs as a new device.
- Device proofs keep the v2 signature payload, which the official Swift clients also still use for compatibility.
- Loopback connections, including SSH port forwards, are silently approved on first pairing by default. LAN and Tailnet connections to the same host still require approval.
- The reference client reconnects with backoff from 1 s up to 30 s and never retries automatically after a pairing or authentication refusal.
- Under load, queued message notifications can collapse into one `sessions.changed` event whose top-level payload has `phase: "message"` and no `message`, `messageId`, or `messageSeq`. Clients refetch `chat.history` for the matching conversation. Milestone 1 implements this.
- Shared sessions record who wrote each user row in `__openclaw`: `senderId`, `senderName`, `senderUsername`, and a typed `senderIdentity`. Readers accept only `profile`, `remote`, and `observation` identities. Channel senders are `observation`. Inbound channel rows can also carry a top-level `senderLabel`.
  - Profile connections stamp their own profile on `chat.send`.
  - Shared-token and password connections all become the single `gateway-owner` profile, so they count as one person.
  - The opening message of a `sessions_create` or `sessions_spawn` session comes from an agent: its provenance is `inter_session`, and `sourceSessionKey` names the agent.
- The viewer is the `hello-ok` `snapshot.presence` row whose `connectionId` equals `server.connId`, when its `user.identity` is a profile. Otherwise `users.self` answers. `FORBIDDEN` means the connection has no profile.

## Repository layout

```
oh-my-openclaw-macos/
├── Package.swift                 # swift test targets
├── project.yml                   # XcodeGen app and UI test targets
├── justfile
├── sgconfig.yml, rules/          # ast-grep layer rules
├── Sources/OhMyOpenClawCore/     # copied from iOS, same paths
├── App/
│   ├── AppModel.swift            # copied from iOS, same paths (OhMyOpenClawState)
│   ├── CredentialStore.swift     # copied from iOS, same paths (OhMyOpenClawState)
│   ├── GatewayProfiles.swift     # copied from iOS, same paths (OhMyOpenClawState)
│   ├── Platform/                 # Mac logic and system adapters (OhMyOpenClawPlatform)
│   ├── Views/                    # SwiftUI
│   └── OhMyOpenClawApp.swift
├── Tests/                        # Core, State, Platform suites
├── UITests/                      # demo smoke test
└── scripts/                      # copied Gateway fixture and its tests
```

- The first import commit is a verbatim copy and names the source commit. Shared files keep their iOS paths, so a fix in either repository can be ported with `git diff | git apply -3`.
- The app target compiles `App/` directly. Swift package targets expose the same files to `swift test`, as in the iOS repository.

## User interface

The main window has three columns: sidebar, timeline, and inspector.

### Sidebar

- Threads are grouped by project, with "No project" last.
- Each thread row shows:
  - its title
  - its state: working with elapsed time, needs approval, finished and unread, or error
  - for a running thread, a one-line narration of the current step
- A "Working" section lists every running thread. Idle threads older than the recent window collapse into "Settled".
- Search filters thread titles.
- A new-thread button sits on each project header.

### Timeline

- User messages are right-aligned bubbles. Assistant replies render as Markdown, with monospaced code blocks and copy.
- Each turn's tool activity collapses into "Worked for N s". Expanding it lists each tool call with its kind, a one-line summary, its state, and its duration. Expanding a call shows its output or diff, with added and removed lines colored.
- A running turn shows "Working for N s", a thinking indicator, and stop.
- Approval and question cards appear in the timeline. Exec commands are shown in monospace, with allow once, allow always, and deny.

### Shared sessions

Team members can join a session and send messages into it. The timeline shows who wrote what:

- **Other people's messages** sit on the left. Each one has an initials avatar and the sender's name.
  - The avatar color is the Control UI's hue: FNV-1a over the UTF-16 `senderId`, modulo 360, drawn as HSL(hue, 48%, 42%).
  - Channel senders appear by their channel name.
- **My messages** stay on the right, as before.
- **Agent openings** (a `sessions_create` or `sessions_spawn` task) sit on the left as the agent.
- **What counts as mine:** a row is mine only when its `senderIdentity` is the viewer's profile. Names, untyped ids, and channel ids are never compared with the viewer.
  - Rows without a sender stay on the right, including pending local sends.
  - With a profileless viewer, every row that has a sender belongs to someone else, because such a viewer's own sends carry none.
  - Until the viewer is known, the last viewer profile saved for that Gateway decides. If none is saved, every row stays on the right.
- **Single-user sessions** look exactly as before.
- **Not in v0.1:** profile photos, reply previews, "suggested by", and participant lists.

### Composer

- Multiline input. Return sends, and Shift-Return or Option-Return inserts a newline.
- Return never sends while the input method has marked text, so committing a Japanese conversion cannot send.
- Attachments come from the file picker, drag and drop, and paste.
- One menu selects the model and thinking level, shown as "<model> <level>".
- The composer also holds send and stop.

### Inspector

Toggled from the toolbar. It shows the project, branch and worktree, working directory, model, and run state of the selected thread.

### New thread

Choose a project. Choose "New worktree" or "Current checkout", as offered by `projects.checkoutOptions`. Choose a model. Send the first message, which creates the session.

### Connection and settings

- **Disconnected.** The timeline area shows the connection form: URL with token or password, or a pasted setup code. It also offers the local demo.
- **Cloudflare Access.** A Gateway published behind Cloudflare Access sends native clients to a login page. The form therefore takes an optional Access service token (Client ID and Client Secret), with either connection method.
  - The token is saved with the Gateway's credentials.
  - It is kept when pairing swaps in a device token, when only the Gateway token is entered again, and when a setup code pairs the same Gateway again.
  - It is sent as `CF-Access-Client-Id` and `CF-Access-Client-Secret`, and only to the Gateway origin.
  - The socket upgrade carries it today. The image-preview and attachment-download loaders also accept it, for when the transcript starts loading media.
  - Redirects are never followed.
  - The form asks for both fields together. Leaving both blank keeps the saved token.
  - An Access login redirect is reported as such.
- **Settings scene (Cmd-,).** Saved Gateways (add, rename, delete, switch, reconnect, disconnect), the notification switch, and the app version.

### Commands

- Cmd-N: new thread in the current project
- Cmd-.: stop the running turn
- Cmd-Shift-R: reconnect
- Cmd-Option-I: toggle the inspector

### Visual style

Standard macOS 27 sidebar, toolbar, and materials. Typography is compact, with monospace for commands, paths, and diffs.

## Changes to the copied shared layer

All changes are test-first:

1. **Client identity.** Done in milestone 1.
2. **Data protection keychain.** Done in milestone 1.
3. **Collapsed message notifications.** Done in milestone 1.
4. **Work log projection.**
   - Keep tool calls and results from history and live `tool` events as structured entries with id, kind, summary, arguments, state, timestamps, output, and diff.
   - Keep the existing display rules for assistant and user text.
5. **Roster activity.** Track `hasActiveRun`, `activeRunIds`, project, worktree, and last-activity time per session row for the sidebar, the inspector, and notifications.
6. **Background narration.** Subscribe to running threads with `mode: "narration"` and keep the latest narration line per session.
7. **Attention events.** Report when any thread's run completes or fails, and when an approval or question arrives or resolves.
8. **Sender attribution.**
   - User rows keep the sender the Gateway recorded, as an optional `ChatMessage.sender`.
   - The store keeps the last viewer profile id per Gateway, also optional.
   - A sender that cannot be read decodes as empty, so a saved store always loads.

## Mac components

- **Composer.** An `NSTextView` subclass wrapped in `NSViewRepresentable`. Key decisions live in a pure `ComposerKeyRouting` function with tests.
- **Connection supervisor.**
  - Keeps the connection open while the app runs, including after the main window closes.
  - Before system sleep it saves and disconnects, and after wake it reconnects.
  - It reconnects when the network path becomes satisfied.
  - Retries back off from 1 s to at most 30 s. It stops on pairing requests, authentication refusals, and user-initiated disconnects. A pure `ReconnectPolicy` holds the decisions.
- **Notification coordinator.**
  - Posts notifications for thread completion, failure, approvals, and questions when the app is not frontmost or the thread is not selected.
  - Clicking a notification opens the thread.
  - The Dock badge counts unseen finished threads plus pending approvals and questions.
  - A pure `NotificationPolicy` holds the decisions.
- **Attachment importer.** File picker, drag and drop, and paste become `ChatAttachment` values. Images are re-encoded as JPEG with ImageIO, and limits follow `hello-ok.policy.attachments`.

## Error handling

- `GatewayFailure` messages are shown inline. Messages whose delivery is uncertain stay on the device and can be retried.
- Connection state appears in the toolbar and in a banner above the timeline. A pairing request shows its request ID with the `openclaw devices list` and `openclaw devices approve <requestId>` steps.

## Testing and tooling

- **TDD with Swift Testing.** Every behavior change starts with a failing test. Mac logic lives in `OhMyOpenClawPlatform` as pure functions or state machines.
- **UI proof.** Each UI milestone runs the app against the demo or the loopback fixture and checks the result on screen. An XCUITest smoke test drives the demo.
- **Static checks.** ast-grep rules enforce layer boundaries: no AppKit, UIKit, or SwiftUI in the shared layer, and no UIKit in the app.
- **`justfile`.** Recipes for `gen`, `build`, `test`, `uitest`, `run`, `lint`, and `fixture`.
- **CI.** GitHub Actions on the `xcode-27` runner runs the fixture tests, `swift test`, the ast-grep scan, and an unsigned `xcodebuild` build.
- **Local signing.** Local runs can use ad-hoc signing for the demo. Real Gateways need automatic signing with the developer's team, because of the data protection keychain. The team ID stays out of the repository and is passed to `just run`.

## Milestones

Each milestone is one pull request that leaves the repository working.

1. **Shared layer** (merged in #1). Core, State, tests, fixture, Mac identity, data protection keychain, collapsed notification refresh, CI.
2. **App shell** (merged in #2).
   - XcodeGen project, sandbox entitlements, and icon.
   - Three-column window with a thread list and a read-only transcript.
   - Connection form, demo, and Settings with saved Gateways.
   - `justfile`, ast-grep rules, and the CI build.
3. **Timeline and work log**, in three pull requests:
   - **3a. Composer** (merged in #4): the IME-safe composer, attachments, the model menu, and approvals and questions.
   - **3b. Sender attribution:** shared-session rows on the left with name and avatar, the viewer identity, and the demo and fixture team threads.
   - **3c. Work log:** the work log projection and the work log timeline with folds.
4. **Threads and projects.** Project grouping, run state and elapsed time, Working and Settled sections, new thread with checkout choice, inspector, and narration.
5. **Connection supervisor.** Sleep and wake, network changes, and backoff.
6. **Notifications.** Attention events for every thread, notification policy, user notifications, Dock badge, and the Settings switch.

## Risks

- **IME.** Return handling must be verified with the Japanese input method on macOS 27. A pure key-routing function is not proof on its own.
- **Data protection keychain.** It requires a signed build with an application identifier, so unsigned CI builds cannot exercise it. Tests use the existing `GatewayConnectionAccess` seam.
- **Local network privacy.** LAN Gateways trigger the macOS local network permission. The app includes `NSLocalNetworkUsageDescription`.
- **Tool event shapes.** Tool event payloads vary by tool and runtime. The work log projection must fall back to a generic entry for unknown tools.
