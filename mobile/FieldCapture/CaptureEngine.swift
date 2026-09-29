import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import Vision

/// Camera + live page detection + the auto-shutter state machine.
///
///   searching ──page found──▶ stabilizing ──still for stableSeconds──▶ capturing
///       ▲                                                                 │ shutter done (haptic)
///       └──── page gone / scene changed ◀──── waiting ◀────────────────────┘
///
/// All state lives on `videoQueue`. Callbacks are delivered on the main queue, except
/// `onPhoto`, which arrives on the photo-output queue and must hand off immediately.
final class CaptureEngine: NSObject {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let videoQueue = DispatchQueue(label: "capture.video", qos: .userInteractive)

    var onOverlay: ((Quad?, OverlayState, CGSize) -> Void)?
    var onDebug: ((String) -> Void)?
    var onShutter: ((CaptureContext) -> Void)?
    var onDuplicate: (() -> Void)?
    var onError: ((String) -> Void)?
    var onPhoto: ((Data, CaptureContext) -> Void)?

    private enum Phase { case searching, stabilizing(CFTimeInterval), capturing, waiting }

    // videoQueue state
    private var tuning = Tuning.load()
    private var phase = Phase.searching
    private var lastQuad: Quad?
    private var lastSig: [UInt8]?
    private var waitRef: [UInt8]?      // scene at the last capture; big change re-arms
    private var dupRef: [UInt8]?       // scene of the last capture (fallback duplicate check for blank pages)
    private var dupPage: PageSig?      // ink layout of the last captured page (primary duplicate check)
    private var currentPB: CVPixelBuffer?
    private var lastSim: Double = -1
    private var handPresent = false
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var retake = false
    private var absent = 0
    private var paused = true   // armed only between Start and Stop
    /// ~10 fps downscaled preview JPEG plus the outline and its state, for the laptop's phone mirror.
    var onMirror: ((Data, Quad?, String) -> Void)?
    private let mirrorQueue = DispatchQueue(label: "mirror")
    private let mirrorCtx = CIContext()
    private var mirrorBusy = false, lastMirror = 0.0
    private var mirrorQuad: Quad?, mirrorState = "paused"
    private var manual = false
    private var batch = ""
    private var number = 1
    private var portrait = CGSize(width: 3, height: 4)
    private var frames = 0
    private var fpsStart: CFTimeInterval = 0
    private var fps = 0.0
    private var lastDebug: CFTimeInterval = 0

    private var standardDims: CMVideoDimensions?
    private var device: AVCaptureDevice?   // sessionQueue
    private var torchWanted = false        // sessionQueue
    private let lock = NSLock()
    private var inflight: [Int64: CaptureContext] = [:]

    // MARK: control

    func start() {
        sessionQueue.async { [self] in
            if session.inputs.isEmpty { configure() }
            if !session.isRunning { session.startRunning() }
            applyTorch()
        }
    }

    func stop() { sessionQueue.async { self.session.stopRunning() } }
    func setTuning(_ t: Tuning) { videoQueue.async { self.tuning = t } }
    func setPage(batch: String, number: Int) { videoQueue.async { self.batch = batch; self.number = number } }
    func setPaused(_ p: Bool) {
        videoQueue.async { self.paused = p; self.phase = .searching }
        // Torch on while armed: even light across the page, no room-light shadows.
        sessionQueue.async { self.torchWanted = !p; self.applyTorch() }
    }
    func requestManual() { videoQueue.async { self.manual = true } }

    /// Last capture was rejected: allow the same page again, and re-arm on any small movement.
    func retakeLast() { videoQueue.async { self.dupRef = nil; self.dupPage = nil; self.retake = true } }

    /// A capture was rejected: reuse its page number, unless another capture already moved past it.
    func rewind(to n: Int) { videoQueue.async { if self.number == n + 1 { self.number = n } } }

    /// New batch: forget the previous page entirely.
    func resetGuard() { videoQueue.async { self.dupRef = nil; self.dupPage = nil; self.waitRef = nil; self.phase = .searching } }

