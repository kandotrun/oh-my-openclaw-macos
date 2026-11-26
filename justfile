xcodebuild := "xcodebuild -project OhMyOpenClaw.xcodeproj -scheme OhMyOpenClaw -destination 'platform=macOS' -derivedDataPath build"

default:
    @just --list

# Run the Gateway fixture tests and every Swift test suite.
test:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    swift test

# Check the ast-grep layer rules and their tests.
lint:
    ast-grep test --skip-snapshot-tests
    ast-grep scan --error

# Generate the Xcode project from project.yml.
gen:
    xcodegen generate

# Build the app without signing.
build: gen
    {{xcodebuild}} CODE_SIGNING_ALLOWED=NO build

# Build and open the app. Without a team it is signed to run locally, which suits the demo.
# Pass your Apple Development team ID to use the Keychain with a real Gateway.
run team="": gen
    {{xcodebuild}} {{ if team == "" { "" } else { "DEVELOPMENT_TEAM=" + team + " CODE_SIGN_IDENTITY='Apple Development'" } }} build
    open "build/Build/Products/Debug/Oh My OpenClaw.app"

# Run the UI smoke tests against the demo and a pairing-only loopback fixture.
uitest: gen
    #!/usr/bin/env bash
    set -euo pipefail
    port_file="$(mktemp)"
    python3 scripts/gateway-fixture.py --pairing > "$port_file" &
    fixture=$!
    trap 'kill "$fixture" 2>/dev/null || true; rm -f "$port_file"' EXIT
    for _ in $(seq 50); do [ -s "$port_file" ] && break; sleep 0.1; done
    port="$(head -1 "$port_file")"
    if [ -z "$port" ]; then echo "The pairing fixture did not publish a port." >&2; exit 1; fi
    TEST_RUNNER_OHMYOPENCLAW_PAIRING_FIXTURE="ws://127.0.0.1:$port" {{xcodebuild}} test

# Start the synthetic loopback Gateway fixture for local development.
fixture port="9876":
    python3 scripts/gateway-fixture.py --port {{port}}
