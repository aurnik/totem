"""A scripted Totem user for exercising presence from a terminal.

    buddybot.py <server> <handle> whoami            login (creates the account) and print buddies
    buddybot.py <server> <handle> request <target>  send <target> a friend request
    buddybot.py <server> <handle> session <secs>    sign on, stay for <secs>, sign off

Auth is the dev handle login, so any handle works; use one nobody owns.
"""
import asyncio
import json
import sys
import urllib.request

import websockets


def post(server, path, body, token=None):
    req = urllib.request.Request(f"{server}/{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else None


def get(server, path, token):
    req = urllib.request.Request(f"{server}/{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


async def session(server, token, seconds):
    ws_url = server.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
    # Frames are binary on the wire; the gateway ignores text.
    async with websockets.connect(ws_url, additional_headers={"Authorization": f"Bearer {token}"}) as ws:
        welcome = json.loads(await ws.recv())
        me = welcome.get("welcome", {}).get("self_")
        print(f"signed on as {me}", flush=True)
        elapsed = 0
        while elapsed < seconds:
            step = min(20, seconds - elapsed)
            await asyncio.sleep(step)
            elapsed += step
            await ws.send(json.dumps({"heartbeat": {}}).encode())
        await ws.send(json.dumps({"signOff": {}}).encode())
        await asyncio.sleep(0.5)
    print("signed off", flush=True)


def main():
    server, handle, command = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
    token = post(server, "auth/dev", {"handle": handle})["token"]
    if command == "whoami":
        for b in get(server, "buddies", token):
            print(b["user"]["handle"], b["status"])
    elif command == "request":
        post(server, "buddies/requests", {"handle": sys.argv[4]}, token)
        print(f"requested {sys.argv[4]}")
    elif command == "session":
        asyncio.run(session(server, token, int(sys.argv[4])))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