    private func applyTorch() {
        guard let d = device, d.hasTorch, d.isTorchAvailable, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if torchWanted {
            try? d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else if d.torchMode != .off {
            d.torchMode = .off
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        // The mic is owned by AudioRecorder; keep the capture session from reconfiguring audio.
        session.automaticallyConfiguresApplicationAudioSession = false
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.onError?("No back camera available") }
            return
        }
        session.addInput(input)
        self.device = device
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        // The iPhone 15 main camera offers 12 MP and 48 MP here. Enable the largest on the output and
        // choose per shot (Tuning.highRes): a page filling ~25% of the frame is ~190 dpi at 12 MP, ~380 at 48 MP.
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        let px = { (d: CMVideoDimensions) in Int(d.width) * Int(d.height) }
        if let largest = dims.max(by: { px($0) < px($1) }) { photoOutput.maxPhotoDimensions = largest }
        standardDims = dims.filter { px($0) <= 12_600_000 }.max(by: { px($0) < px($1) })
        photoOutput.maxPhotoQualityPrioritization = .balanced
        if let c = photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        }
    }

    // MARK: state machine (videoQueue)

    private func step(quad: Quad?, sig: [UInt8], now: CFTimeInterval) {
        let motion = lastSig.map { Self.diff(sig, $0) } ?? 99
        let jitter: Double = {
            guard let q = quad, let l = lastQuad else { return 1 }
            return q.maxDelta(l)
        }()
        let usable = quad.map { $0.area >= tuning.minArea } ?? false
        defer { lastQuad = quad; lastSig = sig }

        if paused { return emit(quad, .paused) }

        if manual {
            manual = false
            if case .capturing = phase {} else {
                capture(quad ?? .fullFrame, sig: sig, stableAt: now, now: now)
                return emit(quad, .captured)
            }
        }

        var overlay = OverlayState.searching
        switch phase {
        case .capturing:
            overlay = .captured
        case .waiting:
            absent = usable ? 0 : absent + 1
            let change = waitRef.map { Self.diff(sig, $0) } ?? 99
            let needed = retake ? tuning.maxFrameMotion * 2 : tuning.rearmDiff
            if absent >= tuning.absentFrames || change > needed { phase = .searching }
            overlay = .waiting
        case .searching:
            if usable { phase = .stabilizing(now) }
        case .stabilizing(let since):
            guard usable, let q = quad else { phase = .searching; break }
            // A hand on the page means it's being placed or pulled away — the moment of the bad shots.
            if handPresent || jitter > tuning.maxCornerJitter || motion > tuning.maxFrameMotion {
                phase = .stabilizing(now)
                overlay = .stabilizing(0)
                break
            }
            let progress = (now - since) / tuning.stableSeconds
            overlay = .stabilizing(min(progress, 1))
            if progress >= 1 {
                if isSamePage(q, sig) {
                    phase = .waiting
                    waitRef = sig
                    overlay = .duplicate
                    DispatchQueue.main.async { self.onDuplicate?() }
                } else {
                    capture(q, sig: sig, stableAt: since, now: now)
                    overlay = .captured
                }
            }
        }
        emit(quad, overlay)
    }

    /// Same page as the last capture? Compare the straightened page's ink layout, which is robust to
    /// the page being nudged; fall back to the whole-frame signature when either page is ~blank.
    private func isSamePage(_ q: Quad, _ sig: [UInt8]) -> Bool {
        if let d = dupPage, let p = pageSig(q), d.ink >= PageSig.minInk, p.ink >= PageSig.minInk {
            lastSim = PageSig.similarity(p, d)
            return lastSim >= tuning.dupMatch
        }
        lastSim = -1
        if let d = dupRef { return Self.diff(sig, d) < tuning.dupDiff }
        return false
    }

    /// Straighten the detected page in the current preview frame into a 96x128 ink map.
    private func pageSig(_ q: Quad) -> PageSig? {
        guard let pb = currentPB else { return nil }
        let img = CIImage(cvPixelBuffer: pb).oriented(.right)
        let e = img.extent
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = img
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height) }
        f.topLeft = px(q.tl); f.topRight = px(q.tr); f.bottomLeft = px(q.bl); f.bottomRight = px(q.br)
        guard var out = f.outputImage, out.extent.width > 8, out.extent.height > 8 else { return nil }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        let scale = CGFloat(PageSig.h) / out.extent.height
        let aspect = (CGFloat(PageSig.w) / out.extent.width) / scale
        out = out.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect])
        var g = [UInt8](repeating: 0, count: PageSig.w * PageSig.h)
        ci.render(out, toBitmap: &g, rowBytes: PageSig.w, bounds: CGRect(x: 0, y: 0, width: PageSig.w, height: PageSig.h),
                  format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return PageSig(gray: g)
    }

    private func capture(_ q: Quad, sig: [UInt8], stableAt: CFTimeInterval, now: CFTimeInterval) {
        phase = .capturing
        waitRef = sig
        dupRef = sig
        dupPage = pageSig(q)
        retake = false
        absent = 0
        let settings = AVCapturePhotoSettings()
        if tuning.highRes || standardDims == nil {
            if photoOutput.maxPhotoDimensions.width > 0 { settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions }
        } else if let d = standardDims {
            settings.maxPhotoDimensions = d
        }
        settings.photoQualityPrioritization = .balanced
        settings.flashMode = .off
        let id = String(format: "p%04d-", number) + UUID().uuidString.prefix(6).lowercased()
        var ctx = CaptureContext(id: id, batch: batch, number: number, previewQuad: q, stableAt: stableAt,
                                 requestedAt: now, capturedAt: Date().timeIntervalSince1970)
        ctx.dupSim = lastSim
        number += 1   // optimistic; rewind(to:) undoes it if this page is rejected
        lock.lock(); inflight[settings.uniqueID] = ctx; lock.unlock()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func mirror(_ pb: CVPixelBuffer, now: CFTimeInterval) {
        guard onMirror != nil, !mirrorBusy, now - lastMirror >= 0.1 else { return }
        lastMirror = now; mirrorBusy = true
        let img = CIImage(cvPixelBuffer: pb).oriented(.right)
        let q = mirrorQuad, st = mirrorState
        mirrorQueue.async {
            let s = 720 / img.extent.height
            let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let jpeg = self.mirrorCtx.jpegRepresentation(of: small, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55])
            self.videoQueue.async { self.mirrorBusy = false }
            if let jpeg { self.onMirror?(jpeg, q, st) }
        }
    }

    private func emit(_ quad: Quad?, _ state: OverlayState) {
        mirrorQuad = quad
        switch state {
        case .searching: mirrorState = "searching"
        case .stabilizing(let p): mirrorState = "stabilizing:\(p)"
        case .captured: mirrorState = "captured"
        case .waiting: mirrorState = "waiting"
        case .duplicate: mirrorState = "duplicate"
        case .paused: mirrorState = "paused"
        }
        let size = portrait
        DispatchQueue.main.async { self.onOverlay?(quad, state, size) }
    }

    // MARK: frame signature — 24x32 grayscale, ~4x4 averaged samples per cell

    static func signature(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let raw = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let cols = 32, rows = 24   // buffer is landscape
        var out = [UInt8](repeating: 0, count: cols * rows)
        let stepX = max(1, w / cols / 4), stepY = max(1, h / rows / 4)
        for j in 0..<rows {
            for i in 0..<cols {
                let x0 = i * w / cols, y0 = j * h / rows
                var s = 0
                for dy in 0..<4 {
                    let row = base + min(y0 + dy * stepY, h - 1) * bpr
                    for dx in 0..<4 {
                        let p = row + min(x0 + dx * stepX, w - 1) * 4
                        s += Int(p[0]) + 2 * Int(p[1]) + Int(p[2])
                    }
                }
                out[j * cols + i] = UInt8(s / 64)
            }
        }
        return out
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 99 }
        var s = 0
        for i in 0..<a.count { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        mirror(pb, now: now)
        portrait = CGSize(width: CVPixelBufferGetHeight(pb), height: CVPixelBufferGetWidth(pb))
        // Not scanning: no page detection and no outline, so the preview stays still before Start.
        if paused { lastQuad = nil; return emit(nil, .paused) }
        let sig = Self.signature(pb)
        currentPB = pb
        let req = VNDetectDocumentSegmentationRequest()
        // Only look for hands while deciding whether to fire; that's the only time it matters.
        var requests: [VNRequest] = [req]
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        var checkHands = false
        if tuning.requireNoHand, case .stabilizing = phase { checkHands = true; requests.append(hands) }
        // Sensor buffers are landscape; .right makes Vision work in portrait (UI) coordinates.
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:]).perform(requests)
        handPresent = checkHands && (hands.results ?? []).contains { $0.confidence > 0.3 }
        let obs = req.results?.first
        let quad = obs.flatMap { $0.confidence >= 0.5 ? Quad($0) : nil }
        step(quad: quad, sig: sig, now: now)
        currentPB = nil

        frames += 1
        if now - fpsStart >= 1 { fps = Double(frames) / (now - fpsStart); frames = 0; fpsStart = now }
        if now - lastDebug > 0.2 {
            lastDebug = now
            let phaseName: String
            switch phase {
            case .searching: phaseName = "search"
            case .stabilizing: phaseName = handPresent ? "HAND" : "stable"
            case .capturing: phaseName = "shoot"
            case .waiting: phaseName = retake ? "retake" : "wait"
            }
            let since = waitRef.map { String(format: "%.1f", Self.diff(sig, $0)) } ?? "-"
            let s = String(format: "%2.0ffps %@ conf %.2f area %.2f | Δshot %@ sim %.2f | %ldx%ld",
                           fps, phaseName, obs?.confidence ?? 0, quad?.area ?? 0, since, lastSim,
                           Int(portrait.width), Int(portrait.height))
            DispatchQueue.main.async { self.onDebug?(s) }
        }
    }
}

