default:
    @just --list

# Run the Gateway fixture tests and every Swift test suite.
test:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    swift test

# Start the synthetic loopback Gateway fixture for local development.
fixture port="9876":
    python3 scripts/gateway-fixture.py --port {{port}}
