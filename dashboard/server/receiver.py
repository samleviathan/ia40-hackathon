#!/usr/bin/env python3
"""Field-capture receiver: accepts page images + metadata + OCR from the iPhone app.

Stdlib only. Advertises itself over Bonjour (_fieldscan._tcp) so the phone finds it
without typing an IP. Every arrival is hashed and appended to data/<batch>/ledger.jsonl.

    python3 receiver.py            # listens on :8765, dashboard at http://localhost:8765
"""
import hashlib
import json
import mimetypes
import queue
import shutil
import signal
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import cloud

PORT = int(os.environ.get("PORT", "8765"))
ROOT = Path(__file__).resolve().parent.parent          # dashboard/
DATA = Path(os.environ.get("DOCHAND_DATA", ROOT / "data"))
DATA.mkdir(parents=True, exist_ok=True)
SAFE = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")
EXT = {"image": "jpg", "meta": "meta.json", "ocr": "ocr.json", "audio": "m4a", "event": "event.json"}
WHISPER = shutil.which("whisper-cli")
MODEL = ROOT / "models" / os.environ.get("WHISPER_MODEL", "ggml-base.en.bin")
NOISE = re.compile(r"^\s*[\[(][^\])]*[\])]\s*$")  # [BLANK_AUDIO], (music), ...
jobs = queue.Queue()
ocr_jobs = queue.Queue()
OCRPROBE = ROOT / "tools" / "ocrprobe"
OCRFULL = ROOT / "tools" / "ocrfull"
WEB = ROOT / "web"
live = []  # the live board's event log for the current session: [{seq, ...}]


def emit(ev):
    """Append an event to the live board stream (pages, OCR, voice, and the agent's decisions)."""
    with lock:
        ev = dict(ev, seq=len(live), ts=time.time())
        live.append(ev)
    return ev

lock = threading.Lock()
pages = {}  # (batch, page_id) -> dict (pages and audio clips)
events = {}  # batch -> {session_start: {...}, session_end: {...}}
latest_batch = None


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def ms(t):
    return None if t is None else round(t * 1000)


def load_existing():
    global latest_batch
    for ledger in sorted(DATA.glob("*/ledger.jsonl"), key=lambda p: p.stat().st_mtime):
        for line in ledger.read_text().splitlines():
            ev = json.loads(line)
            record(ev["batch"], ev["page"], ev["kind"], ev["arrived"], ev["sha256"], ev["bytes"], log=False)
        latest_batch = ledger.parent.name


