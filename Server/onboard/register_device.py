"""Register a device UDID with App Store Connect (idempotent)."""
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

udid = sys.argv[1]
now = int(time.time())
token = jwt.encode(
    {"iss": os.environ["ASC_ISSUER_ID"], "iat": now - 30, "exp": now + 900,
     "aud": "appstoreconnect-v1"},
    open(os.environ["ASC_KEY_PATH"]).read(),
    algorithm="ES256",
    headers={"kid": os.environ["ASC_KEY_ID"]},
)

request = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/devices",
    data=json.dumps({"data": {"type": "devices", "attributes": {
        "name": f"onboard-{udid[-6:]}", "udid": udid, "platform": "IOS",
    }}}).encode(),
    headers={"Authorization": f"Bearer {token}",
             "Content-Type": "application/json"},
)
try:
    urllib.request.urlopen(request)
    print(f"registered device {udid}")
except urllib.error.HTTPError as error:
    body = error.read().decode()
    # 409 with ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE = already registered.
    if error.code == 409 and "DUPLICATE" in body.upper():
        print(f"device {udid} already registered")
    else:
        sys.exit(f"device registration failed ({error.code}): {body}")
