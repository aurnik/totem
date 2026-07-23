# Mac mini setup — Totem server + friend onboarding

Instructions for Claude Code running on the Mac mini. Goal: this machine runs
the Totem server 24/7, exposes it publicly over HTTPS, and hosts the
self-serve friend onboarding (UDID capture → device registration → ad-hoc IPA
signing → itms-services install) plus the in-app update feed.

Read `CLAUDE.md` first for the architecture. Everything below assumes this
repo is cloned on the mini and you are working from its root.

## What runs here

| Piece | How |
|---|---|
| Redis | `brew services start redis` (launches at boot) |
| Vapor server on 0.0.0.0:9047 | `Server/run.sh`, kept alive by a LaunchAgent |
| Public HTTPS | Tailscale Funnel forwarding to port 9047 |
| Signing pipeline | `Server/onboard/sign.sh`, spawned by the server on demand |

## One-time setup

### 1. Tools

- Full Xcode from the App Store (not just CLT — the signing pipeline runs
  `xcodebuild archive`). Then: `sudo xcodebuild -license accept` and
  `xcodebuild -runFirstLaunch`.
- `brew install xcodegen redis tailscale` (or Tailscale from the App Store).
- `brew services start redis`.
- The user must be signed into Tailscale: `tailscale up`.

### 2. Secrets (ask the user to place these — do not read the key contents)

- App Store Connect API key `.p8` (App Manager role) at
  `~/.appstoreconnect/AuthKey.p8`, `chmod 600`. Note its Key ID and Issuer ID.

### 3. Public URL via Tailscale Funnel

```sh
tailscale funnel --bg 9047
tailscale funnel status   # shows the public https URL, e.g. https://mini.tailXXXX.ts.net
```

If funnel is refused, the tailnet needs HTTPS certificates and the funnel
node attribute enabled — the `tailscale` CLI prints the admin-console link to
approve. The `--bg` config persists across reboots. The resulting URL is
`ONBOARD_BASE_URL` below.

### 4. Server codesigning identity

`Server/run.sh` codesigns the binary so the macOS firewall allowance survives
rebuilds. It defaults to Aurnik's dev-machine identity; on the mini set
`SERVER_CODESIGN_IDENTITY` to an identity that exists here
(`security find-identity -v -p codesigning`). Funnel traffic arrives via
tailscaled locally, so the firewall only matters for LAN clients.

### 5. Environment + LaunchAgent

Create `~/Library/LaunchAgents/com.aurnik.totem.server.plist` (fill in the
real paths/values):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.aurnik.totem.server</string>
    <key>ProgramArguments</key>
    <array><string>/PATH/TO/REPO/Server/run.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ONBOARD_CODE</key><string>CHOOSE-AN-INVITE-CODE</string>
        <key>ONBOARD_BASE_URL</key><string>https://MINI-FUNNEL-URL</string>
        <key>ASC_KEY_ID</key><string>KEY_ID</string>
        <key>ASC_ISSUER_ID</key><string>ISSUER_ID</string>
        <key>ASC_KEY_PATH</key><string>/Users/USER/.appstoreconnect/AuthKey.p8</string>
        <key>SERVER_CODESIGN_IDENTITY</key><string>IDENTITY-ON-THIS-MAC</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/totem-server.log</string>
    <key>StandardErrorPath</key><string>/tmp/totem-server.log</string>
</dict>
</plist>
```

Load with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aurnik.totem.server.plist`.
A LaunchAgent (not a LaunchDaemon) because xcodebuild's signing needs the
user's keychain. The mini must be set to stay awake: System Settings →
Energy → prevent automatic sleeping (or `sudo pmset -a sleep 0`).

### 6. First signing run — do this interactively, once

Cloud signing creates/downloads the Apple Distribution certificate on first
use and the keychain will prompt:

```sh
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… ONBOARD_BASE_URL=…
Server/onboard/sign.sh --rebuild
```

Click "Always Allow" on keychain prompts. When this completes,
`Server/onboard/build/totem.ipa` and `version.txt` exist and the update feed
is live.

## Verify

```sh
curl -s https://MINI-FUNNEL-URL/app/version          # {"build":YYYYMMDDHHMM}
curl -s -o /dev/null -w "%{http_code}\n" "https://MINI-FUNNEL-URL/join?code=THE-CODE"   # 200
curl -s -o /dev/null -w "%{http_code}\n" https://MINI-FUNNEL-URL/join                   # 403
```

Then a real phone: open `https://MINI-FUNNEL-URL/join?code=THE-CODE`, run
both steps, confirm the app installs and signs in (the server URL is baked
into the build from `ONBOARD_BASE_URL` — the friend only types a handle).

## Operations

- **Onboard a friend**: text them `https://MINI-FUNNEL-URL/join?code=THE-CODE`.
  The page walks them through profile → wait → install. Device registration
  counts against the Apple 100-devices/year cap.
- **Publish an app update**: `git pull`, then `Server/onboard/sign.sh --rebuild`
  (with the env vars above). Installed apps show an "Update Totem" button on
  next launch/foreground; tapping it installs over the top, data intact.
  Dev builds (build number "1") never show the banner.
- **Server code update**: `git pull`, then
  `launchctl kickstart -k gui/$(id -u)/com.aurnik.totem.server` (run.sh
  rebuilds on start).
- **Annual**: the ad-hoc provisioning profile expires after 1 year — apps
  stop launching. Run `sign.sh --rebuild`; friends reinstall from the
  `/join` page (registered devices never redo the profile step).
- **Logs**: server `/tmp/totem-server.log`; signing
  `Server/onboard/build/sign.log` (the `/join` page shows the tail on
  failure).