def record(batch, page_id, kind, arrived, sha, size, log=True):
    global latest_batch
    with lock:
        latest_batch = batch
        p = pages.setdefault((batch, page_id), {"batch": batch, "id": page_id})
        p[f"{kind}_arrived"] = arrived
        p[f"{kind}_sha256"] = sha
        p[f"{kind}_bytes"] = size
        if kind == "meta":
            p["meta"] = json.loads((DATA / batch / f"{page_id}.meta.json").read_text())
        if kind == "event":
            events.setdefault(batch, {})[page_id] = json.loads((DATA / batch / f"{page_id}.event.json").read_text())
        if kind == "audio":
            tx = DATA / batch / f"{page_id}.transcript.json"
            if tx.exists():
                p.update(json.loads(tx.read_text()))
            else:
                jobs.put((batch, page_id))
        if kind == "image" and log and (p.get("meta") or {}).get("status") != "rejected":
            ocr_jobs.put((batch, page_id))
        if kind == "ocr":
            o = json.loads((DATA / batch / f"{page_id}.ocr.json").read_text())
            p["ocr_lines"] = len(o.get("lines", []))
            p["ocr_ms"] = o.get("ocr_ms")
    if log and kind == "event":
        e = events[batch][page_id]
        if page_id == "session_start":
            with lock:
                live.clear()
            emit({"type": "session", "state": "live", "batch": batch})
            cloud.session(batch, "live", device=e.get("device"))
        elif page_id == "session_end":
            summary = f"{e.get('page_count')} pages captured · {e.get('rejected', 0)} retakes"
            emit({"type": "session", "state": "done", "batch": batch, "summary": summary})
            cloud.session(batch, "done", summary=summary)
    if log:
        m = p.get("meta") or {}
        cap = (m.get("timing") or {}).get("captured_at")
        lag = f"{arrived - cap:5.2f}s after capture" if cap else ""
        extra = ""
        if kind == "event":
            extra = json.dumps(events[batch][page_id])
        if kind == "meta" and m.get("type") == "audio":
            extra = f"voice clip {m.get('t_end', 0) - m.get('t_start', 0):.1f}s"
        elif kind == "meta":
            extra = f"page {m.get('number')} {m.get('status')} {','.join(m.get('reasons', []))}"
        if kind == "ocr":
            extra = f"{p.get('ocr_lines')} lines, on-device OCR {p.get('ocr_ms')}ms"
        print(f"{time.strftime('%H:%M:%S')} {batch}/{page_id} {kind:5} {size/1024:7.0f}KB {lag} {extra}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == "/api/mirror":
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            MIRROR.update(jpeg=body, meta=self.headers.get("X-Mirror", ""), at=time.time())
            return self.send(200, {"ok": True})
        if self.path == "/api/agent":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"[]")
            evs = [emit(e) for e in (body if isinstance(body, list) else [body])]
            return self.send(200, {"ok": True, "n": len(evs)})
        parts = self.path.strip("/").split("/")
        if len(parts) != 4 or parts[0] != "upload" or parts[3] not in EXT:
            return self.send(404, {"error": "bad path"})
        _, batch, page_id, kind = parts
        if not (SAFE.match(batch) and SAFE.match(page_id)):
            return self.send(400, {"error": "bad id"})
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        arrived = time.time()
        (DATA / batch).mkdir(exist_ok=True)
        dest = DATA / batch / f"{page_id}.{EXT[kind]}"
        sha = hashlib.sha256(body).hexdigest()
        if dest.exists():
            if hashlib.sha256(dest.read_bytes()).hexdigest() == sha:
                return self.send(200, {"ok": True, "sha256": sha})
            return self.send(409, {"error": "conflicting upload"})
        tmp = dest.with_suffix(dest.suffix + ".part")
        tmp.write_bytes(body)
        tmp.replace(dest)
        with open(DATA / batch / "ledger.jsonl", "a") as f:
            f.write(json.dumps({"batch": batch, "page": page_id, "kind": kind, "arrived": arrived,
                                "sha256": sha, "bytes": len(body)}) + "\n")
        record(batch, page_id, kind, arrived, sha, len(body))
        self.send(200, {"ok": True, "sha256": sha})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, (WEB / "operator.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/events":
            q = dict(kv.split("=", 1) for kv in self.path.partition("?")[2].split("&") if "=" in kv)
            since = int(q.get("since", 0))
            with lock:
                return self.send(200, {"events": live[since:], "next": len(live)})
        if path in ("/live", "/live/"):
            return self.send(200, (WEB / "index.html").read_bytes(), "text/html; charset=utf-8")
        m = re.match(r"^/live/([a-z]+\.(css|js))$", path)
        if m and (WEB / m[1]).is_file():
            return self.send(200, (WEB / m[1]).read_bytes(), "text/css" if m[2] == "css" else "text/javascript")
        if path == "/api/mirror":
            if not MIRROR["jpeg"] or time.time() - MIRROR["at"] > 5:
                return self.send(204, b"")
            self.send_response(200)
            for k, v in (("Content-Type", "image/jpeg"), ("Content-Length", str(len(MIRROR["jpeg"]))),
                         ("Cache-Control", "no-store"), ("X-Mirror", MIRROR["meta"])):
                self.send_header(k, v)
            self.end_headers()
            return self.wfile.write(MIRROR["jpeg"])
        if path == "/ping":
            return self.send(200, {"ok": True, "host": socket.gethostname()})
        if path == "/api/pages":
            q = dict(kv.split("=", 1) for kv in self.path.partition("?")[2].split("&") if "=" in kv)
            with lock:
                batch = q.get("batch") or latest_batch
                rows = [dict(p) for (b, _), p in pages.items() if b == batch]
                batches = sorted({b for b, _ in pages}, reverse=True)
                ev = dict(events.get(batch, {}))
            rows.sort(key=lambda p: (p.get("meta") or {}).get("timing", {}).get("captured_at") or p.get("image_arrived") or 0)
            return self.send(200, {"batch": batch, "batches": batches, "pages": rows, "events": ev})
        m = re.match(r"^/files/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$", path)
        if m and (DATA / m[1] / m[2]).is_file():
            f = DATA / m[1] / m[2]
            return self.send(200, f.read_bytes(), mimetypes.guess_type(f.name)[0] or "application/octet-stream")
        self.send(404, {"error": "not found"})


def transcriber():
    """Serial Whisper worker: m4a -> 16 kHz wav -> whisper.cpp (Metal) -> transcript.json."""
    while True:
        batch, cid = jobs.get()
        base = DATA / batch / cid
        t0 = time.time()
        try:
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", f"{base}.m4a", "-ar", "16000", "-ac", "1",
                            f"{base}.wav"], check=True)
            subprocess.run([WHISPER, "-m", str(MODEL), "-f", f"{base}.wav", "-oj", "-of", f"{base}.whisper", "-np", "-nt"],
                           check=True, capture_output=True)
            segs = json.loads(Path(f"{base}.whisper.json").read_text()).get("transcription", [])
            text = " ".join(s["text"].strip() for s in segs if not NOISE.match(s["text"])).strip()
            out = {"transcript": text, "transcribe_ms": round((time.time() - t0) * 1000), "transcribed_at": time.time(),
                   "asr": f"whisper.cpp {MODEL.name}"}
        except Exception as e:  # keep the worker alive; surface the failure in the UI
            out = {"transcript": "", "transcribe_error": str(e)[:200], "transcribed_at": time.time()}
        Path(f"{base}.transcript.json").write_text(json.dumps(out))
        Path(f"{base}.wav").unlink(missing_ok=True)
        with lock:
            pages.setdefault((batch, cid), {"batch": batch, "id": cid}).update(out)
        if out["transcript"] and not re.match(r"^\W*(uh|um|oh|hmm)\W*$", out["transcript"], re.I):
            emit({"type": "voice", "id": cid, "text": out["transcript"], "action": ""})
            cloud.voice(batch, cid, out["transcript"])
        print(f"{time.strftime('%H:%M:%S')} {batch}/{cid} ASR   {out.get('transcribe_ms', '-')}ms  \"{out['transcript']}\"",
              flush=True)


