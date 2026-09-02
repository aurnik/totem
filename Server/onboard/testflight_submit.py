"""Submit a processed TestFlight build to the external tester group.

Uploading a build only puts it in App Store Connect; external testers see
nothing until the build is attached to their group and passes Beta App Review.
Both steps are API-driven, and both have prerequisites Apple rejects the
submission without: export-compliance answered, "What to Test" notes present,
and the app's beta review contact details on file.

Run with --status to inspect without changing anything.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (same key as provision.py).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

BUNDLE_ID = "com.deadsimple.totem"
API = "https://api.appstoreconnect.apple.com/v1"
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now - 30, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        open(os.environ["ASC_KEY_PATH"]).read(),
        algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def api(method, path, body=None, tolerate=()):
    req = urllib.request.Request(
        f"{API}/{path}", method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode()
        if e.code in tolerate:
            return {"error": e.code, "detail": detail}
        sys.exit(f"{method} {path} failed ({e.code}): {detail[:600]}")


def app_id():
    found = api("GET", f"apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not found:
        sys.exit(f"no app record for {BUNDLE_ID}")
    return found[0]["id"]


def latest_build(app, version=None):
    query = f"builds?filter[app]={app}&limit=5&sort=-version"
    if version:
        query += f"&filter[version]={version}"
    builds = api("GET", query)["data"]
    if not builds:
        sys.exit("no builds found")
    return builds[0]


def previous_version(app, current):
    """Highest build number below `current`. Zero-padded stamps of equal width,
    so string ordering is chronological."""
    versions = sorted(
        (b["attributes"]["version"]
         for b in api("GET", f"builds?filter[app]={app}&limit=200")["data"]),
        reverse=True)
    return next((v for v in versions if v < current), None)


def commit_titles(previous, current):
    """Commit subjects this build carries. testflight.sh stamps build numbers
    with `date +%Y%m%d%H%M`, so two of them bound the range directly — no tag
    or recorded SHA needed."""
    def when(stamp):
        # Stamps have minute resolution and a build is archived from the
        # working tree, usually a moment before its commit lands, so a
        # build's minute belongs to it whole.
        return f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]} {stamp[8:10]}:{stamp[10:12]}:59"

    result = subprocess.run(
        ["git", "log", "--no-merges", "--pretty=format:%s",
         f"--since={when(previous)}", f"--until={when(current)}"],
        capture_output=True, text=True, cwd=REPO)
    if result.returncode != 0:
        sys.exit(f"git log failed: {result.stderr.strip()[:200]}")
    return [line for line in result.stdout.splitlines() if line.strip()]


def external_groups(app):
    groups = api("GET", f"betaGroups?filter[app]={app}&limit=50")["data"]
    return [g for g in groups if not g["attributes"].get("isInternalGroup")]


def status():
    app = app_id()
    print(f"app id: {app}")

    for build in api("GET", f"builds?filter[app]={app}&limit=3&sort=-version")["data"]:
        a = build["attributes"]
        print(f"\nbuild {a['version']}  id={build['id']}")
        print(f"  processingState:   {a.get('processingState')}")
        print(f"  expired:           {a.get('expired')}")
        print(f"  usesNonExempt:     {a.get('usesNonExemptEncryption')}")
        print(f"  expirationDate:    {a.get('expirationDate')}")
        loc = api("GET", f"builds/{build['id']}/betaBuildLocalizations")["data"]
        print(f"  whatsNew:          {[l['attributes'].get('whatsNew') for l in loc] or 'NONE'}")
        sub = api("GET", f"builds/{build['id']}/betaAppReviewSubmission",
                  tolerate=(404,))
        if sub and "error" not in sub and sub.get("data"):
            print(f"  reviewSubmission:  {sub['data']['attributes'].get('betaReviewState')}")
        else:
            print("  reviewSubmission:  none")

    print("\nbeta groups:")
    for g in api("GET", f"betaGroups?filter[app]={app}&limit=50")["data"]:
        a = g["attributes"]
        kind = "internal" if a.get("isInternalGroup") else "EXTERNAL"
        builds = api("GET", f"betaGroups/{g['id']}/builds?limit=5",
                     tolerate=(403, 404))
        names = "?"
        if builds and "error" not in builds:
            names = [b["attributes"]["version"] for b in builds["data"]] or "none"
        print(f"  {a['name']}  ({kind})  id={g['id']}  "
              f"publicLink={a.get('publicLinkEnabled')}  builds={names}")

    detail = api("GET", f"apps/{app}/betaAppReviewDetail", tolerate=(404,))
    print("\nbetaAppReviewDetail:")
    if detail and "error" not in detail and detail.get("data"):
        d = detail["data"]["attributes"]
        for key in ("contactFirstName", "contactLastName", "contactEmail",
                    "contactPhone", "demoAccountRequired", "demoAccountName"):
            print(f"  {key}: {d.get(key)!r}")
    else:
        print("  MISSING — Beta App Review will reject without it")

    loc = api("GET", f"apps/{app}/betaAppLocalizations", tolerate=(404,))
    print("\nbetaAppLocalizations:")
    if loc and "error" not in loc:
        for l in loc["data"]:
            a = l["attributes"]
            print(f"  {a.get('locale')}: description={bool(a.get('description'))} "
                  f"feedbackEmail={a.get('feedbackEmail')!r}")


def set_whats_new(build_id, text, locale="en-US"):
    """Beta App Review rejects a build with no tester notes."""
    existing = api("GET", f"builds/{build_id}/betaBuildLocalizations")["data"]
    for loc in existing:
        if loc["attributes"].get("locale") == locale:
            api("PATCH", f"betaBuildLocalizations/{loc['id']}",
                {"data": {"type": "betaBuildLocalizations", "id": loc["id"],
                          "attributes": {"whatsNew": text}}})
            return "updated"
    api("POST", "betaBuildLocalizations",
        {"data": {"type": "betaBuildLocalizations",
                  "attributes": {"locale": locale, "whatsNew": text},
                  "relationships": {"build": {
                      "data": {"type": "builds", "id": build_id}}}}})
    return "created"


def add_to_group(group_id, build_id):
    result = api("POST", f"betaGroups/{group_id}/relationships/builds",
                 {"data": [{"type": "builds", "id": build_id}]},
                 tolerate=(409, 422))
    return "already attached" if result and "error" in result else "attached"


def set_auto_notify(build_id, enabled):
    """Whether TestFlight emails every tester the moment the build goes live.

    Off unless asked for: builds go out several times a day here, and an inbox
    that fills with them is one nobody reads on the release that matters.
    Testers still get the build — silently if their TestFlight auto-updates,
    otherwise next time they open it — and expiring the older builds means
    anyone who fell behind is told to update by the app itself rather than by
    a mail they've learned to ignore. Must run before the build reaches an
    external group, since that is what sends the mail.
    """
    detail = api("GET", f"builds/{build_id}/buildBetaDetail")["data"]["id"]
    api("PATCH", f"buildBetaDetails/{detail}",
        {"data": {"id": detail, "type": "buildBetaDetails",
                  "attributes": {"autoNotifyEnabled": enabled}}})
    return "testers emailed" if enabled else "silent"


def submit_for_review(build_id):
    result = api("POST", "betaAppReviewSubmissions",
                 {"data": {"type": "betaAppReviewSubmissions",
                           "relationships": {"build": {
                               "data": {"type": "builds", "id": build_id}}}}},
                 tolerate=(409, 422))
    if result and "error" in result:
        return f"not created ({result['error']}) — may already be in review"
    return result["data"]["attributes"].get("betaReviewState", "submitted")


def announce_build_to_server(version):
    """Tell the server which build testers can now install.

    The in-app banner reads this off the welcome frame, so the number has to
    reach the server's environment — which Railway only re-injects by
    deploying. That deploy is also what delivers it: every client reconnects,
    gets a fresh welcome, and the ones left behind start showing the banner.
    The bounce lands inside the presence grace, so nobody flaps offline.

    Never fatal. It runs after the build is already submitted, and a release
    that shipped but didn't announce itself is a missing banner, not a broken
    release — recoverable by setting the variable by hand.
    """
    try:
        subprocess.run(["railway", "variable", "set", f"LATEST_CLIENT_BUILD={version}"],
                       check=True, capture_output=True, timeout=120)
        return f"LATEST_CLIENT_BUILD={version}"
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        detail = getattr(e, "stderr", b"") or b""
        return (f"FAILED ({e}) {detail.decode()[:200]} — set LATEST_CLIENT_BUILD={version} "
                "on Railway by hand, or the banner won't appear")


def expire_build(build_id):
    api("PATCH", f"builds/{build_id}",
        {"data": {"type": "builds", "id": build_id,
                  "attributes": {"expired": True}}})


def expire_previous(app, keep_version, dry_run=False):
    """Retire every older build once the new one is live.

    TestFlight keeps offering builds until they expire, so a tester who
    reinstalls can land on an old one — and this app's client and server ship
    together, so an old client is one that talks to a server that has moved
    past it. Expiring leaves exactly one installable build.
    """
    builds = api("GET", f"builds?filter[app]={app}&limit=50&sort=-version")["data"]
    retired = 0
    for build in builds:
        a = build["attributes"]
        if a["version"] == keep_version or a.get("expired"):
            continue
        if dry_run:
            print(f"expire {a['version']}: would expire")
        else:
            expire_build(build["id"])
            print(f"expire {a['version']}: expired")
        retired += 1
    if not retired:
        print("expire: nothing older still active")


def notes_for(app, version):
    previous = previous_version(app, version)
    if not previous:
        sys.exit(f"no build before {version} to diff against")
    titles = commit_titles(previous, version)
    if not titles:
        sys.exit(f"no commits between builds {previous} and {version}")
    return previous, "\n".join(titles)


def submit(version, notes=None, dry_run=False, notify=False):
    app = app_id()
    build = latest_build(app, version)
    build_id = build["id"]
    state = build["attributes"].get("processingState")
    if state != "VALID":
        sys.exit(f"build {version} is {state}, not VALID — wait for processing")

    if notes:
        origin = "supplied notes"
    else:
        previous, notes = notes_for(app, version)
        origin = f"commit titles since build {previous}"
    print(f"build {version} ({build_id}) is VALID; {origin}\n")
    print(notes)
    if dry_run:
        print(f"\nnotification: {'testers emailed' if notify else 'silent'}")
        expire_previous(app, version, dry_run=True)
        print(f"announce: would set LATEST_CLIENT_BUILD={version} on Railway")
        print("\n(dry run — nothing submitted)")
        return

    print(f"\nwhats-new: {set_whats_new(build_id, notes)}")
    print(f"notification: {set_auto_notify(build_id, notify)}")
    for group in external_groups(app):
        name = group["attributes"]["name"]
        print(f"group {name}: {add_to_group(group['id'], build_id)}")
    print(f"review submission: {submit_for_review(build_id)}")
    # Last, so a failure earlier leaves the old builds installable rather than
    # retiring them in favour of one that never shipped.
    expire_previous(app, version)
    print(f"announce: {announce_build_to_server(version)}")


if __name__ == "__main__":
    if "--status" in sys.argv:
        status()
    elif "--submit" in sys.argv:
        version = sys.argv[sys.argv.index("--submit") + 1]
        supplied = None
        if "--notes-file" in sys.argv:
            path = sys.argv[sys.argv.index("--notes-file") + 1]
            supplied = open(path).read().strip()
            if not supplied:
                sys.exit(f"{path} is empty — review rejects a build with no notes")
        submit(version, notes=supplied, dry_run="--dry-run" in sys.argv,
               notify="--notify" in sys.argv)
    elif "--expire-previous" in sys.argv:
        version = sys.argv[sys.argv.index("--expire-previous") + 1]
        expire_previous(app_id(), version, dry_run="--dry-run" in sys.argv)
    elif "--commits" in sys.argv:
        app = app_id()
        version = sys.argv[sys.argv.index("--commits") + 1]
        previous, notes = notes_for(app, version)
        print(f"# commits in build {version}, since build {previous}\n{notes}")
    else:
        sys.exit("usage: testflight_submit.py --status "
                 "| --commits <build-number> "
                 "| --submit <build-number> [--notes-file <path>] [--dry-run] "
                 "| --expire-previous <build-number> [--dry-run]")
