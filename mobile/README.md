# DocHand mobile

iPhone capture app. It watches for a page, fires the shutter when the page is still and clear,
straightens it, and uploads it to the Mac receiver. An always-on mic records short voice notes
("new box: Springfield", "that was the back page") that the agent uses as hints.

| File | Role |
|---|---|
| `FieldCapture/CaptureEngine.swift` | Camera, live page detection, auto-shutter state machine, hand-in-frame gate |
| `FieldCapture/PageProcessor.swift` | Straighten, quality metrics (sharpness, weakest region, glare, ink), JPEG, optional on-phone OCR |
| `FieldCapture/AudioRecorder.swift` | Always-on mic, level-gated speech clips (.m4a), noise filter |
| `FieldCapture/Uploader.swift` | Disk-backed outbox, serial retrying uploads, Bonjour discovery of the receiver |
| `FieldCapture/AppModel.swift`, `ContentView.swift` | Session Start/Stop, Next/Rescan cue, minimal UI, settings sheet |
| `FieldCapture/Models.swift` | Upload and metadata types |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated and git-ignored |
| `build.sh` | Generate, build, install and launch on the first paired iPhone (or `DEVICE=<udid>`) |

## Build

Needs Xcode and `xcodegen` (`brew install xcodegen`). `build.sh` builds with `-sdk iphoneos` and
no destination, which avoids Xcode 26's 8 GB simulator download. Set `DEVELOPMENT_TEAM` to your Apple team ID. A free
(personal) team's signature lasts 7 days; rerun `build.sh` after that.

## Finding the receiver

The app looks up `_fieldscan._tcp` over Bonjour; the receiver puts its IPv4 address in the TXT
record. Hotel and conference Wi-Fi often block device-to-device traffic, so use the USB cable:
run the receiver with `DOCHAND_ADVERTISE_IP=usb` and it advertises the USB link's address, following
it across reconnects. A host typed in settings (long-press the page count) overrides Bonjour.

The app also posts ~10 preview frames a second, with its page count, cue, page outline and
Start/Stop state, to `POST /api/mirror`, so the board can show the phone screen.

## Upload contract

| Call | Body |
|---|---|
| `POST /upload/<batch>/<id>/meta` | JSON. Pages: `type:"page"`, number, status, reasons, metrics, quad, image dims + sha256, timing (`captured_at` = phone clock). Clips: `type:"audio"`, `t_start`, `t_end`, `peak_db` |
| `POST /upload/<batch>/<id>/image` | Straightened page JPEG |
| `POST /upload/<batch>/<id>/audio` | Speech clip .m4a |
| `POST /upload/<batch>/<id>/ocr` | Optional on-phone OCR (off by default) |
| `POST /upload/<batch>/session_start\|session_end/event` | `session_end` carries `page_count`, `captures`, `rejected`, `audio_clips` |

## Tuned values

| Setting | Value | Evidence |
|---|---|---|
| Resolution | 48 MP stills | 12 MP gave ~190 dpi at typical framing; 48 MP gives ~350-550 dpi |
| Auto-shutter | still 0.25 s, corner jitter ≤ 3 %, motion ≤ 4, page ≥ 8 % of frame | 0.35 s felt slow; 0.2 s fired mid-flip |
| Hand gate | never fire while Vision sees a hand | Removed every double-shot and mid-flip capture |
| Blur (page) | mean of top-2000 \|Laplacian\| ≥ 105 | Blurry 20-93, sharp 120-358 |
| Blur (weakest region) | 3×3 grid, text regions only, ≥ 60 | Handheld tilt leaves one corner soft |
| Glare | pixels ≥ max(paper+35, 245) > 1 % | Clean pages score ≤ 0.11 % |
| Cut-off | a corner within 0.6 % of the frame edge | Rejected a book detected as a page |
| Mic | open a clip at −30 dBFS, keep if peak ≥ −22 dBFS | Real speech ≥ −19.7 dB; noise ≤ −20.7 dB |

The phone only guarantees what can't be fixed later (blur, glare, cut-off, a hand over text,
resolution). Order, rotation, cropping and duplicates are fixed on the Mac.
