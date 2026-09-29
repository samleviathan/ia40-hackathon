import AVFoundation
import SwiftUI
import UIKit

@main
struct FieldCaptureApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            CameraView(engine: model.engine)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.manualCapture() }

            if let f = model.flash {
                f.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            }

            // Minimal scanning UI: page count (top-left), Next/Rescan cue (top-right), Start/Stop (bottom-right).
            // Everything else stays off-screen so attention stays on keeping the page in frame.
            // Long-press the page count for settings.
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(model.accepted)")
                            .font(.system(size: 72, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        if model.offline {
                            Text("laptop offline").font(.caption.weight(.semibold)).foregroundStyle(.red)
                        }
                    }
                    .onLongPressGesture { showSettings = true }
                    Spacer()
                    if model.running, let cue = model.cue {
                        Text(cue == .rescan ? "Rescan" : "Next")
                            .font(.title.weight(.bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(cue == .rescan ? Color.red : Color.green, in: Capsule())
                            .id(model.cueTick)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        model.running ? model.stopSession() : model.startSession()
                    } label: {
                        Text(model.running ? "Stop" : "Start")
                            .font(.title2.weight(.bold))
                            .frame(width: 130, height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.running ? .red : .green)
                }
            }
            .padding()
            .foregroundStyle(.white)
            .animation(.spring(duration: 0.25), value: model.cueTick)
        }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .onAppear { model.start() }
    }
}

struct PageThumb: View {
    let page: PageRecord

    var color: Color {
        switch page.status {
        case .processing: return .gray
        case .accepted: return page.reasons.contains("blank") ? .orange : .green
        case .rejected: return .red
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                if let t = page.thumb {
                    Image(uiImage: t).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 54, height: 70)
            .background(.black.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 3))
            HStack(spacing: 3) {
                Text("\(page.number)").font(.caption2.weight(.bold)).monospacedDigit()
                Circle().fill(page.imageSent ? Color.blue : Color.gray.opacity(0.5)).frame(width: 6, height: 6)
                Circle().fill(page.ocrSent ? Color.purple : (page.ocrDone ? Color.yellow : Color.gray.opacity(0.5)))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var host = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Laptop") {
                    Text(model.receiver).font(.caption)
                    TextField("blank = auto-discover, or 192.168.1.20:8765", text: $host)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Apply") { model.setHost(host) }
                }
                Section("Auto-shutter") {
                    slider("Stable for (s)", $model.tuning.stableSeconds, 0.1...1.0, "%.2f")
                    slider("Corner jitter max", $model.tuning.maxCornerJitter, 0.002...0.04, "%.3f")
                    slider("Frame motion max", $model.tuning.maxFrameMotion, 0.5...10, "%.1f")
                    slider("Re-arm change", $model.tuning.rearmDiff, 4...40, "%.1f")
                    slider("Same-page below", $model.tuning.dupDiff, 0...10, "%.1f")
                    slider("Same-page ink match ≥", $model.tuning.dupMatch, 0.2...0.95, "%.2f")
                    slider("Min page area", $model.tuning.minArea, 0.05...0.6, "%.2f")
                    Toggle("Wait until no hand is in frame", isOn: $model.tuning.requireNoHand)
                }
                Section("Quality gate") {
                    slider("Sharpness min", $model.tuning.sharpMin, 0...150, "%.0f")
                    slider("Weakest region min", $model.tuning.regionSharpMin, 0...200, "%.0f")
                    slider("Glare max", $model.tuning.glareMax, 0...0.05, "%.3f")
                    slider("Edge margin", $model.tuning.edgeMargin, 0...0.03, "%.3f")
                }
                Section("Audio + processing") {
                    slider("Mic speech gate (dBFS)", $model.tuning.micThresholdDB, -70 ... -10, "%.0f")
                    Toggle("OCR on phone (normally on laptop)", isOn: $model.tuning.phoneOCR)
                    Toggle("48 MP capture (higher dpi)", isOn: $model.tuning.highRes)
                }
                Section {
                    Toggle("Show debug line", isOn: $model.showDebug)
                    Button("Reset tuning to defaults", role: .destructive) { model.tuning = Tuning() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { host = model.manualHost }
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ fmt: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(label); Spacer(); Text(String(format: fmt, v.wrappedValue)).monospacedDigit() }
            Slider(value: v, in: r)
        }
    }
}

// MARK: camera preview + page outline

struct CameraView: UIViewRepresentable {
    let engine: CaptureEngine

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = engine.session
        v.previewLayer.videoGravity = .resizeAspectFill
        engine.onOverlay = { [weak v] quad, state, size in v?.show(quad, state, size) }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.lineWidth = 5
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = bounds
    }

    func show(_ q: Quad?, _ state: OverlayState, _ size: CGSize) {
        if let c = previewLayer.connection, c.videoRotationAngle != 90, c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let q, size.width > 0, size.height > 0 else { shape.path = nil; return }

        // Map Vision's normalized portrait coordinates through the aspect-fill preview.
        let s = max(bounds.width / size.width, bounds.height / size.height)
        let dw = size.width * s, dh = size.height * s
        let ox = (bounds.width - dw) / 2, oy = (bounds.height - dh) / 2
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * dw, y: oy + (1 - p.y) * dh) }
        let path = UIBezierPath()
        path.move(to: m(q.tl)); path.addLine(to: m(q.tr)); path.addLine(to: m(q.br)); path.addLine(to: m(q.bl))
        path.close()
        shape.path = path.cgPath

        let stroke: UIColor, fill: UIColor
        switch state {
        case .searching: stroke = .systemYellow; fill = .clear
        case .stabilizing(let p): stroke = .systemYellow; fill = UIColor.systemYellow.withAlphaComponent(0.35 * p)
        case .captured: stroke = .systemGreen; fill = UIColor.systemGreen.withAlphaComponent(0.35)
        case .waiting: stroke = UIColor.white.withAlphaComponent(0.5); fill = .clear
        case .duplicate: stroke = .systemOrange; fill = UIColor.systemOrange.withAlphaComponent(0.25)
        case .paused: stroke = .gray; fill = .clear
        }
        shape.strokeColor = stroke.cgColor
        shape.fillColor = fill.cgColor
    }
}

struct MicMeter: View {
    let db: Float
    let open: Bool
    let running: Bool
    let clips: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: running ? (open ? "waveform.circle.fill" : "mic.fill") : "mic.slash")
                .font(.title2)
                .foregroundStyle(open ? .red : .white)
            VStack(alignment: .leading, spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(open ? Color.red : Color.green)
                            .frame(width: g.size.width * CGFloat(max(0, min(1, (db + 70) / 60))))
                    }
                }
                .frame(width: 80, height: 6)
                Text("\(clips) voice clips").font(.caption2).monospacedDigit()
            }
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
