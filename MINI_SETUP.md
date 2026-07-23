# Deployment — Railway server + Mac mini signer

Instructions for setting up Totem's production topology. Read `CLAUDE.md`
first for the architecture.

- **Railway** runs everything user-facing 24/7: the chat/presence/audio relay
  (all communication flows through it — nothing is peer-to-peer), the
  `/join` onboarding site, and the `/app` update feed. Railway's domain
  provides the HTTPS that profile enrollment and itms-services require.
- **The Mac mini** is a signing worker only (iOS signing needs macOS +
  Xcode). It holds a long-poll request open to Railway, which hands jobs
  over the moment a friend registers — push latency, but only outbound
  HTTPS: the mini is never exposed to the internet, no funnel, no static
  IP, no server.

The two halves share `SIGNER_SECRET`, a random string you generate
(`openssl rand -hex 24`). Setting it on the Railway service is what switches
the server from local signing to job queueing.

## Part 1 — Railway

1. Create a Railway project; deploy this repo as a service (connect the
   GitHub repo, or `railway up` from the repo root). The root `Dockerfile`
   is picked up automatically; the build context must be the repo root
   (TotemKit is a local package dependency).
2. Add a **Redis** database to the project.
3. Add a **volume** to the app service, mounted at `/data` (SQLite + built
   IPAs live there; without it every redeploy wipes users and builds).
4. Service variables:
   - `DB_PATH` = `/data/db.sqlite`
   - `ONBOARD_DIR` = `/data/onboard`
   - `REDIS_URL` = reference the Redis service's connection URL variable
   - `REDIS_PUBLIC_URL` = reference the Redis service's public URL variable
     (fallback — NIO fails to resolve Railway's IPv6-only private DNS, so
     the server retries the private URL then falls back to this)
   - `ONBOARD_CODE` = an invite code you choose
   - `SIGNER_SECRET` = the shared secret
   - `ONBOARD_BASE_URL` = `https://<the service's public domain>` (generate
     the domain under Settings → Networking first; target port 8080)
5. Redeploy after setting variables.

Verify:

```sh
BASE=https://<railway-domain>
curl -s -o /dev/null -w "%{http_code}\n" "$BASE/join?code=<ONBOARD_CODE>"   # 200
curl -s -o /dev/null -w "%{http_code}\n" "$BASE/join"                        # 403
curl -s "$BASE/app/version"                    # 404 until the first build uploads
```

The apps' sign-in screen accepts this URL as the server (friends' builds get
it baked in automatically once the first signed build is published).

## Part 2 — Mac mini (signing worker)

### Tools

- Full Xcode from the App Store (the pipeline runs `xcodebuild archive`).
  Then `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`.
- `brew install xcodegen`.
- This repo cloned somewhere stable.

### Secrets (ask the user to place these — do not read the key contents)

- App Store Connect API key `.p8` (App Manager role) at
  `~/.appstoreconnect/AuthKey.p8`, `chmod 600`. Note its Key ID and
  Issuer ID.

### First run — interactively, once

Cloud signing creates/downloads the Apple Distribution certificate on first
use and the keychain prompts:

```sh
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.appstoreconnect/AuthKey.p8
export SERVER_URL=https://<railway-domain> SIGNER_SECRET=<shared secret>
Server/onboard/worker.sh --publish
```

Click "Always Allow" on keychain prompts. When it finishes,
`curl $SERVER_URL/app/version` returns the build number — the update feed
is live.

### Keep the worker running

`~/Library/LaunchAgents/com.aurnik.totem.signer.plist` (fill in real values):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.aurnik.totem.signer</string>
    <key>ProgramArguments</key>
    <array><string>/PATH/TO/REPO/Server/onboard/worker.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SERVER_URL</key><string>https://RAILWAY-DOMAIN</string>
        <key>SIGNER_SECRET</key><string>SHARED-SECRET</string>
        <key>ASC_KEY_ID</key><string>KEY_ID</string>
        <key>ASC_ISSUER_ID</key><string>ISSUER_ID</string>
        <key>ASC_KEY_PATH</key><string>/Users/USER/.appstoreconnect/AuthKey.p8</string>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/totem-signer.log</string>
    <key>StandardErrorPath</key><string>/tmp/totem-signer.log</string>
</dict>
</plist>
```

Load: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aurnik.totem.signer.plist`.
A LaunchAgent (not a LaunchDaemon) because xcodebuild signing needs the
user's keychain. Keep the mini awake: System Settings → Energy → prevent
automatic sleeping (or `sudo pmset -a sleep 0`).

## End-to-end check

On any iPhone, open `https://<railway-domain>/join?code=<ONBOARD_CODE>`:
register the device (profile → Settings → Install → bounced back), watch
the page flip to "Preparing your build…" (the worker receives the job
immediately; the build takes a couple of minutes), then Install Totem. The
app signs in with just a handle — the server URL is baked in.

## Operations

- **Onboard a friend**: text them the `/join?code=…` link. Registrations
  count against Apple's 100-devices/year cap.
- **Publish an app update**: on the mini, run `worker.sh --publish` (with
  the env above). Installed apps show an "Update Totem" button on next
  launch/foreground. Dev builds (build number "1") never show it.
- **Server update**: push to the deployed branch (or `railway up`) —
  Railway rebuilds. Users' sockets reconnect automatically.
- **Annual**: the ad-hoc provisioning profile expires after 1 year — apps
  stop launching until you `worker.sh --publish` and friends reinstall from
  `/join` (registered devices never redo the profile step).
- **Logs**: Railway dashboard for the server; `/tmp/totem-signer.log` and
  `Server/onboard/build/worker.log` on the mini. Signing failures surface
  on the `/join` page automatically.
