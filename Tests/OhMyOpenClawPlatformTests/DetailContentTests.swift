import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

@Test func pairingAboveCachedThreadsKeepsTheApprovalGuidanceVisible() {
    #expect(DetailContent.pairingBanner(hasSessions: true, state: .pairing(requestID: "req-1", message: "承認してください")) ==
        PairingBanner(requestID: "req-1", message: "承認してください"))
}

@Test func theConnectionFormShowsItsOwnPairingGuidance() {
    #expect(DetailContent.pairingBanner(hasSessions: false, state: .pairing(requestID: "req-1", message: "m")) == nil)
}

@Test func otherConnectionStatesShowNoPairingBanner() {
    #expect(DetailContent.pairingBanner(hasSessions: true, state: .connected) == nil)
    #expect(DetailContent.pairingBanner(hasSessions: true, state: .failed("x")) == nil)
}
