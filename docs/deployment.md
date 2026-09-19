# Deployment

Two machines: a container host for the server and a Mac for TestFlight builds.

## Server

The root `Dockerfile` builds the server with the repo as its build context
(TotemKit is a local package). The container needs:

| Variable | Purpose |
| --- | --- |
| `PORT` | Listen port (injected by most hosts; defaults to 8080) |
| `DB_PATH` | SQLite file on a persistent volume, e.g. `/data/db.sqlite` |
| `REDIS_URL` | Redis connection URL |
| `REDIS_PUBLIC_URL` | Optional fallback if the private hostname does not resolve at boot |
| `APNS_KEY_PEM`, `APNS_KEY_ID`, `APNS_TEAM_ID` | Optional; pushes are disabled without them |
| `GEMINI_API_KEY` | Optional; the Gemini bot is not registered without it |
| `YOUTUBE_API_KEY` | Optional; the picker falls back to pasted links without it |
| `LATEST_CLIENT_BUILD` | Set by the release script; drives the in-app update banner |

Without the volume, every redeploy wipes users. Clients reconnect on their own
after a deploy; the bounce lands inside the presence grace period, so nobody
flaps offline.

## TestFlight builds

Signing is API-driven manual signing, so the build machine needs no Xcode
account. `Server/onboard/provision.py` ensures, through the App Store Connect
API, the bundle ID, an Apple Distribution certificate created from a locally
generated key (imported into a dedicated keychain so codesign works over ssh),
Apple's WWDR intermediates, and a fresh App Store profile. Profiles are
immutable, so the profile is recreated on every run.

Requirements on the build machine: full Xcode with the iOS platform installed,
xcodegen as its full release layout (a bare symlink to the binary loses its
bundled setting presets), and an App Store Connect API key with the App Manager
role.

```sh
export ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=~/.appstoreconnect/AuthKey_….p8
export TOTEM_TEAM_ID=… TOTEM_SERVER_URL=https://your-server.example
export TOTEM_TESTFLIGHT_APP_ID=…          # numeric App Store id, for the update banner
/path/to/repo/Server/onboard/testflight.sh
```

Build numbers are stamped from the clock (`YYYYMMDDHHMM`); `MARKETING_VERSION`
in `Apps/project.yml` is bumped by hand per meaningful release, and each new
value re-triggers Beta App Review.

Once the build has processed, `testflight_submit.py` attaches it to every
external group, sets the tester notes, submits it for review, expires older
builds, and announces the build number to the server:

```sh
Server/onboard/.venv/bin/python Server/onboard/testflight_submit.py --status
Server/onboard/.venv/bin/python Server/onboard/testflight_submit.py --submit <build> --notes-file notes.txt
```

Releases are silent by default; pass `--notify` to email testers. Older builds
are expired because client and server ship together, and a tester reinstalling
an old build would talk to a server that has moved past it.
