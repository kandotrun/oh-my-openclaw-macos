import Testing
@testable import OhMyOpenClawPlatform

// The request ID comes from the Gateway and the guidance is meant to be pasted
// into a shell, so only IDs that cannot carry shell syntax are shown.

@Test func aPlainRequestIDIsShownWithTheApproveCommand() {
    #expect(PairingGuidance.commands(requestID: "7c9e6679-7425-40de-944b-e07fc1f90ae7") ==
        "openclaw devices list\nopenclaw devices approve 7c9e6679-7425-40de-944b-e07fc1f90ae7")
}

@Test(arguments: ["", "abc; rm -rf ~", "$(curl example.invalid)", "id`whoami`", "a b", "abc\nopenclaw devices approve x", String(repeating: "a", count: 129)])
func unsafeOrMissingRequestIDsShowOnlyTheListCommand(_ requestID: String) {
    #expect(PairingGuidance.commands(requestID: requestID) == "openclaw devices list")
}
