import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import ImageIO
import UIKit
import Vision

struct Metrics {
    var sharpness: Double   // mean |Laplacian| of the 2000 strongest edge pixels — fixed count, so a mostly blank page isn't scored as blurry
    var glare: Double       // share of near-saturated pixels well above the paper
    var paper: Int          // median gray level (≈ paper white)
    var contrast: Double    // gray std dev
    var ink: Double         // share of pixels clearly darker than paper (≈0 means blank)
    var regionMin: Double = -1   // weakest 3x3 text region (mean of its 200 strongest edges); -1 = too few text regions
    var textRegions = 0

    /// Handheld tilt leaves one corner soft while the page overall scores sharp. Score each 3x3 region
    /// that has real text. Calibrated on 50 pages: bad crops 6–53, good ≥92.
    static func regions(_ p: [UInt8], _ w: Int, _ h: Int) -> (Double, Int) {
        var vals: [Double] = []
        p.withUnsafeBufferPointer { b in
            for r in 0..<3 {
                for c in 0..<3 {
                    let x0 = max(1, c * w / 3), x1 = min(w - 1, (c + 1) * w / 3)
                    let y0 = max(1, r * h / 3), y1 = min(h - 1, (r + 1) * h / 3)
                    guard x1 > x0 + 4, y1 > y0 + 4 else { continue }
                    var gh = [Int](repeating: 0, count: 256), lh = [Int](repeating: 0, count: 1021)
                    for y in y0..<y1 {
                        let row = y * w
                        for x in x0..<x1 {
                            let v = Int(b[row + x])
                            gh[v] += 1
                            let l = 4 * v - Int(b[row + x - 1]) - Int(b[row + x + 1]) - Int(b[row + x - w]) - Int(b[row + x + w])
                            lh[min(abs(l), 1020)] += 1
                        }
                    }
                    let n = (x1 - x0) * (y1 - y0)
                    var acc = 0, med = 0
                    for (i, k) in gh.enumerated() { acc += k; if acc * 2 >= n { med = i; break } }
                    let dark = gh[0..<max(0, med - 50)].reduce(0, +)
                    guard Double(dark) / Double(n) > 0.015, dark > 1500 else { continue }
                    var need = 200, sum = 0.0
                    for v in stride(from: 1020, through: 0, by: -1) where need > 0 {
                        let t = min(need, lh[v]); sum += Double(t * v); need -= t
                    }
                    vals.append(sum / Double(max(1, 200 - need)))
                }
            }
        }
        return (vals.count >= 4 ? (vals.min() ?? -1) : -1, vals.count)
    }

    /// `p` is an 8-bit grayscale image, w×h.
    static func compute(_ p: [UInt8], _ w: Int, _ h: Int) -> Metrics {
        guard w > 20, h > 20 else { return Metrics(sharpness: 0, glare: 0, paper: 0, contrast: 0, ink: 0) }
        var hist = [Int](repeating: 0, count: 256)
        var lap = [Int](repeating: 0, count: 1021)
        let bx = max(1, w / 40), by = max(1, h / 40)   // skip a thin border: correction edges aren't content
        p.withUnsafeBufferPointer { b in
            for y in by..<(h - by) {
                let r = y * w
                for x in bx..<(w - bx) {
                    let v = Int(b[r + x])
                    hist[v] += 1
                    let l = 4 * v - Int(b[r + x - 1]) - Int(b[r + x + 1]) - Int(b[r + x - w]) - Int(b[r + x + w])
                    lap[min(abs(l), 1020)] += 1
                }
            }
        }
        let n = max(1, hist.reduce(0, +))
        func pct(_ h: [Int], _ q: Double) -> Int {
            let target = Int(Double(n) * q)
            var acc = 0
            for (i, c) in h.enumerated() { acc += c; if acc >= target { return i } }
            return h.count - 1
        }
        let paper = pct(hist, 0.5)
        var mean = 0.0, sq = 0.0
        for (i, c) in hist.enumerated() { mean += Double(i * c); sq += Double(i * i * c) }
        mean /= Double(n)
        let std = (sq / Double(n) - mean * mean).squareRoot()
        // Glare = near-blown-out pixels well above the paper. Uneven light and cream paper don't
        // reach this; a specular hotspot saturates (measured on real pages: clean ≤0.11%).
        let glareLevel = min(255, max(paper + 35, 245))
        let glare = Double(hist[glareLevel...].reduce(0, +)) / Double(n)
        let inkLevel = max(0, paper - 60)
        let ink = Double(hist[...inkLevel].reduce(0, +)) / Double(n)
        // Mean of the strongest 2000 edge responses. Measured on real captures: motion-blurred 20–93,
        // sharp 120–358 (sparse "signature only" pages included), vs. the old percentile which put
        // sharp sparse pages (107) next to blurry ones (77).
        var need = 2000, acc = 0.0
        for v in stride(from: lap.count - 1, through: 0, by: -1) where need > 0 {
            let take = min(need, lap[v])
            acc += Double(take * v); need -= take
        }
        let sharp = acc / Double(max(1, 2000 - need))
        return Metrics(sharpness: sharp, glare: glare, paper: paper, contrast: std, ink: ink)
    }
}

