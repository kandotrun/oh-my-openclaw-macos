# Milestone 1: Shared Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the iOS client's Gateway transport and conversation state into this repository, adapt them for macOS, and run their tests in CI.

**Architecture:** The first commit copies the shared files verbatim from `kandotrun/oh-my-openclaw-ios@e9a5515`, keeping their iOS paths. Later commits make three test-first changes:

- an injectable client identity that sends `macos` and `Mac`
- data protection keychain items under a Mac service name
- a history refresh for collapsed `sessions.changed` message notifications

**Tech Stack:** Swift 6.4 package (`swift-tools-version: 6.4`, macOS 27), Swift Testing, Python 3 standard library fixture, GitHub Actions `xcode-27` runner.

**Spec:** [docs/superpowers/specs/2026-11-26-macos-client-design.md](../specs/2026-11-26-macos-client-design.md)

---

## File map

| File | Responsibility |
| --- | --- |
| `Package.swift` | `OhMyOpenClawCore` and `OhMyOpenClawState` targets and their tests |
| `Sources/OhMyOpenClawCore/*` | Copied transport, device proofs, wire values, conversation reducer |
| `Sources/OhMyOpenClawCore/GatewayClientIdentity.swift` | New: client display name, version, platform, device family |
| `App/AppModel.swift`, `App/CredentialStore.swift`, `App/GatewayProfiles.swift` | Copied conversation state, Keychain, saved Gateways |
| `Tests/OhMyOpenClawCoreTests/*`, `Tests/OhMyOpenClawStateTests/*` | Copied suites, plus `CredentialStoreTests.swift` and `CollapsedMessageRefreshTests.swift` |
| `scripts/gateway-fixture.py`, `scripts/test_gateway_fixture.py` | Copied loopback fixture; now also asserts the Mac client identity |
| `THIRD_PARTY_NOTICES.md` | Copied OpenClaw MIT notice |
| `justfile` | `test` and `fixture` recipes |
| `.github/workflows/ci.yml` | Shared-layer CI job |

### Task 1: Verbatim import

**Files:** all copied files listed above, plus a new `Package.swift`.

- [ ] **Step 1: Copy the files from the source commit**

```bash
SRC=/path/to/oh-my-openclaw-ios   # a clone that contains e9a5515823c56473958fcd2047ca41754747cf8b
git -C "$SRC" archive e9a5515823c56473958fcd2047ca41754747cf8b \
  Sources/OhMyOpenClawCore App/AppModel.swift App/CredentialStore.swift App/GatewayProfiles.swift \
  Tests/OhMyOpenClawCoreTests Tests/OhMyOpenClawStateTests \
  scripts/gateway-fixture.py scripts/test_gateway_fixture.py THIRD_PARTY_NOTICES.md | tar -x
rm Tests/OhMyOpenClawStateTests/ChatLayoutTests.swift   # covers the iOS-only drawer layout
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OhMyOpenClaw",
    platforms: [.macOS(.v27)],
    products: [.library(name: "OhMyOpenClawCore", targets: ["OhMyOpenClawCore"])],
    targets: [
        .target(name: "OhMyOpenClawCore"),
        // The app target compiles App/ directly; this target exposes the same files to swift test.
        .target(name: "OhMyOpenClawState", dependencies: ["OhMyOpenClawCore"], path: "App",
                sources: ["AppModel.swift", "CredentialStore.swift", "GatewayProfiles.swift"]),
        .testTarget(name: "OhMyOpenClawCoreTests", dependencies: ["OhMyOpenClawCore"]),
        .testTarget(name: "OhMyOpenClawStateTests", dependencies: ["OhMyOpenClawState", "OhMyOpenClawCore"]),
    ]
)
```

- [ ] **Step 3: Run the imported suites**

Run: `python3 -m unittest discover -s scripts -p 'test_*.py' && swift test`
Expected: 2 Python tests pass; `Test run with 66 tests` (Core) and `Test run with 54 tests` (State) pass.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources App Tests scripts THIRD_PARTY_NOTICES.md
git commit -m "chore: import the shared layer from oh-my-openclaw-ios@e9a5515"
```

### Task 2: Mac client identity

**Files:**
- Create: `Sources/OhMyOpenClawCore/GatewayClientIdentity.swift`
- Modify: `Sources/OhMyOpenClawCore/GatewayClient.swift` (init and the `client` object in `establishConnection`)
- Modify: `App/GatewayProfiles.swift` (`GatewayConnectionAccess.live`)
- Test: `scripts/gateway-fixture.py` (connect assertions), exercised by `GatewayIntegrationTests`

- [ ] **Step 1: Write the failing contract check** in the fixture's `connect` branch, after the `client.mode` assertion:

```python
            assert params["client"]["platform"] == "macos" and params["client"]["deviceFamily"] == "Mac"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter GatewayIntegrationTests`
Expected: FAIL. The fixture rejects the `ios` / `iPhone` client and closes the socket, so `connect()` throws.

- [ ] **Step 3: Implement the identity**

`Sources/OhMyOpenClawCore/GatewayClientIdentity.swift`:

```swift
import Foundation

/// How this app describes itself in `connect`. Paired device metadata is pinned
/// by the Gateway, so the Mac client never reuses the iOS platform values.
public struct GatewayClientIdentity: Sendable, Equatable {
    public var displayName: String
    public var version: String
    public var platform: String
    public var deviceFamily: String

