import Foundation
import Vapor

/// Self-hosted friend onboarding for ad-hoc distribution, all from one page:
/// a UDID-capture configuration profile (the udid.tech trick — OTA profile
/// enrollment POSTs the device's UDID back), then `onboard/sign.sh` registers
/// the device with App Store Connect and exports a fresh ad-hoc IPA that
/// includes it, served via an itms-services manifest.
///
/// Gated by ONBOARD_CODE (invite code in every URL); disabled when unset.
/// ONBOARD_BASE_URL must be the public https base (profile enrollment and
/// itms-services both require TLS).
struct OnboardController: RouteCollection {
    static let bundleID = "com.aurnik.totem.Totem-iOS"

    func boot(routes: RoutesBuilder) throws {
        let join = routes.grouped("join")
        join.get(use: page)
        join.get("profile", use: profile)
        join.on(.POST, "udid", body: .collect(maxSize: "1mb"), use: receiveUDID)
        join.get("manifest", use: manifest)
        join.get("ipa", use: ipa)
    }

    // MARK: - Routes

    private func page(_ req: Request) async throws -> Response {
        let code = try inviteCode(req)
        let base = baseURL(req)
        let state = await OnboardPipeline.shared.state(ipaPath: ipaPath(req))

        let step2: String
        switch state {
        case .signing:
            step2 = """
            <p class="busy">Preparing your build&hellip; this takes a couple of
            minutes. This page refreshes itself.</p>
            """
        case .failed(let message):
            step2 = """
            <p class="error">Build failed — send this to Aurnik:</p>
            <pre>\(message.htmlEscaped())</pre>
            """
        case .ready:
            let manifestURL = "\(base)/join/manifest?code=\(code)"
            let encoded = manifestURL.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? manifestURL
            step2 = """
            <a class="button" href="itms-services://?action=download-manifest&url=\(encoded)">
            Install Totem</a>
            <p class="hint">After installing, find Totem on your home screen.</p>
            """
        case .idle:
            step2 = #"<p class="hint">Waiting for step 1&hellip;</p>"#
        }

        let refresh = if case .signing = state {
            #"<meta http-equiv="refresh" content="4">"#
        } else { "" }

        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(refresh)
        <title>Join Totem</title>
        <style>
        body { font-family: -apple-system, sans-serif; margin: 0 auto; max-width: 30em;
               padding: 2em 1.5em; color: #222; }
        h1 { font-size: 1.6em; }
        h2 { font-size: 1.1em; margin-top: 2em; }
        .button { display: block; text-align: center; background: #007aff; color: white;
                  padding: 14px; border-radius: 12px; text-decoration: none;
                  font-weight: 600; margin: 1em 0; }
        .hint, .busy { color: #666; font-size: 0.95em; }
        .error { color: #c00; }
        pre { white-space: pre-wrap; font-size: 0.8em; background: #f4f4f4;
              padding: 1em; border-radius: 8px; }
        </style>
        </head><body>
        <h1>Join Totem</h1>
        <h2>Step 1 — register this iPhone</h2>
        <a class="button" href="\(base)/join/profile?code=\(code)">Register this iPhone</a>
        <p class="hint">Safari will download a profile. Open
        <b>Settings&nbsp;&rsaquo;&nbsp;Profile Downloaded</b> and tap Install —
        it reads this phone's device ID, sends it here, and brings you back.
        Nothing stays installed.</p>
        <h2>Step 2 — install the app</h2>
        \(step2)
        </body></html>
        """
        return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"],
                        body: .init(string: html))
    }

    private func profile(_ req: Request) async throws -> Response {
        let code = try inviteCode(req)
        let postURL = "\(baseURL(req))/join/udid?code=\(code)"
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <dict>
                <key>URL</key>
                <string>\(postURL)</string>
                <key>DeviceAttributes</key>
                <array>
                    <string>UDID</string>
                    <string>PRODUCT</string>
                    <string>VERSION</string>
                </array>
            </dict>
            <key>PayloadOrganization</key>
            <string>Totem</string>
            <key>PayloadDisplayName</key>
            <string>Totem Device Registration</string>
            <key>PayloadDescription</key>
            <string>One-time step that sends this device's ID to Totem so a build can be signed for it. Nothing stays installed.</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadUUID</key>
            <string>8C7A9B1E-4F2D-4E7B-9C5A-1D3E5F708192</string>
            <key>PayloadIdentifier</key>
            <string>com.aurnik.totem.udid</string>
            <key>PayloadType</key>
            <string>Profile Service</string>
        </dict>
        </plist>
        """
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/x-apple-aspen-config")
        headers.replaceOrAdd(name: .contentDisposition, value: #"attachment; filename="totem.mobileconfig""#)
        return Response(status: .ok, headers: headers, body: .init(string: payload))
    }

    private func receiveUDID(_ req: Request) async throws -> Response {
        let code = try inviteCode(req)
        guard let body = req.body.data,
              let udid = Self.extractUDID(from: Data(buffer: body)),
              udid.count >= 20, udid.count <= 44,
              udid.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { throw Abort(.badRequest, reason: "No UDID in enrollment payload.") }

        let started = await OnboardPipeline.shared.begin(
            udid: udid, onboardDir: onboardDir(req), logger: req.logger)
        req.logger.info("onboard: UDID \(udid) received, signing \(started ? "started" : "already running")")
        // Redirecting the enrollment POST bounces the device back to Safari;
        // the profile itself never persists.
        return req.redirect(to: "\(baseURL(req))/join?code=\(code)", redirectType: .permanent)
    }

    private func manifest(_ req: Request) async throws -> Response {
        let code = try inviteCode(req)
        let ipaURL = "\(baseURL(req))/join/ipa?code=\(code)"
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>items</key>
            <array>
                <dict>
                    <key>assets</key>
                    <array>
                        <dict>
                            <key>kind</key>
                            <string>software-package</string>
                            <key>url</key>
                            <string>\(ipaURL)</string>
                        </dict>
                    </array>
                    <key>metadata</key>
                    <dict>
                        <key>bundle-identifier</key>
                        <string>\(Self.bundleID)</string>
                        <key>bundle-version</key>
                        <string>1.0</string>
                        <key>kind</key>
                        <string>software</string>
                        <key>title</key>
                        <string>Totem</string>
                    </dict>
                </dict>
            </array>
        </dict>
        </plist>
        """
        return Response(status: .ok, headers: ["Content-Type": "text/xml"],
                        body: .init(string: payload))
    }

    private func ipa(_ req: Request) async throws -> Response {
        _ = try inviteCode(req)
        let path = ipaPath(req)
        guard FileManager.default.fileExists(atPath: path) else {
            throw Abort(.notFound, reason: "No build available yet.")
        }
        return req.fileio.streamFile(at: path)
    }

    // MARK: - Helpers

    private func inviteCode(_ req: Request) throws -> String {
        guard let expected = Environment.get("ONBOARD_CODE") else {
            throw Abort(.notFound)
        }
        guard let provided = req.query[String.self, at: "code"], provided == expected else {
            throw Abort(.forbidden, reason: "Bad invite code.")
        }
        return expected
    }

    private func baseURL(_ req: Request) -> String {
        Environment.get("ONBOARD_BASE_URL")
            ?? "https://" + (req.headers.first(name: .host) ?? "localhost")
    }

    private func onboardDir(_ req: Request) -> String {
        req.application.directory.workingDirectory + "onboard"
    }

    private func ipaPath(_ req: Request) -> String {
        onboardDir(req) + "/build/totem.ipa"
    }

    /// The enrollment POST body is CMS (PKCS#7) DER wrapping an XML plist of
    /// the requested device attributes — fish the plist out without touching
    /// the signature.
    static func extractUDID(from data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let attributes = plist as? [String: Any]
        else { return nil }
        return attributes["UDID"] as? String
    }
}

/// One signing run at a time: registers the device and exports a fresh IPA
/// via `onboard/sign.sh`, with the log tail surfaced on failure.
actor OnboardPipeline {
    static let shared = OnboardPipeline()

    enum State {
        case idle
        case signing
        case ready
        case failed(String)
    }

    private var running = false
    private var failure: String?

    func state(ipaPath: String) -> State {
        if running { return .signing }
        if let failure { return .failed(failure) }
        if FileManager.default.fileExists(atPath: ipaPath) { return .ready }
        return .idle
    }

    /// Returns false if a run was already in progress (the new device still
    /// got registered by the run that follows — the friend can just retry).
    func begin(udid: String, onboardDir: String, logger: Logger) -> Bool {
        guard !running else { return false }
        running = true
        failure = nil
        Task {
            let status = await Self.runScript(udid: udid, onboardDir: onboardDir)
            if status != 0 {
                let log = (try? String(contentsOfFile: onboardDir + "/build/sign.log", encoding: .utf8)) ?? ""
                self.failure = "sign.sh exited \(status)\n" + log.suffix(2_000)
                logger.error("onboard: signing failed (\(status))")
            } else {
                logger.info("onboard: build ready")
            }
            self.running = false
        }
        return true
    }

    private nonisolated static func runScript(udid: String, onboardDir: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.currentDirectoryURL = URL(fileURLWithPath: onboardDir)
            process.arguments = [
                "-c", "mkdir -p build && exec ./sign.sh \"$1\" > build/sign.log 2>&1",
                "sign", udid,
            ]
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}

private extension String {
    func htmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
