import Foundation
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

private let gateway = URL(string: "wss://gateway.example.com/")!

@Test func aSignInAskedForOrUnderWayStaysVisibleOverCachedThreads() {
    let link = URL(string: "https://gateway.example.com/cdn-cgi/access/cli?token=synthetic-public-key")!
    let shown: [CloudflareAccessSignInState] = [
        .required(target: gateway, message: "サインインしてください"),
        .checking(target: gateway),
        .waitingForBrowser(target: gateway, link: link, opened: false, host: "gateway.example.com", team: "team.cloudflareaccess.com"),
        .failed(target: gateway, message: "サインインできませんでした"),
    ]
    for state in shown {
        #expect(DetailContent.accessBanner(hasSessions: true, signIn: state) == AccessBanner(target: gateway, signIn: state), "\(state)")
    }
}

@Test func theConnectionFormShowsItsOwnSignIn() {
    #expect(DetailContent.accessBanner(hasSessions: false, signIn: .required(target: gateway, message: "m")) == nil)
    #expect(DetailContent.accessBanner(hasSessions: false, signIn: .checking(target: gateway)) == nil)
}

@Test func withoutASignInThereIsNoAccessBanner() {
    #expect(DetailContent.accessBanner(hasSessions: true, signIn: .idle) == nil)
}
