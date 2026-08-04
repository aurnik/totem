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
import sys
import time
import urllib.error
import urllib.request

import jwt

BUNDLE_ID = "com.deadsimple.totem"
API = "https://api.appstoreconnect.apple.com/v1"


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


def submit_for_review(build_id):
    result = api("POST", "betaAppReviewSubmissions",
                 {"data": {"type": "betaAppReviewSubmissions",
                           "relationships": {"build": {
                               "data": {"type": "builds", "id": build_id}}}}},
                 tolerate=(409, 422))
    if result and "error" in result:
        return f"not created ({result['error']}) — may already be in review"
    return result["data"]["attributes"].get("betaReviewState", "submitted")


def submit(version, notes):
    app = app_id()
    build = latest_build(app, version)
    build_id = build["id"]
    state = build["attributes"].get("processingState")
    if state != "VALID":
        sys.exit(f"build {version} is {state}, not VALID — wait for processing")

    print(f"build {build['attributes']['version']} ({build_id}) is VALID")
    print(f"whats-new: {set_whats_new(build_id, notes)}")

    for group in external_groups(app):
        name = group["attributes"]["name"]
        print(f"group {name}: {add_to_group(group['id'], build_id)}")

    print(f"review submission: {submit_for_review(build_id)}")


NOTES = """\
Housekeeping release — no new features, but everyone needs it.

The server changed how it sends account details, so builds older than this \
one can no longer sign in. Update and you're fine.

Under the hood a lot of unused code came out, including paths that touched \
voice, dictation, group chats and avatars. Nothing there should look any \
different — so if something does, that's a bug and I want to hear about it. \
Worth a quick try: live voice in a group chat, the dictation toggle, and \
signing out and back in.\
"""

if __name__ == "__main__":
    if "--status" in sys.argv:
        status()
    elif "--submit" in sys.argv:
        version = sys.argv[sys.argv.index("--submit") + 1]
        submit(version, NOTES)
    else:
        sys.exit("usage: testflight_submit.py --status | --submit <build-number>")
