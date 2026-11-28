import Foundation
import Testing
import OhMyOpenClawCore

@Suite("Cloudflare Access sign-in state")
struct CloudflareAccessSignInStateTests {
    private let gateway = URL(string: "wss://gateway.example.com/")!
    private let link = URL(string: "https://gateway.example.com/cdn-cgi/access/cli?token=synthetic")!
    private var waiting: CloudflareAccessSignInState {
        .waitingForBrowser(target: gateway, link: link, opened: false, host: "gateway.example.com", team: "team.cloudflareaccess.com")
    }

    @Test func everyStateButIdleNamesTheGatewayItIsFor() {
        #expect(CloudflareAccessSignInState.idle.target == nil)
        let named: [CloudflareAccessSignInState] = [
            .required(target: gateway, message: "m"), .checking(target: gateway), waiting, .failed(target: gateway, message: "m"),
        ]
        for state in named { #expect(state.target == gateway, "\(state)") }
    }

    @Test func aSignInRunsFromTheCheckUntilItsSessionIsSaved() {
        #expect(CloudflareAccessSignInState.checking(target: gateway).isRunning)
        #expect(waiting.isRunning)
        let settled: [CloudflareAccessSignInState] = [.idle, .required(target: gateway, message: "m"), .failed(target: gateway, message: "m")]
        for state in settled { #expect(!state.isRunning, "\(state)") }
    }
}
