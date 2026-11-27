import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawPlatform

private let hana = MessageSender(identityKind: "profile", identityID: "demo-hana", id: "demo-hana", name: "佐藤 花子")
private let me = MessageSender(identityKind: "profile", identityID: "p1", id: "p1", name: "Me")
private let channel = MessageSender(identityKind: "observation", identityID: "42", id: "42", name: "Taro")
private let untypedMe = MessageSender(id: "p1", name: "Me")
private let agentOpening = MessageSender(id: "agent:main", agentID: "main")

private func user(_ sender: MessageSender?) -> ChatMessage { ChatMessage(role: .user, text: "hi", sender: sender) }

@Suite("Sender style")
struct SenderStyleTests {
    @Test func hashMatchesTheControlUI() {
        #expect(SenderStyle.fnv1a("a") == 3_826_002_220)
        #expect(SenderStyle.fnv1a("") == 2_166_136_261)
        #expect(SenderStyle.hue(for: hana) == 179)
        #expect(SenderStyle.hue(for: MessageSender(name: "佐藤 花子")) == 58)
    }

    @Test func avatarColorIsTheControlUIsHSL() {
        func close(_ color: (red: Double, green: Double, blue: Double), _ expected: (Double, Double, Double)) -> Bool {
            abs(color.red - expected.0) < 0.0001 && abs(color.green - expected.1) < 0.0001 && abs(color.blue - expected.2) < 0.0001
        }
        #expect(close(SenderStyle.avatarRGB(hue: 0), (0.6216, 0.2184, 0.2184)))
        #expect(close(SenderStyle.avatarRGB(hue: 179), (0.2184, 0.6216, 0.6149)))
        #expect(close(SenderStyle.avatarRGB(hue: 300), (0.6216, 0.2184, 0.6216)))
    }

    @Test func initialsTakeTheFirstLetterOfTwoWords() {
        #expect(SenderStyle.initials("佐藤 花子") == "佐花")
        #expect(SenderStyle.initials("Alexandria Montgomery-Winter") == "AM")
        #expect(SenderStyle.initials("alice") == "A")
        #expect(SenderStyle.initials("  ") == "?")
        #expect(SenderStyle.initials(nil) == "?")
    }

    @Test func myProfileIsMineAndEveryOtherSenderIsAPeer() {
        let viewer = ViewerIdentity.profile("p1")
        #expect(SenderStyle.attribution(of: user(me), viewer: viewer) == .own)
        #expect(SenderStyle.attribution(of: user(nil), viewer: viewer) == .own)
        #expect(SenderStyle.attribution(of: user(hana), viewer: viewer) == .peer(PeerChrome(name: "佐藤 花子", initials: "佐花", hue: 179)))
        guard case .peer = SenderStyle.attribution(of: user(channel), viewer: viewer) else { Issue.record("channel sender"); return }
        // Only a typed profile can be mine; an untyped id that equals mine is someone else.
        guard case .peer = SenderStyle.attribution(of: user(untypedMe), viewer: viewer) else { Issue.record("untyped id"); return }
    }

    @Test func aProfilelessViewerSendsWithoutASenderSoEverySenderIsSomeoneElse() {
        guard case .peer = SenderStyle.attribution(of: user(me), viewer: .profileless) else { Issue.record("typed sender"); return }
        #expect(SenderStyle.attribution(of: user(nil), viewer: .profileless) == .own)
    }

    @Test func anUnresolvedViewerKeepsEveryRowOnTheRight() {
        #expect(SenderStyle.attribution(of: user(hana), viewer: .unresolved) == .own)
    }

    @Test func agentOpeningsAndRepliesAreNeverMine() {
        for viewer in [ViewerIdentity.unresolved, .profileless, .profile("p1")] {
            #expect(SenderStyle.attribution(of: user(agentOpening), viewer: viewer) == .agent("main"))
            #expect(SenderStyle.attribution(of: ChatMessage(role: .assistant, text: "done"), viewer: viewer) == .agentReply)
        }
    }

    @Test func aPeerWithoutANameIsStillShown() {
        let chrome = SenderStyle.attribution(of: user(MessageSender(identityKind: "profile", identityID: "p9")), viewer: .profile("p1"))
        #expect(chrome == .peer(PeerChrome(name: "参加者", initials: "?", hue: Int(SenderStyle.fnv1a("") % 360))))
    }
}
