import APNS
import APNSCore
import Crypto
import Fluent
import FluentSQLiteDriver
import Redis
import Vapor
import VaporAPNS

func configure(_ app: Application) async throws {
    app.databases.use(
        .sqlite(.file(Environment.get("DB_PATH") ?? "db.sqlite")), as: .sqlite)
    app.redis.configuration = try await resolveRedis(logger: app.logger)

    // Pushes are disabled unless the APNs key is in the environment.
    if let keyPEM = Environment.get("APNS_KEY_PEM"),
       let keyID = Environment.get("APNS_KEY_ID"),
       let teamID = Environment.get("APNS_TEAM_ID") {
        app.apns.containers.use(
            APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: try .init(pemRepresentation: keyPEM),
                    keyIdentifier: keyID,
                    teamIdentifier: teamID),
                environment: .production),
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            responseDecoder: JSONDecoder(),
            requestEncoder: JSONEncoder(),
            as: .default)
    }

    app.migrations.add(CreateSchema())
    app.migrations.add(DropMessageStorage())
    app.migrations.add(AddPushSupport())
    app.migrations.add(AddAvatar())
    app.migrations.add(AddBots())
    app.migrations.add(AddBotContextAliases())
    app.migrations.add(AdoptDerivedConversations())
    app.migrations.add(DropSessionStorage())
    app.migrations.add(SignOnAlertsOptIn())
    app.migrations.add(AddLastSeen())
    try await app.autoMigrate()

    let connections = ConnectionManager()
    let bots = BotRegistry()
    await bots.load(db: app.db, client: app.client, logger: app.logger)
    let gateway = GatewayController(
        app: app, connections: connections, pusher: Pusher(app: app),
        bots: bots)

    let authed = app.grouped(TokenAuthenticator(), UserModel.guardMiddleware())
    try authed.register(collection: BuddyController(gateway: gateway))
    try authed.register(collection: SessionController(gateway: gateway))
    try authed.register(collection: PushController())
    try authed.register(collection: ProfileController(gateway: gateway))
    try authed.register(collection: YouTubeController())
    // The YouTube player page must load from a real origin and a WKWebView
    // sends no bearer token, so it is unauthenticated and keyed only by video ID.
    try app.register(collection: PlayerPageController())
    authed.webSocket("ws") { req, ws in
        await gateway.handleUpgrade(req: req, ws: ws)
    }
    try app.register(collection: AuthController())

    gateway.startLivenessSweep()
}

/// `RedisConfiguration(url:)` resolves the hostname eagerly, and a container
/// host's private DNS can lag container start, so this retries before falling
/// back to `REDIS_PUBLIC_URL`.
private func resolveRedis(logger: Logger) async throws -> RedisConfiguration {
    guard let redisURL = Environment.get("REDIS_URL") else {
        return try RedisConfiguration(hostname: Environment.get("REDIS_HOST") ?? "localhost")
    }
    var lastError: Error?
    for attempt in 1...10 {
        do {
            return try RedisConfiguration(url: redisURL)
        } catch {
            lastError = error
            logger.warning("redis resolve attempt \(attempt) failed: \(error)")
            try? await Task.sleep(for: .seconds(1))
        }
    }
    if let publicURL = Environment.get("REDIS_PUBLIC_URL") {
        logger.warning("falling back to REDIS_PUBLIC_URL")
        return try RedisConfiguration(url: publicURL)
    }
    throw lastError!
}