def reader():
    """Per page: thumbnail for the board, full Apple Vision OCR (text + word boxes, upside-down check),
    readability verdict. Emits page events the live board shows while the agent decides."""
    while True:
        batch, pid = ocr_jobs.get()
        base = DATA / batch / pid
        with lock:
            num = (pages[(batch, pid)].get("meta") or {}).get("number")
        subprocess.run(["sips", "-Z", "700", f"{base}.jpg", "--out", f"{base}.thumb.jpg"], capture_output=True)
        img = f"/files/{batch}/{pid}.thumb.jpg"
        emit({"type": "page", "n": num, "id": pid, "img": img, "state": "reading"})
        try:
            r = json.loads(subprocess.run([str(OCRFULL), f"{base}.jpg"], capture_output=True, text=True,
                                          timeout=90).stdout.strip().splitlines()[-1])
            Path(f"{base}.full.json").write_text(json.dumps(r))
            words, rate = r["words"], r["real_word_rate"]
            # Judge by Vision's own line confidence, not dictionary hits: numbers, names and plurals
            # are missing from /usr/share/dict/words, so clear tables and short pages looked unreadable.
            # On 87 pages: blurry/faint 0.38-0.66, clear >= 0.77.
            conf = sum(l["conf"] for l in r["lines"]) / max(1, len(r["lines"]))
            verdict = "few words" if words < 30 else ("READS" if conf >= 0.7 else "DID NOT READ - retake")
            snippet = next((l["text"] for l in r["lines"] if len(l["text"]) > 12), "")
            out = {"read_words": words, "read_rate": round(rate, 2), "read_verdict": verdict, "read_ms": r["ms"],
                   "orientation": r["orientation"]}
        except Exception as e:
            out, snippet = {"read_verdict": f"check failed: {e}"[:120], "read_words": 0}, ""
        with lock:
            pages.setdefault((batch, pid), {"batch": batch, "id": pid}).update(out)
        emit({"type": "page", "n": num, "id": pid, "img": img, "state": "read", "words": out.get("read_words"),
              "snippet": snippet, "verdict": out.get("read_verdict")})
        if out.get("read_words"):
            with lock:
                p = pages[(batch, pid)]
            cloud.page(base, batch, pid, num, p.get("image_sha256", ""),
                       ((p.get("meta") or {}).get("timing") or {}).get("captured_at"))
        print(f"{time.strftime('%H:%M:%S')} {batch}/{pid} READ  page {num}: {out.get('read_verdict')} "
              f"({out.get('read_words', '-')} words, {int(out.get('read_rate', 0) * 100)}% real) -> {base}.full.json", flush=True)


