import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

@Suite("Connection form browser sign-in")
struct ConnectionFormSignInTests {
    private let gateway = URL(string: "wss://gateway.example.com/")!
    private let link = URL(string: "https://gateway.example.com/cdn-cgi/access/cli?token=synthetic-public-key")!

    /// A setup code leaves the form once it is sent, and a relaunch starts with an empty form; the
    /// Gateway that asked for the sign-in, or whose sign-in failed, is still the one to sign in to.
    @Test func anEmptyFormSignsInToTheGatewayTheSignInIsFor() {
        for state: CloudflareAccessSignInState in [.required(target: gateway, message: "m"), .failed(target: gateway, message: "m")] {
            #expect(ConnectionFormSignIn.start(formNamesGateway: false, signIn: state, connecting: false) == .stateTarget, "\(state)")
        }
    }

    @Test func aFormThatNamesAGatewaySignsInWithItsOwnInputs() {
        #expect(ConnectionFormSignIn.start(formNamesGateway: true, signIn: .idle, connecting: false) == .formInputs)
        #expect(ConnectionFormSignIn.start(formNamesGateway: true, signIn: .required(target: gateway, message: "m"), connecting: false) == .formInputs)
    }

    /// The form may have changed while the sign-in ran; trying it again repeats the sign-in that failed.
    @Test func tryingAFailedSignInAgainSignsInToTheGatewayItWasFor() {
        #expect(ConnectionFormSignIn.start(formNamesGateway: true, signIn: .failed(target: gateway, message: "m"), connecting: false) == .stateTarget)
    }

    @Test func anEmptyFormWithNoSignInToRepeatCannotStartOne() {
        #expect(ConnectionFormSignIn.start(formNamesGateway: false, signIn: .idle, connecting: false) == nil)
    }

    @Test func nothingStartsWhileAConnectionChangeOrASignInIsUnderWay() {
        #expect(ConnectionFormSignIn.start(formNamesGateway: true, signIn: .idle, connecting: true) == nil)
        #expect(ConnectionFormSignIn.start(formNamesGateway: false, signIn: .required(target: gateway, message: "m"), connecting: true) == nil)
        let running: [CloudflareAccessSignInState] = [
            .checking(target: gateway),
            .waitingForBrowser(target: gateway, link: link, opened: true, host: "gateway.example.com", team: "team.cloudflareaccess.com"),
        ]
        for state in running {
            #expect(ConnectionFormSignIn.start(formNamesGateway: true, signIn: state, connecting: false) == nil, "\(state)")
        }
    }
}
