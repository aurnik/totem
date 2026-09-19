import XCTest
@testable import TotemKit

final class BotTagTests: XCTestCase {

    private let aliases = ["@gemini", "@g"]

    func testMatchesLongAlias() {
        let m = BotTag.match("@gemini what is a totem pole", aliases: aliases)
        XCTAssertEqual(m?.tag, "@gemini")
        XCTAssertEqual(m?.prompt, "what is a totem pole")
    }

    func testMatchesShortAlias() {
        let m = BotTag.match("@g hello", aliases: aliases)
        XCTAssertEqual(m?.tag, "@g")
        XCTAssertEqual(m?.prompt, "hello")
    }

    func testLongestAliasWinsOverPrefix() {
        // "@g" is a prefix of "@gemini"; the longer tag wins.
        XCTAssertEqual(BotTag.match("@gemini hi", aliases: ["@g", "@gemini"])?.tag, "@gemini")
    }

    func testWordBoundaryRequired() {
        XCTAssertNil(BotTag.match("@general chat is over there", aliases: aliases))
        XCTAssertNil(BotTag.match("@geminis are cool", aliases: aliases))
    }

    func testCaseInsensitiveButPreservesTypedCasing() {
        let m = BotTag.match("@GeMiNi hi", aliases: aliases)
        XCTAssertEqual(m?.tag, "@GeMiNi")
        XCTAssertEqual(m?.prompt, "hi")
    }

    func testLeadingPositionOnly() {
        XCTAssertNil(BotTag.match("ask @gemini about it", aliases: aliases))
    }

    func testLeadingWhitespaceIgnored() {
        XCTAssertEqual(BotTag.match("   @g hi", aliases: aliases)?.prompt, "hi")
    }

    func testBareTagIsAMatchWithEmptyPrompt() {
        let m = BotTag.match("@gemini", aliases: aliases)
        XCTAssertEqual(m?.tag, "@gemini")
        XCTAssertEqual(m?.prompt, "")
    }

    func testTagRangeLocatesTheTagInTheOriginalBody() {
        let body = "  @g hello"
        let m = BotTag.match(body, aliases: aliases)
        XCTAssertEqual(m.map { String(body[$0.tagRange]) }, "@g")
    }

    func testNoMatchWithoutATag() {
        XCTAssertNil(BotTag.match("hello there", aliases: aliases))
        XCTAssertNil(BotTag.match("", aliases: aliases))
        XCTAssertNil(BotTag.match("   ", aliases: aliases))
    }

    // MARK: - Context tags

    private var gemini: Bot {
        Bot(id: UUID(), handle: "gemini", displayName: "Gemini",
            aliases: ["@gemini", "@g", "@gemini_", "@g_"],
            contextAliases: ["@gemini_", "@g_"])
    }

    func testUnderscoreTagsMatchAndAreDistinctFromPlainOnes() {
        let all = gemini.aliases
        XCTAssertEqual(BotTag.match("@g_ recap", aliases: all)?.tag, "@g_")
        XCTAssertEqual(BotTag.match("@gemini_ recap", aliases: all)?.tag, "@gemini_")
        // The trailing underscore is not swallowed by the shorter tag.
        XCTAssertEqual(BotTag.match("@g_ recap", aliases: all)?.prompt, "recap")
    }

    func testOnlyUnderscoreTagsAskForContext() {
        let bot = gemini
        XCTAssertTrue(bot.wantsContext("@g_"))
        XCTAssertTrue(bot.wantsContext("@GEMINI_"))
        XCTAssertFalse(bot.wantsContext("@g"))
        XCTAssertFalse(bot.wantsContext("@gemini"))
    }

    func testPlainTagStillMatchesWhenUnderscoreTagsExist() {
        let all = gemini.aliases
        XCTAssertEqual(BotTag.match("@g hi", aliases: all)?.tag, "@g")
        XCTAssertEqual(BotTag.match("@gemini hi", aliases: all)?.tag, "@gemini")
    }

    func testUnderscoreTagStillNeedsAWordBoundary() {
        XCTAssertNil(BotTag.match("@g_thing", aliases: gemini.aliases))
    }

    func testBotDecodesWithoutContextAliases() throws {
        let json = #"{"id":"\#(UUID().uuidString)","handle":"g","displayName":"G","aliases":["@g"]}"#
        let bot = try JSONDecoder().decode(Bot.self, from: Data(json.utf8))
        XCTAssertEqual(bot.contextAliases, [])
        XCTAssertFalse(bot.wantsContext("@g"))
    }

    func testMatchAcrossBotsPicksTheTaggedOne() {
        let gemini = Bot(id: UUID(), handle: "gemini", displayName: "Gemini",
                         aliases: ["@gemini", "@g"])
        let other = Bot(id: UUID(), handle: "echo", displayName: "Echo", aliases: ["@echo"])
        XCTAssertEqual(BotTag.match("@echo hi", bots: [gemini, other])?.bot.id, other.id)
        XCTAssertNil(BotTag.match("hi", bots: [gemini, other]))
    }
}
