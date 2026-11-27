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

# Run the UI smoke tests against the demo and one loopback fixture per mode:
# pairing-only, an open question, a shared thread, and Cloudflare Access.
uitest: gen
    #!/usr/bin/env bash
    set -euo pipefail
    modes=(pairing question shared access); pids=(); files=(); environment=()
    trap 'kill "${pids[@]}" 2>/dev/null || true; rm -f "${files[@]}"' EXIT
    for mode in "${modes[@]}"; do
        file="$(mktemp)"; files+=("$file")
        python3 scripts/gateway-fixture.py "--$mode" > "$file" &
        pids+=("$!")
    done
    for index in "${!modes[@]}"; do
        file="${files[$index]}"
        for _ in $(seq 50); do [ -s "$file" ] && break; sleep 0.1; done
        port="$(head -1 "$file")"
        if [ -z "$port" ]; then echo "The ${modes[$index]} Gateway fixture did not publish a port." >&2; exit 1; fi
        name="$(printf '%s' "${modes[$index]}" | tr '[:lower:]' '[:upper:]')"
        environment+=("TEST_RUNNER_OHMYOPENCLAW_${name}_FIXTURE=ws://127.0.0.1:$port")
    done
    env "${environment[@]}" {{xcodebuild}} test

# Start the synthetic loopback Gateway fixture for local development.
fixture port="9876":
    python3 scripts/gateway-fixture.py --port {{port}}
