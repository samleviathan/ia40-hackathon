import AVFoundation
import SwiftUI
import UIKit

final class AppModel: ObservableObject {
    let engine = CaptureEngine()
    let audio = AudioRecorder()
    let uploader: Uploader
    let processor: PageProcessor

    @Published var pages: [PageRecord] = []
    @Published var accepted = 0
    @Published var message = "Press Start to begin a session"
    @Published var flash: Color?
    @Published var receiver = "Looking for laptop…"
    @Published var queued = 0
    @Published var debug = ""
    @Published var running = false
    enum Cue { case next, rescan }
    @Published var cue: Cue?
    @Published var cueTick = 0
    @Published var offline = false
    @Published var micDB: Float = -160
    @Published var micOpen = false
    @Published var clips = 0
    @Published var showDebug = true
    @Published var tuning = Tuning.load() {
        didSet {
            tuning.save(); engine.setTuning(tuning); processor.setTuning(tuning)
            audio.thresholdDB = Float(tuning.micThresholdDB)
        }
    }
    @Published var manualHost = UserDefaults.standard.string(forKey: "host") ?? ""

    private(set) var batch = AppModel.newBatchID()
    private let impact = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        let u = Uploader()
        uploader = u
        processor = PageProcessor(uploader: u)

        engine.setPage(batch: batch, number: 1)
        engine.onPhoto = { [weak self] data, ctx in self?.processor.process(data, ctx) }
        engine.onShutter = { [weak self] ctx in self?.shutter(ctx) }
        engine.onDuplicate = { [weak self] in
            self?.message = "Same page — flip to the next one"
            self?.setCue(.next)
            self?.notify.notificationOccurred(.warning)
        }
        engine.onDebug = { [weak self] s in self?.debug = s }
        engine.onError = { [weak self] s in self?.message = s }
        processor.onResult = { [weak self] id, status, reasons, thumb in self?.result(id, status, reasons, thumb) }
        processor.onOCR = { [weak self] id, _ in self?.update(id) { $0.ocrDone = true } }
        uploader.onSent = { [weak self] page, kind in
            self?.update(page) { p in
                if kind == "image" { p.imageSent = true }
                if kind == "ocr" { p.ocrSent = true }
            }
        }
        uploader.onState = { [weak self] label, n in
            self?.receiver = label; self?.queued = n
            self?.offline = label.hasPrefix("Offline") || label.hasPrefix("Retrying")
        }
        engine.onMirror = { [weak self] jpeg, quad, state in
            DispatchQueue.main.async {
                guard let self else { return }
                var m: [String: Any] = ["count": self.accepted, "running": self.running, "state": state, "offline": self.offline]
                if let c = self.cue { m["cue"] = c == .rescan ? "rescan" : "next" }
                if let q = quad { m["quad"] = q.points.map { [Double($0.x), Double(1 - $0.y)] } }
                if let d = try? JSONSerialization.data(withJSONObject: m) { self.uploader.mirror(jpeg, meta: d.base64EncodedString()) }
            }
        }
        uploader.start(manualHost: manualHost)
        audio.thresholdDB = Float(tuning.micThresholdDB)
        audio.onLevel = { [weak self] db, open in self?.micDB = db; self?.micOpen = open }
        audio.onClip = { [weak self] clip in self?.sendClip(clip) }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        impact.prepare()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok { self.engine.start() } else { self.message = "Camera access denied — enable it in Settings" }
            }
        }
    }

    func manualCapture() { if running { engine.requestManual() } }

    /// Start hands the job to the system: new session, camera armed, mic open.
    func startSession() {
        batch = Self.newBatchID()
        pages = []
        accepted = 0
        clips = 0
        engine.setPage(batch: batch, number: 1)
        engine.resetGuard()
        sendEvent("session_start", [:])
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                guard self.running else { return }
                if ok {
                    do { try self.audio.start() } catch { self.message = "Mic failed: \(error.localizedDescription)" }
                } else {
                    self.message = "Mic access denied — pages only"
                }
            }
        }
        engine.setPaused(false)
        running = true
        cue = .next
        message = "Scanning — feed pages, talk any time"
    }

    /// Stop: disarm, close the last audio clip, and tell the laptop how many pages to expect.
    func stopSession() {
        engine.setPaused(true)
        audio.stop()
        running = false
        message = "Finishing…"
        // Let the audio queue flush its last clip, and let pages still being checked settle, so
        // the page_count in session_end matches what the laptop will receive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.sendEndWhenSettled(0) }
    }

    private func sendEndWhenSettled(_ tries: Int) {
        if pages.contains(where: { $0.status == .processing }) && tries < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.sendEndWhenSettled(tries + 1) }
            return
        }
        let rejected = pages.filter { $0.status == .rejected }.count
        let good = pages.filter { $0.status == .accepted }.count
        sendEvent("session_end", ["page_count": good, "captures": pages.count,
                                  "rejected": rejected, "audio_clips": clips])
        message = "Session ended: \(good) pages"
    }

    private func sendEvent(_ name: String, _ extra: [String: Any]) {
        var e = extra
        e["type"] = name
        e["batch"] = batch
        e["t"] = Date().timeIntervalSince1970
        e["device"] = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
        if let d = try? JSONSerialization.data(withJSONObject: e) {
            uploader.add(batch: batch, page: name, kind: "event", data: d)
        }
    }

    /// Called on the audio queue.
    private func sendClip(_ clip: AudioRecorder.Clip) {
        guard let data = try? Data(contentsOf: clip.url) else { return }
        try? FileManager.default.removeItem(at: clip.url)
        DispatchQueue.main.async {
            self.clips += 1
            let id = String(format: "a%04d-", self.clips) + UUID().uuidString.prefix(6).lowercased()
            let meta: [String: Any] = ["type": "audio", "id": id, "batch": self.batch,
                                       "t_start": clip.tStart, "t_end": clip.tEnd,
                                       "peak_db": Double(clip.peakDB), "bytes": data.count]
            if let m = try? JSONSerialization.data(withJSONObject: meta) {
                self.uploader.add(batch: self.batch, page: id, kind: "meta", data: m)
            }
            self.uploader.add(batch: self.batch, page: id, kind: "audio", data: data)
        }
    }

    func setHost(_ h: String) {
        manualHost = h
        UserDefaults.standard.set(h, forKey: "host")
        uploader.start(manualHost: h)
    }

    // MARK: events (main)

    private func shutter(_ c: CaptureContext) {
        impact.impactOccurred()
        impact.prepare()
        guard running else { return }
        pages.insert(PageRecord(id: c.id, number: c.number), at: 0)
        if pages.count > 80 { pages.removeLast(pages.count - 80) }
        message = "Page \(c.number) — flip"
        blink(.white)
    }

    private func result(_ id: String, _ status: PageStatus, _ reasons: [String], _ thumb: UIImage?) {
        update(id) { p in p.status = status; p.reasons = reasons; p.thumb = thumb }
        guard let p = pages.first(where: { $0.id == id }) else { return }
        if status == .accepted {
            accepted = max(accepted, p.number)
            message = reasons.contains("blank") ? "Page \(p.number) ✓ (blank)" : "Page \(p.number) ✓"
            setCue(.next)
            blink(.green)
        } else {
            engine.rewind(to: p.number)
            engine.retakeLast()
            message = "Retake page \(p.number): \(reasons.joined(separator: ", "))"
            setCue(.rescan)
            notify.notificationOccurred(.error)
            blink(.red)
        }
    }

    private func setCue(_ c: Cue) { cue = c; cueTick += 1 }

    private func update(_ id: String, _ change: (inout PageRecord) -> Void) {
        if let i = pages.firstIndex(where: { $0.id == id }) { change(&pages[i]) }
    }

    private func blink(_ c: Color) {
        flash = c
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { if self.flash == c { self.flash = nil } }
    }

    static func newBatchID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "b" + f.string(from: Date())
    }
}
