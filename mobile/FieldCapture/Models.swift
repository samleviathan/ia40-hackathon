import CoreGraphics
import Foundation
import UIKit
import Vision

/// Page corners in Vision's normalized space (0...1, origin bottom-left) of the portrait image.
struct Quad: Codable, Equatable {
    var tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint

    init(_ o: VNRectangleObservation) {
        tl = o.topLeft; tr = o.topRight; br = o.bottomRight; bl = o.bottomLeft
    }

    init(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }

    static let fullFrame = Quad(tl: CGPoint(x: 0, y: 1), tr: CGPoint(x: 1, y: 1), br: CGPoint(x: 1, y: 0), bl: CGPoint(x: 0, y: 0))

    var points: [CGPoint] { [tl, tr, br, bl] }

    var area: Double {
        let p = points
        var s = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    func maxDelta(_ o: Quad) -> Double {
        zip(points, o.points).map { Double(hypot($0.x - $1.x, $0.y - $1.y)) }.max() ?? 1
    }

    func touchesEdge(_ margin: Double) -> Bool {
        points.contains { Double($0.x) < margin || Double($0.x) > 1 - margin || Double($0.y) < margin || Double($0.y) > 1 - margin }
    }
}

/// Capture thresholds, tuned against real paper and lighting.
struct Tuning: Codable, Equatable {
    var stableSeconds = 0.25      // corners must hold still this long before auto-capture
    var maxCornerJitter = 0.03    // normalized corner movement allowed between frames while "stable"
    var maxFrameMotion = 4.0      // mean abs change of the 24x32 frame signature allowed while "stable"
    var rearmDiff = 18.0          // after a capture, this much scene change re-arms the shutter
    var dupDiff = 3.0             // a stable scene closer than this to the last capture is "same page"
    var absentFrames = 10         // page gone for this many frames also re-arms
    var dupMatch = 0.95           // on-phone ink match proved unable to separate duplicates (dups 0.48, distinct 0.39–0.57); effectively off — the laptop dedupes
    var requireNoHand = true      // never fire while a hand is in frame
    var regionSharpMin = 60.0     // weakest text region below this = retake (applies when ≥4 text regions)
    var highRes = true            // 48 MP stills (~380 dpi at typical framing) instead of 12 MP
    var minArea = 0.08            // page must cover this share of the frame
    var sharpMin = 105.0          // top-2000 edge strength below this = blurry (blurry ≤93, sharp ≥120)
    var glareMax = 0.01           // share of near-saturated page pixels (≥ max(paper+35, 245)) = glare
    var edgeMargin = 0.006        // corners closer than this to the frame edge = cut off
    var phoneOCR = false          // OCR normally runs on the laptop; on-phone OCR is optional
    var micThresholdDB = -30.0    // level that opens an audio clip

    static func load() -> Tuning {
        guard let d = UserDefaults.standard.data(forKey: "tuning.v7"),
              let t = try? JSONDecoder().decode(Tuning.self, from: d) else { return Tuning() }
        return t
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "tuning.v7")
    }
}

struct CaptureContext {
    let id: String
    let batch: String
    let number: Int
    let previewQuad: Quad
    let stableAt: CFTimeInterval       // CACurrentMediaTime when stability started
    let requestedAt: CFTimeInterval    // shutter fired
    let capturedAt: TimeInterval       // wall clock, for laptop-side latency
    var dupSim: Double = -1            // ink-overlap score vs. the previous capture (-1 = not computed)
    var photoAt: CFTimeInterval = 0    // photo data ready
}

enum PageStatus: String, Codable { case processing, accepted, rejected }

struct PageRecord: Identifiable {
    let id: String
    let number: Int
    var status: PageStatus = .processing
    var reasons: [String] = []
    var thumb: UIImage?
    var imageSent = false
    var ocrDone = false
    var ocrSent = false
}

enum OverlayState { case searching, stabilizing(Double), captured, waiting, duplicate, paused }
