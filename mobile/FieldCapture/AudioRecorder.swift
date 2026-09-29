import AVFoundation

/// Always-on microphone for a capture session. A simple level gate cuts speech into clips
/// (open when the level rises, close after `silenceToClose` of quiet, keep a short pre-roll so
/// the first syllable isn't lost). Each clip is an .m4a stamped with the phone's wall clock;
/// transcription happens on the laptop.
final class AudioRecorder {
    struct Clip { let url: URL; let tStart: TimeInterval; let tEnd: TimeInterval; let peakDB: Float }

    var thresholdDB: Float = -40
    var silenceToClose = 1.0
    var preRoll = 0.35
    var maxClip = 30.0
    var minSpeech = 0.35
    var minPeakDB: Float = -22   // measured: every real utterance peaked ≥ -19.7 dB; noise clips ≤ -20.7 dB

    var onClip: ((Clip) -> Void)?              // any thread
    var onLevel: ((Float, Bool) -> Void)?      // main: dBFS, clip open

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "audio.gate")
    private let dir = FileManager.default.temporaryDirectory
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var clipStart: TimeInterval = 0
    private var lastLoud: TimeInterval = 0
    private var firstLoud: TimeInterval = 0
    private var peak: Float = -160
    private var pre: [(AVAudioPCMBuffer, TimeInterval)] = []
    private var lastEmit: TimeInterval = 0
    private(set) var running = false

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        // Without this, iOS silences haptics while the mic records — and haptics are the "flip" cue.
        try s.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try s.setActive(true)
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            let t = Date().timeIntervalSince1970
            guard let self, let copy = Self.copy(buf) else { return }
            self.queue.async { self.handle(copy, end: t) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { self.close(); self.pre = [] }
    }

    // MARK: queue-confined

    private func handle(_ buf: AVAudioPCMBuffer, end t: TimeInterval) {
        let dur = Double(buf.frameLength) / buf.format.sampleRate
        let start = t - dur
        let db = Self.level(buf)
        let loud = db > thresholdDB
        if loud { lastLoud = t; peak = max(peak, db) }

        if file == nil {
            pre.append((buf, start))
            while let f = pre.first, start - f.1 > preRoll { pre.removeFirst() }
            if loud {
                firstLoud = start
                open(format: buf.format, start: pre.first?.1 ?? start)
                for (b, _) in pre { try? file?.write(from: b) }
                pre = []
            }
        } else {
            try? file?.write(from: buf)
            if t - lastLoud > silenceToClose || t - clipStart > maxClip { close() }
        }

        if t - lastEmit > 0.08 {
            lastEmit = t
            let open = file != nil
            DispatchQueue.main.async { self.onLevel?(db, open) }
        }
    }

    private func open(format: AVAudioFormat, start: TimeInterval) {
        let url = dir.appendingPathComponent("clip-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount,
                                       AVEncoderBitRateKey: 64000]
        file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                interleaved: format.isInterleaved)
        fileURL = url
        clipStart = start
        peak = -160
    }

    private func close() {
        guard file != nil, let url = fileURL else { return }
        file = nil   // releasing the AVAudioFile finalizes the .m4a
        fileURL = nil
        let speech = lastLoud - firstLoud
        if speech < minSpeech || peak < minPeakDB {
            try? FileManager.default.removeItem(at: url)   // a click or a cough
            return
        }
        onClip?(Clip(url: url, tStart: clipStart, tEnd: lastLoud, peakDB: peak))
    }

    static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData, b.frameLength > 0 else { return -160 }
        let n = Int(b.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = ch[0][i]; sum += v * v }
        let rms = (sum / Float(n)).squareRoot()
        return 20 * log10(max(rms, 1e-8))
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength),
              let src = b.floatChannelData, let dst = c.floatChannelData else { return nil }
        c.frameLength = b.frameLength
        let frames = Int(b.frameLength) * (b.format.isInterleaved ? Int(b.format.channelCount) : 1)
        let channels = b.format.isInterleaved ? 1 : Int(b.format.channelCount)
        for i in 0..<channels { memcpy(dst[i], src[i], frames * MemoryLayout<Float>.size) }
        return c
    }
}