extension CaptureEngine: AVCapturePhotoCaptureDelegate {
    /// Exposure is finished: the page can move now. This is the "flip" cue.
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        lock.lock(); let ctx = inflight[resolvedSettings.uniqueID]; lock.unlock()
        videoQueue.async { if case .capturing = self.phase { self.phase = .waiting } }
        if let ctx { DispatchQueue.main.async { self.onShutter?(ctx) } }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock(); let ctx = inflight.removeValue(forKey: photo.resolvedSettings.uniqueID); lock.unlock()
        guard var c = ctx, error == nil, let data = photo.fileDataRepresentation() else {
            let msg = error?.localizedDescription ?? "photo had no data"
            DispatchQueue.main.async { self.onError?("Capture failed: \(msg)") }
            return
        }
        c.photoAt = CACurrentMediaTime()
        onPhoto?(data, c)
    }
}

/// Binary ink map of a straightened page at 96x128. Ink = clearly darker than its local neighborhood,
/// which ignores lighting gradients and fold shadows.
struct PageSig {
    static let w = 96, h = 128, minInk = 40
    let bits: [UInt8]
    let ink: Int

    init(gray g: [UInt8]) {
        let w = Self.w, h = Self.h, r = 6
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += Int(g[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var b = [UInt8](repeating: 0, count: w * h)
        var n = 0
        for y in 0..<h {
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1), y0 = max(0, y - r), y1 = min(h, y + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = sum / ((x1 - x0) * (y1 - y0))
                if Int(g[y * w + x]) < mean - 10 { b[y * w + x] = 1; n += 1 }
            }
        }
        bits = b
        ink = n
    }

    /// Share of each page's ink that has ink within 1px on the other page (the smaller of the two).
    static func similarity(_ a: PageSig, _ b: PageSig) -> Double {
        func covered(_ x: PageSig, by y: PageSig) -> Double {
            var hit = 0
            for j in 0..<h {
                for i in 0..<w where x.bits[j * w + i] == 1 {
                    var found = false
                    for dj in -1...1 where !found {
                        let jj = j + dj
                        if jj < 0 || jj >= h { continue }
                        for di in -1...1 {
                            let ii = i + di
                            if ii >= 0 && ii < w && y.bits[jj * w + ii] == 1 { found = true; break }
                        }
                    }
                    if found { hit += 1 }
                }
            }
            return Double(hit) / Double(max(1, x.ink))
        }
        return min(covered(a, by: b), covered(b, by: a))
    }
}
