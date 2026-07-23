#!/bin/bash
# Mac mini signing worker for a remotely-hosted (Railway) server: polls for
# device-registration jobs, registers the devices, builds a fresh ad-hoc IPA,
# and uploads it. The server serves the IPA and update feed; this machine
# only needs outbound HTTPS.
#   worker.sh             poll loop (run this from the LaunchAgent)
#   worker.sh --publish   build + upload once, no device registration
# Env: SERVER_URL, SIGNER_SECRET, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
set -euo pipefail
cd "$(dirname "$0")"
: "${SERVER_URL:?SERVER_URL is not set}"
: "${SIGNER_SECRET:?SIGNER_SECRET is not set}"
AUTH=(-H "Authorization: Bearer $SIGNER_SECRET")
mkdir -p build

ensure_venv() {
    if [ ! -d .venv ]; then
        python3 -m venv .venv
        ./.venv/bin/pip -q install PyJWT cryptography
    fi
}

build_and_upload() {
    ONBOARD_BASE_URL="$SERVER_URL" ./sign.sh --rebuild
    local build_number
    build_number="$(cat build/version.txt)"
    curl -fsS "${AUTH[@]}" -T build/totem.ipa \
        "$SERVER_URL/signer/ipa?build=$build_number" > /dev/null
    echo "published build $build_number"
}

if [ "${1:-}" = "--publish" ]; then
    build_and_upload
    exit 0
fi

echo "watching $SERVER_URL for signing jobs…"
while true; do
    # Long-poll: the server holds this open and answers the moment a friend
    # registers, so jobs are effectively pushed over our outbound connection.
    UDIDS="$(curl -fsS --max-time 70 "${AUTH[@]}" "$SERVER_URL/signer/jobs?wait=true" \
        | /usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["udids"]))' \
        2>/dev/null || { sleep 5; true; })"
    if [ -n "$UDIDS" ]; then
        echo "jobs: $UDIDS"
        if {
            ensure_venv
            while IFS= read -r udid; do
                ./.venv/bin/python register_device.py "$udid"
            done <<< "$UDIDS"
            build_and_upload
        } > build/worker.log 2>&1; then
            echo "done"
        else
            tail -c 2000 build/worker.log | curl -fsS "${AUTH[@]}" -X POST \
                --data-binary @- "$SERVER_URL/signer/fail" > /dev/null || true
            echo "failed; log tail reported to server"
        fi
    fi
done
