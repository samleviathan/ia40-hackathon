#!/usr/bin/env python3
"""Feed for the live agent: one line per page read, voice clip, and session change.

    python3 -u watch.py            # follows http://127.0.0.1:8765/api/events

Each read page is printed with the first lines of its OCR text, so the agent can file it
and post decisions with `agent.py post` without another lookup. Survives receiver restarts.
"""
import json
import os
import time
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("DOCHAND_DATA", Path(__file__).resolve().parent.parent / "data"))
since, down = 0, False
while True:
    try:
        r = json.load(urllib.request.urlopen(f"http://127.0.0.1:8765/api/events?since={since}", timeout=5))
        if down:
            print("RECEIVER back up", flush=True)
            down = False
    except Exception as e:
        if not down:
            print(f"RECEIVER DOWN: {e}", flush=True)
            down = True
        time.sleep(2)
        continue
    if r["next"] < since:  # receiver restarted, its event log starts over
        since = 0
        continue
    for e in r["events"]:
        t = e.get("type")
        if t == "session":
            print(f"SESSION {e.get('state')} batch={e.get('batch')}", flush=True)
        elif t == "page" and e.get("state") == "read":
            batch = e["img"].split("/")[2]
            f = DATA / batch / f"{e['id']}.full.json"
            text = " | ".join(l["text"] for l in json.loads(f.read_text())["lines"][:14])[:700] if f.exists() else ""
            print(f"PAGE #{e['n']} {e['id']} batch={batch} {e.get('verdict')} {e.get('words')}w :: {text}", flush=True)
        elif t == "voice":
            print(f"VOICE: {e.get('text')}", flush=True)
    since = r["next"]
    time.sleep(0.7)
