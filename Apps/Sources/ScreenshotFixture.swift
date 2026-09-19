import Foundation
import TotemKit

/// Seeds the app with a made-up account for marketing screenshots, selected by
/// `--screenshot friends|chat|voice|four`. Debug builds only.
enum ScreenshotFixture {
    enum Scene: String {
        case friends, chat, voice, four
    }

    #if DEBUG
    static let scene: Scene? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--screenshot"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return Scene(rawValue: arguments[index + 1])
    }()

    /// The conversation a chat scene opens on launch.
    static var openConversation: UUID? {
        guard let scene, scene != .friends else { return nil }
        return groupID
    }

    private static func user(_ number: Int, _ handle: String, _ avatar: Avatar?) -> User {
        User(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
             handle: handle, avatar: avatar)
    }

    private static let me = user(1, "sk8rboi", Avatar(skinTone: 0.35, hair: 0.2))

    private static let bobaboy = user(2, "BoBaBoY", Avatar(skinTone: 0.6, hair: 0.85, glasses: true))
    private static let pixiedust = user(3, "pixiedust", Avatar(skinTone: 0.1, hair: 0.05))
    private static let surfnturf = user(4, "surfnturf88", Avatar(skinTone: 0.8, hair: 0.65, cigarette: true))

    private static let online: [User] = [
        bobaboy, pixiedust, surfnturf,
        user(5, "xXdarkangelXx", Avatar(skinTone: 0.2, hair: 0.75, glasses: true, cigarette: true)),
    ]
    private static let away: [(User, String)] = [
        (user(8, "punkrawker", Avatar(skinTone: 0.0, hair: 0.95)), "brb food"),
        (user(9, "starz4eva", Avatar(skinTone: 0.7, hair: 0.3, glasses: true)), "at practice, back @ 6"),
    ]
    private static let idle: [User] = []
    private static let offline: [User] = [
        user(6, "th3matrix", Avatar(skinTone: 1.0, hair: 0.8)),
        user(10, "n0scope", Avatar(skinTone: 0.5, hair: 0.5, cigarette: true)),
        user(7, "lilmisssunshine", Avatar(skinTone: 0.45, hair: 0.1, glasses: true)),
        user(11, "cuddlebug", Avatar(skinTone: 0.25, hair: 0.4)),
        user(12, "ragingbull22", nil),
        user(13, "spaceCadet_x", Avatar(skinTone: 0.9, hair: 0.0, glasses: true)),
        user(14, "MoonPie", Avatar(skinTone: 0.15, hair: 0.55)),
    ]

    private static let groupMembers = [me, bobaboy, pixiedust, surfnturf]
    private static let groupID = ConversationID.derive(groupMembers.map(\.id))
    private static let gemini = Bot(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                                    handle: "gemini", displayName: "Gemini", aliases: ["@gemini"])

    @MainActor
    static func apply(to model: AppModel) {
        guard let scene else { return }
        model.currentUser = me
        model.avatar = me.avatar
        _ = model.machine.handle(.signOn)

        var buddies: [Buddy] = []
        for user in online + away.map(\.0) + idle + offline {
            buddies.append(Buddy(id: UUID(), user: user, status: .accepted, incoming: false))
        }
        model.buddies = buddies
        for user in online { model.presences[user.id] = Presence(state: .online) }
        for (user, message) in away { model.presences[user.id] = Presence(state: .away, awayMessage: message) }
        for user in idle { model.presences[user.id] = Presence(state: .idle) }

        model.groupSessions[groupID] = SessionInfo(
            session: ChatSession(id: groupID, participantIDs: groupMembers.map(\.id),
                                 startedAt: Date().addingTimeInterval(-1800)),
            participants: groupMembers)
        model.bots = [gemini.id: gemini]

        switch scene {
        case .friends:
            model.unreadPeers.insert(groupID)
        case .chat:
            model.transcripts[groupID] = chatTranscript
        case .voice:
            model.transcripts[groupID] = voiceTranscript
            model.liveMicConversation = groupID
            model.speakingUsers[groupID] = Set(groupMembers.map(\.id))
            model.speakerSpectrum = [
                me.id: [0.55, 0.9, 0.7, 0.3],
                bobaboy.id: [0.8, 0.45, 0.25, 0.1],
                pixiedust.id: [0.3, 0.6, 0.95, 0.5],
                surfnturf.id: [0.15, 0.35, 0.2, 0.05],
            ]
            for user in [bobaboy, pixiedust, surfnturf] { model.links[user.id] = .direct }
        case .four:
            model.transcripts[groupID] = fourTranscript
            let game = FourState(
                stacks: [[.yellow], [.red, .yellow], [.red, .red, .yellow],
                         [.yellow, .red, .yellow, .red], [.yellow], [.red], []],
                red: me.id, yellow: bobaboy.id)
            model.stages[groupID] = Stage(version: 12, state: .four(game), ownerID: me.id)
        }
    }

    /// A nil speaker is a centered notice.
    private static func transcript(_ lines: [(User?, String)]) -> [AppModel.TranscriptItem] {
        let start = Date().addingTimeInterval(-Double(lines.count) * 40)
        return lines.enumerated().map { index, line in
            let at = start.addingTimeInterval(Double(index) * 40)
            guard let speaker = line.0 else { return .notice(id: UUID(), text: line.1, at: at) }
            return .message(ChatMessage(id: UUID(), sessionID: groupID, senderID: speaker.id,
                                        body: line.1, sentAt: at))
        }
    }

    private static let geminiSpeaker = User(id: gemini.id, handle: gemini.handle)

    private static let chatTranscript = transcript([
        (nil, "pixiedust signed on"),
        (bobaboy, "yo who's around"),
        (me, "here. just got home"),
        (pixiedust, "same!! what r we doing tonight"),
        (surfnturf, "movie? i have the projector set up"),
        (me, "down. 8?"),
        (bobaboy, "8 works, i'll bring snacks. danny ur on drinks"),
        (pixiedust, "@gemini pick a movie for 4 people who can't agree on anything"),
        (geminiSpeaker, "The Princess Bride: adventure, romance and comedy in one, and only 98 minutes."),
        (surfnturf, "lol ok that's actually a good pick"),
        (me, "princess bride it is"),
        (bobaboy, "inconceivable"),
        (pixiedust, "lmaooo"),
        (pixiedust, "wait can we do 8:30, i have to feed the cat"),
        (bobaboy, "the cat comes first em"),
        (surfnturf, "8:30 then. bring blankets, the garage gets cold"),
        (me, "on it"),
    ])

    private static let voiceTranscript = transcript([
        (bobaboy, "yo who's around"),
        (surfnturf, "here"),
        (pixiedust, "me too, just finished homework"),
        (bobaboy, "jake u alive"),
        (me, "yeah sorry, was at the skatepark"),
        (pixiedust, "movie night at danny's still on?"),
        (surfnturf, "hop on voice, easier to plan"),
        (me, "omw"),
        (bobaboy, "everyone can hear me?"),
        (pixiedust, "loud and clear"),
    ])

    private static let fourTranscript = transcript([
        (pixiedust, "who won"),
        (me, "me, obviously"),
        (bobaboy, "jake got lucky"),
        (bobaboy, "rematch. ur going down"),
        (me, "u said that last time"),
        (pixiedust, "i've got $5 on marcus"),
        (surfnturf, "no way, jake has this"),
        (bobaboy, "watch the middle column"),
    ])
    #else
    static let scene: Scene? = nil
    static let openConversation: UUID? = nil

    @MainActor
    static func apply(to model: AppModel) {}
    #endif
}