/// Per-page work after the shutter: find + straighten the page, check quality, encode,
/// queue for upload, then run full OCR on a separate queue so the next page never waits on it.
final class PageProcessor {
    private let queue = DispatchQueue(label: "page.process", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "page.ocr", qos: .utility)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let uploader: Uploader
    private let device: String
    private var tuning = Tuning.load()

    var onResult: ((String, PageStatus, [String], UIImage?) -> Void)?   // main
    var onOCR: ((String, Int) -> Void)?                                // main: id, line count

    init(uploader: Uploader) {
        self.uploader = uploader
        device = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
    }

    func setTuning(_ t: Tuning) { queue.async { self.tuning = t } }
    func process(_ data: Data, _ c: CaptureContext) { queue.async { self.run(data, c) } }

    private func run(_ data: Data, _ c: CaptureContext) {
        let t0 = CACurrentMediaTime()
        guard var img = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let W = img.extent.width, H = img.extent.height

        // Re-detect on a 1024px copy of the real photo; fall back to the live-preview corners.
        let s = 1024 / max(W, H)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let req = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(ciImage: small, options: [:]).perform([req])
        let quad = req.results?.first.flatMap { $0.confidence >= 0.5 ? Quad($0) : nil } ?? c.previewQuad

        let f = CIFilter.perspectiveCorrection()
        f.inputImage = img
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
        f.topLeft = px(quad.tl); f.topRight = px(quad.tr); f.bottomLeft = px(quad.bl); f.bottomRight = px(quad.br)
        guard var page = f.outputImage else { return }
        page = page.transformed(by: CGAffineTransform(translationX: -page.extent.minX, y: -page.extent.minY))
        page = page.cropped(to: CGRect(x: 0, y: 0, width: floor(page.extent.width), height: floor(page.extent.height)))

        // Quality metrics on a ≤1200px grayscale copy.
        let ms = min(1, 1200 / max(page.extent.width, page.extent.height))
        let g = page.transformed(by: CGAffineTransform(scaleX: ms, y: ms))
        let gw = Int(g.extent.width), gh = Int(g.extent.height)
        var gray = [UInt8](repeating: 0, count: gw * gh)
        ci.render(g, toBitmap: &gray, rowBytes: gw, bounds: CGRect(x: 0, y: 0, width: gw, height: gh),
                  format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        var m = Metrics.compute(gray, gw, gh)
        (m.regionMin, m.textRegions) = Metrics.regions(gray, gw, gh)

        var reasons: [String] = []
        let blank = m.ink < 0.002
        if quad.touchesEdge(tuning.edgeMargin) { reasons.append("cut off") }
        if !blank && m.sharpness < tuning.sharpMin { reasons.append("blurry") }
        else if m.regionMin >= 0 && m.regionMin < tuning.regionSharpMin { reasons.append("blurry region") }
        if m.glare > tuning.glareMax { reasons.append("glare") }
        let status: PageStatus = reasons.isEmpty ? .accepted : .rejected
        if blank { reasons.append("blank") }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85]
        guard let jpeg = ci.jpegRepresentation(of: page, colorSpace: sRGB, options: opts) else { return }
        let sha = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()

        let ts = 180 / max(page.extent.width, page.extent.height)
        let thumb = ci.createCGImage(page.transformed(by: CGAffineTransform(scaleX: ts, y: ts)),
                                     from: CGRect(x: 0, y: 0, width: floor(page.extent.width * ts), height: floor(page.extent.height * ts)))
            .map { UIImage(cgImage: $0) }

        let now = CACurrentMediaTime()
        let meta: [String: Any] = [
            "type": "page", "id": c.id, "batch": c.batch, "number": c.number, "status": status.rawValue, "reasons": reasons,
            "metrics": ["sharpness": m.sharpness, "region_min": m.regionMin, "text_regions": m.textRegions,
                        "glare": m.glare, "paper": m.paper, "contrast": m.contrast,
                        "ink": m.ink, "quad_area": quad.area],
            "quad": quad.points.map { [Double($0.x), Double(1 - $0.y)] },
            "image": ["width": Int(page.extent.width), "height": Int(page.extent.height), "bytes": jpeg.count,
                      "sha256": sha, "photo_width": Int(W), "photo_height": Int(H)],
            "timing": ["captured_at": c.capturedAt,
                       "stable_ms": Int((c.requestedAt - c.stableAt) * 1000),
                       "shutter_to_photo_ms": Int((c.photoAt - c.requestedAt) * 1000),
                       "process_ms": Int((now - t0) * 1000),
                       "shutter_to_queued_ms": Int((now - c.requestedAt) * 1000)],
            "dup_sim": c.dupSim,
            "device": device,
            "tuning": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tuning))) ?? [:],
        ]
        if let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            uploader.add(batch: c.batch, page: c.id, kind: "meta", data: metaData)
        }
        uploader.add(batch: c.batch, page: c.id, kind: "image", data: jpeg)
        DispatchQueue.main.async { self.onResult?(c.id, status, reasons, thumb) }

        if status == .accepted && !blank && tuning.phoneOCR {
            ocrQueue.async { self.ocr(page, c) }
        }
    }

    private func ocr(_ page: CIImage, _ c: CaptureContext) {
        let t0 = CACurrentMediaTime()
        guard let cg = ci.createCGImage(page, from: page.extent) else { return }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])

        var lines: [[String: Any]] = []
        for o in req.results ?? [] {
            guard let top = o.topCandidates(1).first else { continue }
            let text = top.string
            var words: [[String: Any]] = []
            text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { w, r, _, _ in
                guard let w, let box = (try? top.boundingBox(for: r))?.boundingBox else { return }
                words.append(["text": w, "box": Self.topLeft(box)])
            }
            lines.append(["text": text, "confidence": top.confidence, "box": Self.topLeft(o.boundingBox), "words": words])
        }
        let doc: [String: Any] = ["id": c.id, "batch": c.batch, "engine": "apple-vision-accurate",
                                  "ocr_ms": Int((CACurrentMediaTime() - t0) * 1000),
                                  "width": cg.width, "height": cg.height, "lines": lines]
        if let d = try? JSONSerialization.data(withJSONObject: doc) {
            uploader.add(batch: c.batch, page: c.id, kind: "ocr", data: d)
        }
        let n = lines.count
        DispatchQueue.main.async { self.onOCR?(c.id, n) }
    }

    /// Vision rect (normalized, origin bottom-left) → [x, y, w, h] normalized, origin top-left.
    static func topLeft(_ r: CGRect) -> [Double] {
        [r.minX, 1 - r.maxY, r.width, r.height].map { (Double($0) * 10000).rounded() / 10000 }
    }
}