MIRROR = {"jpeg": None, "meta": "", "at": 0.0}   # latest phone preview frame (app-side mirror)


def usb_ip():
    """The Mac's address on the iPhone's USB link (169.254.x.x on an en* port other than Wi-Fi)."""
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    iface = None
    for line in out.splitlines():
        if line and not line[0].isspace():
            iface = line.split(":")[0]
        elif iface and iface.startswith("en") and iface != "en0":
            m = re.search(r"inet (169\.254\.\d+\.\d+)", line)
            if m:
                return m[1]
    return None


def advertise(ip):
    return subprocess.Popen(["dns-sd", "-R", f"FieldScan {socket.gethostname().split('.')[0]}",
                             "_fieldscan._tcp", "local", str(PORT), f"ip={ip}", f"port={PORT}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def mirror_decisions(d):
    """Show production's triage decisions (dashboard/prod) on the local board too."""
    for doc in d.get("docs", []):
        actions = [{k: v for k, v in a.items() if v} for a in doc.get("actions", [])]
        emit({**doc, "type": "doc", "fields": {f["name"]: f["value"] for f in doc.get("fields", [])}, "actions": actions})
    for e in d.get("entities", []):
        emit({"type": "entity", **e})
    for i in d.get("issues", []):
        emit({"type": "issue", **i})
    if d.get("narration"):
        emit({"type": "narration", "text": d["narration"]})


def stop(*_):
    raise KeyboardInterrupt


def main():
    if WHISPER and MODEL.exists():
        threading.Thread(target=transcriber, daemon=True).start()
    else:
        print(f"WARNING: no transcription (whisper-cli={WHISPER}, model exists={MODEL.exists()})", flush=True)
    threading.Thread(target=reader, daemon=True).start()
    cloud.start(on_decisions=mirror_decisions)
    load_existing()
    # DOCHAND_ADVERTISE_IP: "usb" follows the iPhone's USB link, "off" skips Bonjour (e.g. a second
    # receiver for testing), anything else is the address to advertise. Default: the LAN address.
    want = os.environ.get("DOCHAND_ADVERTISE_IP", os.environ.get("FIELD_CAPTURE_ADVERTISE_IP", ""))
    pick = lambda: (usb_ip() or lan_ip()) if want == "usb" else (lan_ip() if want in ("", "off") else want)
    ip = pick()
    # Bonjour advertisement via the built-in macOS dns-sd tool; TXT carries the IPv4 address.
    adv = advertise(ip) if want != "off" else None
    # Stop the dns-sd child on `kill` too, or a stale advert outlives the receiver.
    signal.signal(signal.SIGTERM, stop)

    def follow():
        # DOCHAND_ADVERTISE_IP=usb: the USB link's address changes on every reconnect, so
        # re-advertise when it does. The app looks the laptop up again after failed uploads.
        nonlocal adv, ip
        while True:
            time.sleep(2)
            now = pick()
            if now != ip:
                adv.terminate()
                ip, adv = now, advertise(now)
                print(f"{time.strftime('%H:%M:%S')} advertising {ip}:{PORT}", flush=True)
    if want == "usb":
        threading.Thread(target=follow, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"receiver on http://{ip}:{PORT}  (dashboard: http://localhost:{PORT})  data: {DATA}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if adv:
            adv.terminate()


if __name__ == "__main__":
    sys.exit(main())
