# DocHand dashboard

The Mac side: a stdlib Python receiver that stores every upload, OCRs each page with Apple Vision,
transcribes voice notes with Whisper, and streams events to the live board. An agent reads the
stream and posts filing decisions back.

| Path | Role |
|---|---|
| `server/receiver.py` | HTTP server: uploads, ledger, Bonjour advert, OCR and Whisper workers, event stream, board |
| `server/watch.py` | Feed for a live agent: one line per read page (with OCR text), voice clip and session change |
| `server/agent.py` | `show` a page's OCR text; `post` decisions to the board |
| `server/cloud.py` | Forwards pages, voice notes and sessions to production when `DOCHAND_CLOUD_URL` is set |
| `tools/*.swift` | `ocrfull` (Vision OCR with word boxes and upside-down check), `ocrprobe` (readability), `phonescreen` (USB screen mirror) |
| `web/index.html`, `app.css`, `app.js` | Live board at `/live/`. Opened as a file it replays `web/events.js` |
| `web/operator.html` | Operator view at `/`: every capture, latency, OCR verdicts |
| [`prod/`](prod/) | Production: OpenAI Agents SDK triage per page, private Vercel Blob and Neon Postgres storage |

## Run

```sh
tools/build.sh                                            # once
DOCHAND_ADVERTISE_IP=usb python3 -u server/receiver.py | tee -a receiver.log
```

| Env | Default | Meaning |
|---|---|---|
| `PORT` | 8765 | Listen port |
| `DOCHAND_ADVERTISE_IP` | LAN address | `usb` follows the iPhone's USB link; `off` skips Bonjour (use for a second, test receiver) |
| `DOCHAND_DATA` | `dashboard/data` | Where uploads, OCR and transcripts are written |
| `DOCHAND_CLOUD_URL`, `DOCHAND_INGEST_TOKEN` | unset | Forward to production and mirror its agent's decisions here (see `prod/`) |
| `WHISPER_MODEL` | `ggml-base.en.bin` | Model file in `dashboard/models/` (from huggingface ggerganov/whisper.cpp) |

Prerequisites: `whisper-cli` (Homebrew whisper-cpp), `ffmpeg`, and the compiled tools. Restarting
the receiver clears the board; its event log is in memory, while files on disk are kept.

## Manual agent loop

```sh
python3 -u server/watch.py                 # follow pages as they are read
python3 server/agent.py show <batch> <page_id>
python3 server/agent.py post '<event json or list>'
```

In production the agent is an API call instead; see [`prod/`](prod/).

## Event stream (`GET /api/events?since=N`, `POST /api/agent`)

From the receiver: `session {state}` · `page {n, img, state: reading|read, words, snippet, verdict}` · `voice {text, action}`.

From the agent:

- `doc {id, box, boxkey, title, doctype, date, pages[] (reading order), status: open|complete, fields{}, note, summary?, actions?, access?}`
  Re-posting the same id updates it; that is how reordering and reuniting pages show.
  `actions` is `[{text, due?: YYYY-MM-DD, detail?}]`; fields named like "Action needed" also count.
  `access` is `{level: public|internal|restricted|privileged, parties[], reason}`, shown through **Viewing as**. It is a view, not enforcement.
- `entity {name, etype: person|org|agency|address, doc, seen}`
- `issue {sev: high|med|low, doc, text}`
- `narration {text}`

## The board

- **Board**: recently added pages, documents grouped by folder (box), people and organizations, issues, agent feed, phone mirror.
- **Files**: folders, files named `<date>_<title>.pdf`, and data models (the union of fields per document type).
- **Wide view** (click a document): the scan with OCR word boxes (B toggles, arrows change page) beside the summary, action items with due dates, issues, every extracted field, entities and file details.

## Measured

| Stage | Time |
|---|---|
| Shutter → Mac (12 / 48 MP) | ~0.9 s / ~1.8 s |
| Apple Vision OCR (M3 Pro) | 0.25-0.65 s per page |
| Whisper base.en per clip | 0.3-0.5 s |
| Agent decision (one API call per page) | target 2-4 s |
| Operator pace | ~3.3 s per page |

"Did it read": ≥ 30 words and mean Vision line confidence ≥ 0.70. On 87 pages, blurry or faint
pages scored 0.38-0.66 and clear ones ≥ 0.77.
