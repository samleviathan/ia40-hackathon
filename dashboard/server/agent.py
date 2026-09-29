#!/usr/bin/env python3
"""Helper for the human-in-the-loop agent driving the live board.

    agent.py show <batch> <page_id> [...]   print OCR text of pages (compact)
    agent.py post '<json event or list>'    push decisions to the live board
"""
import json
import os
import sys
import urllib.request
from pathlib import Path

DATA = Path(os.environ.get("DOCHAND_DATA", Path(__file__).resolve().parent.parent / "data"))


def show(batch, pids):
    for pid in pids:
        f = DATA / batch / f"{pid}.full.json"
        m = json.loads((DATA / batch / f"{pid}.meta.json").read_text())
        if not f.exists():
            print(f"== {pid} (#{m['number']}) no OCR yet")
            continue
        r = json.loads(f.read_text())
        print(f"== {pid} (#{m['number']}) {r['words']} words, {int(r['real_word_rate'] * 100)}% real, {r['orientation']}")
        print("\n".join(l["text"] for l in r["lines"]))


def post(payload):
    req = urllib.request.Request("http://127.0.0.1:8765/api/agent", data=payload.encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    print(urllib.request.urlopen(req, timeout=5).read().decode())


if __name__ == "__main__":
    if sys.argv[1] == "show":
        show(sys.argv[2], sys.argv[3:])
    else:
        post(sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read())
