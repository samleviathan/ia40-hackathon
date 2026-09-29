"""Forward the receiver's work to DocHand production (dashboard/prod on Vercel).

Enabled when DOCHAND_CLOUD_URL is set (with DOCHAND_INGEST_TOKEN). The Mac still does capture,
OCR and Whisper; production stores files in private Vercel Blob, rows in Neon, and runs the
OpenAI triage agent per page. Its decisions come back and are mirrored onto the local board.

Calls run on one background worker, in order, so a slow agent call never blocks uploads.
"""
import json
import os
import queue
import threading
import urllib.request
import uuid
from pathlib import Path

URL = os.environ.get("DOCHAND_CLOUD_URL", "").rstrip("/")
TOKEN = os.environ.get("DOCHAND_INGEST_TOKEN", "")
enabled = bool(URL and TOKEN)
_jobs = queue.Queue()


def _post(path, body, ctype, timeout=90):
    req = urllib.request.Request(f"{URL}{path}", data=body, method="POST",
                                 headers={"Content-Type": ctype, "Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def _multipart(fields, files):
    """fields: {name: str}; files: {name: (filename, bytes, content_type)}."""
    b = uuid.uuid4().hex
    out = []
    for k, v in fields.items():
        out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    for k, (fn, data, ct) in files.items():
        out.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"; filename="{fn}"\r\n'
                   f"Content-Type: {ct}\r\n\r\n".encode() + data + b"\r\n")
    out.append(f"--{b}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={b}"


def _worker(on_decisions):
    while True:
        kind, args = _jobs.get()
        try:
            if kind == "page":
                base, fields = args
                body, ctype = _multipart(fields, {
                    "image": (base.name + ".jpg", Path(f"{base}.jpg").read_bytes(), "image/jpeg"),
                    "thumb": (base.name + ".thumb.jpg", Path(f"{base}.thumb.jpg").read_bytes(), "image/jpeg"),
                    "ocr": (base.name + ".full.json", Path(f"{base}.full.json").read_bytes(), "application/json"),
                })
                r = _post("/api/ingest/page", body, ctype)
                if on_decisions and r.get("decisions"):
                    on_decisions(r["decisions"])
            else:
                _post(f"/api/ingest/{kind}", json.dumps(args).encode(), "application/json", timeout=15)
        except Exception as e:  # production is best-effort; the local board keeps working
            print(f"cloud {kind} failed: {e}", flush=True)


def start(on_decisions=None):
    """on_decisions(decisions) is called with the agent's output for each page."""
    if enabled:
        threading.Thread(target=_worker, args=(on_decisions,), daemon=True).start()
        print(f"cloud: forwarding to {URL}", flush=True)


def page(base, batch, page_id, n, sha256, captured_at=None):
    if enabled:
        _jobs.put(("page", (Path(base), {"batch": batch, "page_id": page_id, "n": n, "sha256": sha256,
                                          **({"captured_at": captured_at} if captured_at else {})})))


def voice(batch, clip_id, text):
    if enabled:
        _jobs.put(("voice", {"batch": batch, "clip_id": clip_id, "text": text}))


def session(batch, state, device=None, summary=None):
    if enabled:
        _jobs.put(("session", {"batch": batch, "state": state, "device": device, "summary": summary}))
