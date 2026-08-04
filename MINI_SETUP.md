# Deployment — Railway server + Mac mini build machine

Instructions for setting up Totem's production topology. Read `CLAUDE.md`
first for the architecture.

- **Railway** runs everything user-facing 24/7: the chat/presence/audio relay
  (all communication flows through it — nothing is peer-to-peer).
- **The Mac mini** is a build machine only (iOS signing needs macOS +
  Xcode). It archives and uploads TestFlight builds; it is never exposed to
  the internet, no funnel, no static IP, no server.

## Part 1 — Railway

1. Create a Railway project; deploy this repo as a service (connect the
   GitHub repo, or `railway up` from the repo root). The root `Dockerfile`
   is picked up automatically; the build context must be the repo root
   (TotemKit is a local package dependency).
2. Add a **Redis** database to the project.
3. Add a **volume** to the app service, mounted at `/data` (SQLite lives
   there; without it every redeploy wipes users).
4. Service variables:
   - `DB_PATH` = `/data/db.sqlite`
   - `REDIS_URL` = reference the Redis service's connection URL variable
   - `REDIS_PUBLIC_URL` = reference the Redis service's public URL variable
     (fallback — NIO fails to resolve Railway's IPv6-only private DNS, so
     the server retries the private URL then falls back to this)
5. Generate a public domain under Settings → Networking (target port 8080).
6. Redeploy after setting variables.

That domain is what `testflight.sh` bakes into distributed builds as the
default server (`TOTEM_SERVER_URL`), so friends sign in with just a handle.
The apps' sign-in screen also accepts it typed by hand.

## Part 2 — Mac mini (TestFlight builds)

### Tools

- Full Xcode from the App Store (the pipeline runs `xcodebuild archive`).
  Then `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`.
- The iOS platform: `xcodebuild -downloadPlatform iOS` (Xcode ships without
  it).
- xcodegen installed as its full release layout, NOT a bare symlink to the
  binary — xcodegen finds its bundled SettingPresets relative to the binary
  path, and through a symlink it silently generates projects with no platform
  settings. Unzip the release to `~/tools/xcodegen/` and put
  `~/tools/xcodegen/bin` on PATH.
- This repo cloned somewhere stable.

### Secrets (ask the user to place these — do not read the key contents)

- App Store Connect API key `.p8` (App Manager role) at
  `~/.appstoreconnect/AuthKey.p8`, `chmod 600`. Note its Key ID and
  Issuer ID.

### How signing works (no Xcode account needed)

Signing is fully API-driven manual signing — `provision.py` (run by
`testflight.sh` on every build) ensures via the App Store Connect API:

- the distribution bundle ID `com.deadsimple.totem` (dev builds keep
  `com.aurnik.totem.Totem-iOS` under the personal team; that ID is not
  registrable in the paid team `BUQNMSY5Q2`),
- an Apple Distribution certificate created from a locally generated key
  (state in `~/.appstoreconnect/dist/`), imported into a dedicated
  `totem-signing` keychain that the pipeline unlocks with a known password —
  the login keychain is locked in ssh sessions, so codesign would otherwise
  prompt or fail,
- a recreated "Totem AppStore" profile (profiles are immutable — recreation
  is how certificate changes get in),
- Apple's WWDR intermediate certificates.

### Publish a build

The app record `com.deadsimple.totem` must already exist in App Store
Connect, with an external tester group and a public link.

```sh
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.appstoreconnect/AuthKey_….p8
export TOTEM_SERVER_URL=https://<railway-domain>
/PATH/TO/REPO/Server/onboard/testflight.sh
```

Invoke it with an absolute path — cwd drifts. The build appears in App Store
Connect after processing (~5–15 min), then goes to testers.

## Operations

- **Onboard a friend**: send them the TestFlight public link.
- **Publish an app update**: run `testflight.sh` on the mini. Build numbers
  auto-stamp from the clock; bump `MARKETING_VERSION` in `Apps/project.yml`
  by hand per meaningful release — each new marketing version re-triggers
  external Beta App Review.
- **Server update**: push to the deployed branch (or `railway up`) —
  Railway rebuilds. Users' sockets reconnect automatically.
- **Logs**: Railway dashboard for the server; the `testflight.sh` output on
  the mini.
