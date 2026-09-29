import AVFoundation
import CoreImage
import CoreMediaIO
import Network

// Mirrors the USB iPhone's screen (the same source QuickTime's "New Movie Recording" uses) as an
// MJPEG stream at http://<mac>:8766/stream, so the live board can show the phone next to the board.
// Build: swiftc -O tools/phonescreen.swift -o tools/phonescreen

let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["PHONESCREEN_PORT"] ?? "8766") ?? 8766
let maxHeight: CGFloat = 900
let minInterval = 1.0 / 15

// iOS screens only appear as capture devices after this opt-in.
var prop = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
var allow: UInt32 = 1
CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)

final class Hub {
    private let q = DispatchQueue(label: "hub")
    private var clients: [NWConnection] = []
    private var latest: Data?
    func add(_ c: NWConnection) {
        q.async {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            c.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
            self.clients.append(c)
            if let f = self.latest { self.send(f, to: c) }
        }
    }
    func publish(_ jpeg: Data) {
        q.async {
            self.latest = jpeg
            self.clients.forEach { self.send(jpeg, to: $0) }
        }
    }
    private func send(_ jpeg: Data, to c: NWConnection) {
        var part = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!
        part.append(jpeg); part.append("\r\n".data(using: .utf8)!)
        c.send(content: part, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.q.async { self?.clients.removeAll { $0 === c }; c.cancel() } }
        })
    }
}

final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let hub: Hub
    let ctx = CIContext()
    var last = 0.0
    init(hub: Hub) { self.hub = hub }
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - last >= minInterval, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        last = now
        var img = CIImage(cvPixelBuffer: pb)
        let s = min(1, maxHeight / img.extent.height)
        img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let jpeg = ctx.jpegRepresentation(of: img, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]) {
            hub.publish(jpeg)
        }
    }
}

let hub = Hub()
let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { c in
    c.start(queue: .global())
    // Any request gets the stream; read and discard the request line and headers.
    c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in hub.add(c) }
}
listener.start(queue: .global())

let grabber = Grabber(hub: hub)
let session = AVCaptureSession()
let out = AVCaptureVideoDataOutput()
out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
out.alwaysDiscardsLateVideoFrames = true
out.setSampleBufferDelegate(grabber, queue: DispatchQueue(label: "frames"))

func findScreen() -> AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
        .devices.first { $0.modelID == "iOS Device" }
}

AVCaptureDevice.requestAccess(for: .video) { ok in if !ok { print("camera access denied"); exit(1) } }
var device: AVCaptureDevice?
for _ in 0..<20 where device == nil {
    device = findScreen()
    if device == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
}
guard let dev = device, let input = try? AVCaptureDeviceInput(device: dev) else {
    print("no iPhone screen found: plug in, unlock, and trust this Mac"); exit(1)
}
session.addInput(input)
session.addOutput(out)
session.startRunning()
print("mirroring \(dev.localizedName) on http://localhost:\(port)/stream", terminator: "\n")
fflush(stdout)
NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: dev, queue: nil) { _ in
    print("iPhone disconnected"); exit(2)
}
RunLoop.main.run()
