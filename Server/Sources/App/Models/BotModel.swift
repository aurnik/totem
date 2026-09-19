import Fluent
import Foundation
import TotemKit

/// A bot's durable identity. The row ID is the `senderID` on everything the
/// bot says, so it must be stable across restarts.
final class BotModel: Model, @unchecked Sendable {
    static let schema = "bots"

    @ID(key: .id) var id: UUID?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    /// JSON array of tags including the leading "@".
    @Field(key: "aliases") var aliasesJSON: String
    /// Subset of `aliases` whose use also sends the conversation so far.
    @OptionalField(key: "context_aliases") var contextAliasesJSON: String?

    init() {}

    init(id: UUID? = nil, handle: String, displayName: String, aliases: [String],
         contextAliases: [String] = []) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.aliases = aliases
        self.contextAliases = contextAliases
    }

    var aliases: [String] {
        get { Self.decode(aliasesJSON) }
        set { aliasesJSON = Self.encode(newValue) }
    }

    var contextAliases: [String] {
        get { contextAliasesJSON.map(Self.decode) ?? [] }
        set { contextAliasesJSON = Self.encode(newValue) }
    }

    private static func decode(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private static func encode(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values.map { $0.lowercased() }))
            ?? Data("[]".utf8), as: UTF8.self)
    }

    var dto: TotemKit.Bot {
        Bot(id: id!, handle: handle, displayName: displayName,
            aliases: aliases, contextAliases: contextAliases)
    }
}
