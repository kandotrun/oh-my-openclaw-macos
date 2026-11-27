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

# Run the UI smoke tests against the demo and two loopback fixtures: pairing-only and one open question.
uitest: gen
    #!/usr/bin/env bash
    set -euo pipefail
    pairing_file="$(mktemp)"; question_file="$(mktemp)"
    python3 scripts/gateway-fixture.py --pairing > "$pairing_file" &
    pairing=$!
    python3 scripts/gateway-fixture.py --question > "$question_file" &
    question=$!
    trap 'kill "$pairing" "$question" 2>/dev/null || true; rm -f "$pairing_file" "$question_file"' EXIT
    for _ in $(seq 50); do [ -s "$pairing_file" ] && [ -s "$question_file" ] && break; sleep 0.1; done
    pairing_port="$(head -1 "$pairing_file")"; question_port="$(head -1 "$question_file")"
    if [ -z "$pairing_port" ] || [ -z "$question_port" ]; then echo "A Gateway fixture did not publish a port." >&2; exit 1; fi
    TEST_RUNNER_OHMYOPENCLAW_PAIRING_FIXTURE="ws://127.0.0.1:$pairing_port" \
    TEST_RUNNER_OHMYOPENCLAW_QUESTION_FIXTURE="ws://127.0.0.1:$question_port" {{xcodebuild}} test

# Start the synthetic loopback Gateway fixture for local development.
fixture port="9876":
    python3 scripts/gateway-fixture.py --port {{port}}