    public init(displayName: String = "Oh My OpenClaw", version: String = "0.1.0", platform: String = "macos", deviceFamily: String = "Mac") {
        self.displayName = displayName; self.version = version; self.platform = platform; self.deviceFamily = deviceFamily
    }
}
```

In `GatewayClient`, store `private let clientIdentity: GatewayClientIdentity`. Add an initializer parameter `clientIdentity: GatewayClientIdentity = GatewayClientIdentity()` and use it in the `client` object:

```swift
"id": .string("gateway-client"), "displayName": .string(clientIdentity.displayName),
"version": .string(clientIdentity.version), "platform": .string(clientIdentity.platform), "deviceFamily": .string(clientIdentity.deviceFamily),
```

In `GatewayConnectionAccess.live.makeService`, pass the bundle version:

```swift
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? GatewayClientIdentity().version
return GatewayClient(endpoint: url, credentials: credentials, identity: identity, clientIdentity: GatewayClientIdentity(version: version))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: PASS, with the loopback contract test included.

- [ ] **Step 5: Commit** with `feat: identify as a Mac client`.

### Task 3: Data protection keychain

**Files:**
- Modify: `App/CredentialStore.swift`
- Test: `Tests/OhMyOpenClawStateTests/CredentialStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Security
import Testing
@testable import OhMyOpenClawState

@Test func credentialItemsUseTheDataProtectionKeychainWithTheMacService() {
    let query = CredentialStore.itemQuery("gateway:example")
    #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(query[kSecAttrService as String] as? String == "run.kandot.oh-my-openclaw.mac.credentials")
    #expect(query[kSecAttrAccount as String] as? String == "gateway:example")
    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CredentialStoreTests`
Expected: FAIL to compile, because `itemQuery` is private.

- [ ] **Step 3: Implement**

Make `service` and `itemQuery` internal, change the service to `run.kandot.oh-my-openclaw.mac.credentials`, and add `kSecUseDataProtectionKeychain as String: true` to the query. Replace the iOS unlock wording in `CredentialError` with `"接続情報を\(operation)できませんでした（\(status)）。キーチェーンへのアクセスを確認して、もう一度お試しください。"`.

- [ ] **Step 4: Run the tests to verify they pass.** Run `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** with `feat: store credentials in the data protection keychain`.

### Task 4: Refetch history after collapsed message notifications

**Files:**
- Modify: `App/AppModel.swift` (`handle(_:)`, `sessions.changed` branch)
- Test: `Tests/OhMyOpenClawStateTests/CollapsedMessageRefreshTests.swift`

**Contract:** OpenClaw `docs/gateway/protocol/rpc-bootstrap-and-events.md`, and the Control UI's `ui/src/pages/chat/chat-state-events.ts`. When the top-level payload has `phase: "message"` and no `message`, `messageId`, or `messageSeq` key, and it targets the selected chat, refetch history.

- [ ] **Step 1: Write the failing tests.** The fake Gateway records `chat.history` keys and emits `sessions.changed` events.

1. A collapsed notification for the selected chat triggers one more `chat.history` read.
2. A notification with `messageId` does not trigger one.
3. A collapsed notification for an unselected chat does not trigger one.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CollapsedMessageRefreshTests`
Expected: the first test FAILS, because no second history read happens. The other two pass.

- [ ] **Step 3: Implement.** At the end of the `sessions.changed` branch, before `return`:

```swift
if event.name == "sessions.changed", Self.isCollapsedMessageNotification(payload),
   let target = selectedSession, Self.notification(payload, row: row, targets: target) {
    pendingHistoryRefresh.insert(target.id); scheduleQuietRefresh()
}
```

Add these helpers:

```swift
/// Collapsed notifications cannot name individual messages; only a history read recovers them.
nonisolated static func isCollapsedMessageNotification(_ payload: JSONValue) -> Bool {
    guard payload["phase"].stringValue == "message", let fields = payload.objectValue else { return false }
    return fields["message"] == nil && fields["messageId"] == nil && fields["messageSeq"] == nil
}

nonisolated static func notification(_ payload: JSONValue, row: JSONValue, targets target: ChatSession) -> Bool {
    guard let key = payload["sessionKey"].stringValue ?? payload["key"].stringValue ?? row["key"].stringValue ?? row["sessionKey"].stringValue,
          key == target.key else { return false }
    let agent = payload["agentId"].stringValue ?? row["agentId"].stringValue
    return agent == nil || agent == target.agentID
}
```

- [ ] **Step 4: Run the tests to verify they pass.** Run `swift test`. Expected: PASS.

- [ ] **Step 5: Commit** with `fix: refetch history after collapsed message notifications`.

### Task 5: Tooling, CI, and documentation

**Files:**
- Create: `justfile`
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

- [ ] **Step 1: `justfile`**

```just
default:
    @just --list

# Run the Gateway fixture tests and every Swift test suite.
test:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    swift test

# Start the synthetic loopback Gateway fixture for local development.
fixture port="9876":
    python3 scripts/gateway-fixture.py --port {{port}}
```

- [ ] **Step 2: CI**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  shared:
    name: Shared layer
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v5
      - run: xcodebuild -version && swift --version
      - run: python3 -m unittest discover -s scripts -p 'test_*.py'
      - run: swift test
```

- [ ] **Step 3: README.** Add the provenance (copy source commit and the porting rule), the test commands, and the scope of the fixture.

- [ ] **Step 4: Verify.** Run `just test`. Expected: PASS.

- [ ] **Step 5: Commit** with `ci: run the shared layer tests`.
