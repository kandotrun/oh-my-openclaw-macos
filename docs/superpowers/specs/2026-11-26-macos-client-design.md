# Oh My OpenClaw for Mac — Design

Date: 2026-11-26
Status: approved for implementation

## Goal

A calm, chat-first, native macOS client for a personal OpenClaw Gateway, matching the scope and tone of the iOS client [oh-my-openclaw-ios](https://github.com/kandotrun/oh-my-openclaw-ios). It is an independent chat client. It hosts no AI service, manages no Gateway, and embeds no administration console.

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
| v0.1 scope | Parity with iOS v0.1 plus notifications. One main window. |
| UI language | Japanese, like the iOS client |

## Non-goals for v0.1

- Quick Chat (menu bar presence with a global shortcut)
- Multiple windows
- Command palette and find in conversation
- Bonjour discovery, one-click connection to a Gateway on the same Mac, TLS certificate pinning
- Custom dictation (macOS system dictation works in the composer) and QR scanning
- Node capabilities, Gateway installation or management, administration screens

## Protocol facts this design relies on

Checked against OpenClaw `main` at `b1d355f` (2026-11-26, release 2026.11.10):

- Operator clients negotiate protocol v4 exactly (`minProtocol` and `maxProtocol` are both 4).
- Requested scopes stay as in iOS: `operator.read`, `operator.write`, `operator.approvals`, `operator.questions`.
- Paired device metadata (platform, device family) is pinned. The Mac client therefore sends `platform: "macos"` and `deviceFamily: "Mac"` with its own device identity and pairs as a new device.
- Device proofs keep the v2 signature payload, which the official Swift clients also still use for compatibility.
- Loopback connections, including SSH port forwards, are silently approved on first pairing by default. LAN and Tailnet connections to the same host still require approval.
- The reference client reconnects with backoff from 1 s up to 30 s and never retries automatically after a pairing or authentication refusal.
- Under load, queued message notifications can collapse into one `sessions.changed` event whose top-level payload has `phase: "message"` and no `message`, `messageId`, or `messageSeq`. Clients refetch `chat.history` for the matching conversation. The iOS client at the copy source does not do this yet.

## Repository layout

```
oh-my-openclaw-macos/
├── Package.swift                 # swift test targets
├── project.yml                   # XcodeGen app target
├── justfile
├── Sources/OhMyOpenClawCore/     # copied from iOS, same paths
├── App/
│   ├── AppModel.swift            # copied from iOS, same paths (OhMyOpenClawState)
│   ├── CredentialStore.swift     # copied from iOS, same paths (OhMyOpenClawState)
│   ├── GatewayProfiles.swift     # copied from iOS, same paths (OhMyOpenClawState)
│   ├── Platform/                 # new: Mac logic and system adapters (OhMyOpenClawPlatform)
│   ├── Views/                    # new: SwiftUI
│   └── OhMyOpenClawApp.swift
├── Tests/
│   ├── OhMyOpenClawCoreTests/    # copied
│   ├── OhMyOpenClawStateTests/   # copied, without the iOS layout tests
│   └── OhMyOpenClawPlatformTests/
├── UITests/                      # demo smoke test
└── scripts/                      # copied Gateway fixture and its tests
```

- The first import commit is a verbatim copy and names the source commit. Shared files keep their iOS paths, so a fix in either repository can be ported with `git diff | git apply -3`.
- History starts fresh. `README.md` and `THIRD_PARTY_NOTICES.md` record the provenance.
- Not copied: iOS views, iOS input (dictation, QR scanning, UIKit image conversion), and `ChatLayout` with its tests.
- The app target compiles `App/` directly. Swift package targets expose the same files to `swift test`, as in the iOS repository.

## Changes to the copied shared layer

All changes are test-first. The rest of `AppModel` stays unchanged so later iOS fixes remain easy to port.

1. **Client identity.** Display name, version, platform, and device family move out of `GatewayClient.connect` into an injected value. The Mac app sends `Oh My OpenClaw`, its bundle version, `macos`, and `Mac`.
2. **Keychain.** Credential items use the data protection keychain (`kSecUseDataProtectionKeychain`) with the service `run.kandot.oh-my-openclaw.mac.credentials`. This matches iOS semantics and avoids legacy keychain access prompts.
3. **Collapsed message notifications.** A `sessions.changed` event with top-level `phase: "message"` and no `message`, `messageId`, or `messageSeq` schedules a history refresh when it targets the selected conversation.
4. **Attention events (notifications milestone).** `AppModel` reports when the selected conversation's reply completes or fails, and when an approval or question arrives or resolves.

## Mac components

### Composer

- An `NSTextView` subclass wrapped in `NSViewRepresentable`.
  - Return sends.
  - Shift-Return and Option-Return insert a newline.
  - Return never sends while the input method has marked text (`hasMarkedText()`), so committing a Japanese conversion cannot send a message.
- Grows from one to eight lines and shows a placeholder.
- Pasted images and file URLs become attachments.
- Key decisions live in a pure `ComposerKeyRouting` function with its own tests.

### Connection supervisor

- Keeps the connection open while the app runs, including after the main window closes.
- Saves and disconnects before system sleep (`NSWorkspace.willSleepNotification`), and reconnects after wake.
- Reconnects when the network path becomes satisfied (`NWPathMonitor`).
- Retries failed connections with backoff from 1 s, doubling to at most 30 s.
- Stops on pairing requests, authentication refusals, and user-initiated disconnects.
- Decisions live in a pure `ReconnectPolicy` with tests. The supervisor calls existing `AppModel` methods (`foreground()`, `background()`, `retryConnection()`).

### Notification coordinator

- Posts user notifications only while the app is not frontmost: reply completed, reply failed, approval requested, question requested.
- Clicking a notification activates the app and opens that conversation.
- The Dock badge counts unseen replies plus pending approvals and questions. Opening the conversation clears its count.
- Authorization is requested at the first send, and Settings has a switch to turn notifications off.
- Decisions live in a pure `NotificationPolicy` with tests.

### Attachment importer

- File picker, drag and drop onto the conversation, and paste all produce `ChatAttachment` values.
- Images are re-encoded as JPEG with ImageIO.
- Size limits follow `hello-ok.policy.attachments`, as in iOS.

## User interface

- **Main window.** One `Window` scene. Closing it keeps the app running, and clicking the Dock icon reopens it.
- **`NavigationSplitView` sidebar.** Agent name, Gateway switcher, main chat, side chats with a "+" button, and search.
- **Conversation.**
  - Streaming assistant replies, tool activity, and stop.
  - Markdown with code copy.
  - Approval and question cards.
  - Attachment previews through Quick Look, and older-history paging.
- **Composer area.** Model and thinking-level menus, attach, and send or stop.
- **When disconnected.** The conversation area shows the connection form: URL with token or password, or a pasted setup code. It also offers the local demo.
- **Settings scene (Cmd-,).**
  - Saved Gateways: add, rename, delete, switch, reconnect, disconnect.
  - Notification switch and app version.
- **Commands.** Cmd-N opens a new side chat, Cmd-. stops the reply, Cmd-Shift-R reconnects.
- **Visual style.** Standard macOS 27 sidebar, toolbar, and materials, with minimal custom styling. The tone is the same quiet, chat-first style as iOS.

## Error handling

- `GatewayFailure` messages are shown as in iOS. Messages whose delivery is uncertain stay on the device and can be retried.
- Connection state appears in the toolbar and in a banner above the conversation. A pairing request shows its request ID with the `openclaw devices list` and `openclaw devices approve <requestId>` steps.
- Keychain failures use Mac wording.

## Testing and tooling

- **TDD with Swift Testing.**
  - The copied Core and State suites must pass first.
  - Every behavior change starts with a failing test.
  - Mac logic lives in `OhMyOpenClawPlatform` and is tested as pure functions or state machines.
- **UI smoke test.** An XCUITest connects to the demo, sends a message, and sees a reply. It runs locally through `just uitest`.
- **Static checks.** ast-grep rules enforce layer boundaries: no AppKit, UIKit, or SwiftUI imports in the shared layer, and no iOS-only APIs in the app.
- **`justfile` recipes.** `gen`, `build`, `test`, `uitest`, `run`, `lint`, `fixture`.
- **CI.** GitHub Actions on the `xcode-27` runner runs the Python fixture tests, `swift test`, and an unsigned `xcodebuild` build.
- **Local signing.** Local runs use automatic signing with the developer's own team. The data protection keychain and App Sandbox need a real signature. The team ID stays out of the repository and is passed to `just run`.

## Milestones

Each milestone is one pull request that leaves the repository working.

1. **Shared layer.** Import Core, State, their tests, and the fixture. Add client identity, the data protection keychain, and the collapsed notification refresh. Add CI for the shared layer.
2. **App skeleton.** XcodeGen project, sandbox entitlements, icon, main window with sidebar, connection form, demo, `justfile`, ast-grep rules, and CI build.
3. **Conversation and composer.** Transcript, Markdown, attachments, approvals and questions, and the IME-safe composer.
4. **Settings and commands.** Saved Gateway management, menu commands, connection banner, and pairing guidance.
5. **Connection supervisor.** Sleep and wake, network changes, and backoff.
6. **Notifications.** Attention events, notification policy, user notifications, Dock badge, and Settings switch.

## Risks

- **IME.** Return handling must be verified with the Japanese input method on macOS 27. A pure key-routing function is not proof on its own.
- **Data protection keychain.** It requires a signed build with an application identifier, so unsigned CI builds cannot exercise it. Tests use the existing `GatewayConnectionAccess` seam.
- **Local network privacy.** LAN Gateways trigger the macOS local network permission. The app includes `NSLocalNetworkUsageDescription`. Loopback connections should not need it; verify on device.
