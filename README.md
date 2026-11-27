# Oh My OpenClaw for Mac

A native macOS client for your own OpenClaw Gateway, and the Mac counterpart of [Oh My OpenClaw for iOS](https://github.com/kandotrun/oh-my-openclaw-ios).
It is an independent client, without a hosted AI service, Gateway management, or an embedded administration console.

The app is in development.
The approved design is in [docs/superpowers/specs/2026-11-26-macos-client-design.md](docs/superpowers/specs/2026-11-26-macos-client-design.md).

## Build and run

Requirements: macOS 27, Xcode 27 with Swift 6.4, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [just](https://github.com/casey/just), and [ast-grep](https://ast-grep.github.io).

```sh
brew install xcodegen just ast-grep
just run                     # signed to run locally; suits the built-in demo
just run <TEAM_ID>           # signed with your Apple Development team; needed for real Gateways
```

The project specification is `project.yml`; the generated `OhMyOpenClaw.xcodeproj` is intentionally ignored.
The app is sandboxed and stores credentials in the data protection keychain, which requires a build signed with a development team.
A build signed to run locally can open the demo but cannot save Gateway credentials.
The demo uses synthetic conversations and never contacts a Gateway or AI provider.

## Shared layer

`Sources/OhMyOpenClawCore` owns the actor-based WebSocket transport, device proofs, wire values, and the durable conversation reducer.
`App/AppModel.swift`, `App/CredentialStore.swift`, and `App/GatewayProfiles.swift` own conversation state, Keychain access, and saved Gateways.

These files were copied from [oh-my-openclaw-ios](https://github.com/kandotrun/oh-my-openclaw-ios) at [`e9a5515`](https://github.com/kandotrun/oh-my-openclaw-ios/tree/e9a5515823c56473958fcd2047ca41754747cf8b), and the two repositories now evolve independently.
Shared files keep their iOS paths, so a fix in either repository can be ported with `git diff | git apply -3`.
Mac-specific changes so far:

- The client identifies itself with platform `macos` and device family `Mac`.
- Credentials use the data protection keychain under a Mac service name.
- Collapsed `sessions.changed` message notifications refetch the selected conversation.
- User rows keep the sender the Gateway recorded, and the store remembers the viewer's profile per Gateway, so shared sessions show who wrote each message.
- Credentials can hold a Cloudflare Access service token, which is sent to Gateways published behind Cloudflare Access.

The client targets Gateway protocol v4, checked against OpenClaw `main` at [`b1d355f`](https://github.com/openclaw/openclaw/tree/b1d355fcc9fcf91a4514c2612ce7b33211c710b6) (release 2026.11.10).
Adapted OpenClaw authentication code retains its upstream MIT notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Tests

```sh
just test     # Python fixture tests and swift test
just lint     # ast-grep layer rules and their tests
just uitest   # XCUITest smoke test against the demo
```

The Swift suites cover device proofs, safe endpoints and setup codes, conversation state, and a real loopback WebSocket exchange with the synthetic Python fixture.
That fixture proves client transport and framing behavior. It is not an OpenClaw instance or evidence of production connectivity.
It binds only to `127.0.0.1`, needs only Python 3's standard library, and uses synthetic credentials.
