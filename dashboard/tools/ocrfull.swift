import AppKit
import Foundation
import Vision

// Full OCR for the pipeline page: tries upright and upside-down, keeps the orientation that reads
// better, and emits lines + word boxes (normalized, top-left origin, in the upright image).
let dict = Set((try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8))?.lowercased().split(separator: "\n").map(String.init) ?? [])

func tl(_ r: CGRect) -> [Double] { [r.minX, 1 - r.maxY, r.width, r.height].map { (Double($0) * 10000).rounded() / 10000 } }

func run(_ cg: CGImage, _ o: CGImagePropertyOrientation) -> ([[String: Any]], Double, Int) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: cg, orientation: o).perform([req])
    var lines: [[String: Any]] = []
    var toks = 0, real = 0
    for obs in req.results ?? [] {
        guard let top = obs.topCandidates(1).first else { continue }
        var words: [[String: Any]] = []
        top.string.enumerateSubstrings(in: top.string.startIndex..., options: .byWords) { w, r, _, _ in
            guard let w else { return }
            if w.count >= 3 { toks += 1; if dict.contains(w.lowercased()) { real += 1 } }
            if let b = (try? top.boundingBox(for: r))?.boundingBox { words.append(["t": w, "b": tl(b)]) }
        }
        lines.append(["text": top.string, "conf": Double(top.confidence), "b": tl(obs.boundingBox), "words": words])
    }
    return (lines, toks == 0 ? 0 : Double(real) / Double(toks), toks)
}

for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), var rect = Optional(CGRect(origin: .zero, size: img.size)),
          let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
    let t0 = Date()
    let up = run(cg, .up)
    var best = up, orient = "up"
    if up.1 < 0.6 || up.2 < 30 {
        let down = run(cg, .down)
        if down.2 > up.2 && down.1 > up.1 { best = down; orient = "down" }
    }
    let out: [String: Any] = ["path": path, "orientation": orient, "real_word_rate": best.1, "words": best.2,
                              "ms": Int(Date().timeIntervalSince(t0) * 1000), "lines": best.0]
    if let d = try? JSONSerialization.data(withJSONObject: out) { print(String(data: d, encoding: .utf8)!) }
}
