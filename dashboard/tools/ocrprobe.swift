import Foundation
import Vision
import AppKit

// For each image: fast + accurate OCR, language correction OFF. Output JSON per line.
let words = Set((try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8))?.lowercased().split(separator: "\n").map(String.init) ?? [])
for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), var rect = Optional(CGRect(origin: .zero, size: img.size)),
          let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
    var out: [String: Any] = ["path": path]
    for (name, level) in [("fast", VNRequestTextRecognitionLevel.fast), ("accurate", .accurate)] {
        let t0 = Date()
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let obs = req.results ?? []
        var toks = 0, dict = 0, confSum = 0.0, chars = 0
        var regions = [[Int]](repeating: [0, 0], count: 9)   // [tokens, dictionary words] per 3x3 cell
        for o in obs {
            guard let c = o.topCandidates(1).first else { continue }
            confSum += Double(c.confidence); chars += c.string.count
            let cell = min(2, Int((1 - o.boundingBox.midY) * 3)) * 3 + min(2, Int(o.boundingBox.midX * 3))
            for w in c.string.lowercased().split(whereSeparator: { !$0.isLetter }) where w.count >= 3 {
                toks += 1; regions[cell][0] += 1
                if words.contains(String(w)) { dict += 1; regions[cell][1] += 1 }
            }
        }
        out[name] = ["ms": Int(Date().timeIntervalSince(t0) * 1000), "lines": obs.count, "chars": chars,
                     "meanConf": obs.isEmpty ? 0 : confSum / Double(obs.count),
                     "tokens": toks, "dictRate": toks == 0 ? 0 : Double(dict) / Double(toks), "regions": regions]
    }
    if let d = try? JSONSerialization.data(withJSONObject: out), let s = String(data: d, encoding: .utf8) { print(s) }
}
