"""Ensure signing prerequisites via the App Store Connect API.

    provision.py

Ensures the bundle ID, an Apple Distribution certificate in the signing
keychain, and the App Store provisioning profile. Profiles are immutable, so
that one is recreated every run; everything else is idempotent.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH. State in ~/.appstoreconnect/dist/.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

BUNDLE_ID = "com.deadsimple.totem"
APPSTORE_PROFILE_NAME = "Totem AppStore"
API = "https://api.appstoreconnect.apple.com/v1"
STATE = os.path.expanduser("~/.appstoreconnect/dist")
# Dedicated signing keychain so codesign works headless; the login keychain is
# locked in ssh sessions.
KEYCHAIN = os.path.expanduser("~/Library/Keychains/totem-signing.keychain-db")
KEYCHAIN_PASS = "totem-signing"
# System LibreSSL, not Homebrew OpenSSL 3, whose default PKCS12 format is
# rejected by `security import`.
OPENSSL = "/usr/bin/openssl"


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now - 30, "exp": now + 900,
         "aud": "appstoreconnect-v1"},
        open(os.environ["ASC_KEY_PATH"]).read(),
        algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def api(method, path, body=None):
    req = urllib.request.Request(f"{API}/{path}", method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body else None)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} failed ({e.code}): {e.read().decode()[:400]}")


def run(*cmd, ok_fail=False):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 and not ok_fail:
        sys.exit(f"{cmd[0]} failed: {result.stderr.strip()[:300]}")
    return result


def ensure_bundle_id():
    found = api("GET", f"bundleIds?filter[identifier]={BUNDLE_ID}")["data"]
    exact = [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]
    if exact:
        return exact[0]["id"]
    created = api("POST", "bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": "Totem iOS", "platform": "IOS"}}})
    print("registered bundle ID")
    return created["data"]["id"]


def ensure_push_capability(bundle_id_res):
    existing = api("GET", f"bundleIds/{bundle_id_res}/bundleIdCapabilities")["data"]
    if any(c["attributes"]["capabilityType"] == "PUSH_NOTIFICATIONS" for c in existing):
        return
    api("POST", "bundleIdCapabilities", {"data": {"type": "bundleIdCapabilities",
        "attributes": {"capabilityType": "PUSH_NOTIFICATIONS"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id_res}}}}})
    print("enabled push notifications capability")


def ensure_certificate():
    os.makedirs(STATE, exist_ok=True)
    id_file = f"{STATE}/cert_id"
    if os.path.exists(id_file):
        cert_id = open(id_file).read().strip()
        listed = [c for c in api("GET", "certificates?limit=200")["data"]
                  if c["id"] == cert_id]
        if listed:
            import_into_keychain(listed[0])
            return cert_id
    key_path = f"{STATE}/dist.key"
    csr_path = f"{STATE}/dist.csr"
    run(OPENSSL, "genrsa", "-out", key_path, "2048")
    os.chmod(key_path, 0o600)
    run(OPENSSL, "req", "-new", "-key", key_path, "-out", csr_path,
        "-subj", "/CN=Totem Distribution/C=US")
    created = api("POST", "certificates", {"data": {"type": "certificates",
        "attributes": {"certificateType": "DISTRIBUTION",
                       "csrContent": open(csr_path).read()}}})
    open(id_file, "w").write(created["data"]["id"])
    print("created Apple Distribution certificate")
    import_into_keychain(created["data"])
    return created["data"]["id"]


def ensure_keychain():
    # The WWDR downloads below land in STATE.
    os.makedirs(STATE, exist_ok=True)
    if not os.path.exists(KEYCHAIN):
        run("security", "create-keychain", "-p", KEYCHAIN_PASS, KEYCHAIN)
        run("security", "set-keychain-settings", KEYCHAIN)  # never auto-lock
    run("security", "unlock-keychain", "-p", KEYCHAIN_PASS, KEYCHAIN)
    listed = run("security", "list-keychains", "-d", "user").stdout
    if "totem-signing" not in listed:
        existing = [line.strip().strip('"') for line in listed.splitlines() if line.strip()]
        run("security", "list-keychains", "-d", "user", "-s", KEYCHAIN, *existing)
    # Apple's WWDR intermediates, without which codesign cannot build the chain.
    for generation in ("G3", "G4", "G5", "G6"):
        cer = f"{STATE}/wwdr{generation}.cer"
        if not os.path.exists(cer):
            try:
                urllib.request.urlretrieve(
                    f"https://www.apple.com/certificateauthority/AppleWWDRCA{generation}.cer", cer)
            except Exception:
                continue
        run("security", "import", cer, "-k", KEYCHAIN, ok_fail=True)


def import_into_keychain(cert):
    """Import the key and issued cert into the signing keychain, pre-authorized for codesign."""
    cer_path = f"{STATE}/dist.cer"
    pem_path = f"{STATE}/dist.pem"
    p12_path = f"{STATE}/dist.p12"
    open(cer_path, "wb").write(
        base64.b64decode(cert["attributes"]["certificateContent"]))
    run(OPENSSL, "x509", "-inform", "DER", "-in", cer_path, "-out", pem_path)
    run(OPENSSL, "pkcs12", "-export", "-inkey", f"{STATE}/dist.key",
        "-in", pem_path, "-out", p12_path, "-passout", "pass:totem")
    run("security", "import", p12_path, "-k", KEYCHAIN, "-P", "totem",
        "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", ok_fail=True)
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
        "-s", "-k", KEYCHAIN_PASS, KEYCHAIN, ok_fail=True)
    identities = run("security", "find-identity", "-v", "-p", "codesigning", KEYCHAIN).stdout
    if "Apple Distribution" not in identities:
        sys.exit(f"distribution identity missing after import: {identities.strip()[:300]}")


def ensure_appstore_profile(bundle_id_res, cert_id):
    for profile in api("GET",
                       f"profiles?filter[name]={APPSTORE_PROFILE_NAME.replace(' ', '%20')}")["data"]:
        api("DELETE", f"profiles/{profile['id']}")
    created = api("POST", "profiles", {"data": {"type": "profiles",
        "attributes": {"name": APPSTORE_PROFILE_NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_res}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        }}})
    content = base64.b64decode(created["data"]["attributes"]["profileContent"])
    for directory in ("~/Library/MobileDevice/Provisioning Profiles",
                      "~/Library/Developer/Xcode/UserData/Provisioning Profiles"):
        directory = os.path.expanduser(directory)
        os.makedirs(directory, exist_ok=True)
        open(f"{directory}/totem-appstore.mobileprovision", "wb").write(content)
    print("app store profile refreshed")


ensure_keychain()
bundle = ensure_bundle_id()
ensure_push_capability(bundle)
certificate = ensure_certificate()
ensure_appstore_profile(bundle, certificate)
print("provisioning ready")
