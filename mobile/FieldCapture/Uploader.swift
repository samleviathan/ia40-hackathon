import Foundation
import Network

/// Disk-backed FIFO outbox. Every payload is written to Documents/outbox before sending, so a
/// Wi-Fi drop or app restart loses nothing; one serial sender drains it and retries forever.
/// The laptop is found over Bonjour (_fieldscan._tcp, TXT ip/port) unless a host is typed in.
final class Uploader {
    private struct Item { let batch: String, page: String, kind: String, file: URL }

    private let dir: URL
    private let queue = DispatchQueue(label: "upload")
    private var items: [Item] = []
    private var sending = false
    private var base: URL?
    private var hostLabel = "Looking for laptop…"
    private var failures = 0
    private var browser: NWBrowser?
    private var manual = ""
    private var mirrorBusy = false

    var onSent: ((String, String) -> Void)?   // main: page id, kind
    var onState: ((String, Int) -> Void)?     // main: receiver label, queued count

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in leftovers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let p = f.lastPathComponent.components(separatedBy: "__")
            if p.count == 4 { items.append(Item(batch: p[1], page: p[2], kind: p[3], file: f)) }
        }
    }

    func start(manualHost: String) {
        queue.async { [self] in
            browser?.cancel(); browser = nil
            let host = manualHost.trimmingCharacters(in: .whitespaces)
            manual = host
            if !host.isEmpty {
                use(host: host, label: "\(host) (manual)")
                return
            }
            base = nil
            hostLabel = "Looking for laptop…"
            report()
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_fieldscan._tcp", domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                for r in results {
                    if case let .bonjour(txt) = r.metadata, let ip = txt["ip"], let port = txt["port"] {
                        self?.use(host: "\(ip):\(port)", label: "\(ip)")
                        return
                    }
                }
            }
            b.stateUpdateHandler = { [weak self] st in
                if case let .failed(e) = st { self?.hostLabel = "Bonjour failed: \(e)"; self?.report() }
            }
            b.start(queue: queue)
            browser = b
        }
    }

    func add(batch: String, page: String, kind: String, data: Data) {
        queue.async { [self] in
            let name = String(format: "%015.0f", Date().timeIntervalSince1970 * 1000) + "__\(batch)__\(page)__\(kind)"
            let url = dir.appendingPathComponent(name)
            do { try data.write(to: url) } catch { hostLabel = "Disk write failed"; report(); return }
            items.append(Item(batch: batch, page: page, kind: kind, file: url))
            report()
            kick()
        }
    }

    /// Latest preview frame for the laptop's phone mirror. Best effort: dropped while one is in flight.
    func mirror(_ jpeg: Data, meta: String) {
        queue.async { [self] in
            guard let base, !mirrorBusy else { return }
            mirrorBusy = true
            var req = URLRequest(url: base.appendingPathComponent("api/mirror"))
            req.httpMethod = "POST"
            req.timeoutInterval = 3
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            req.setValue(meta, forHTTPHeaderField: "X-Mirror")
            URLSession.shared.uploadTask(with: req, from: jpeg) { [weak self] _, _, _ in
                self?.queue.async { self?.mirrorBusy = false }
            }.resume()
        }
    }

    // MARK: queue-confined

    private func use(host: String, label: String) {
        base = URL(string: "http://\(host)")
        hostLabel = label
        failures = 0
        report()
        kick()
    }

    private func kick() {
        guard !sending, base != nil, !items.isEmpty else { return }
        sending = true
        sendNext()
    }

    private func sendNext() {
        guard let base, let item = items.first else { sending = false; report(); return }
        var req = URLRequest(url: base.appendingPathComponent("upload/\(item.batch)/\(item.page)/\(item.kind)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue(item.kind == "image" ? "image/jpeg" : "application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: req, fromFile: item.file) { [weak self] _, resp, err in
            guard let self else { return }
            self.queue.async {
                if err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 {
                    try? FileManager.default.removeItem(at: item.file)
                    self.items.removeFirst()
                    self.failures = 0
                    DispatchQueue.main.async { self.onSent?(item.page, item.kind) }
                    self.report()
                    self.sendNext()
                } else {
                    self.failures += 1
                    let why = err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                    if self.failures >= 2 { self.hostLabel = "Offline: \(why)" }
                    self.report()
                    // The USB link's address changes when the cable reconnects: look the laptop up again.
                    if self.manual.isEmpty, self.failures % 4 == 0 { self.start(manualHost: "") }
                    self.queue.asyncAfter(deadline: .now() + min(0.5 * Double(self.failures), 3)) {
                        if self.failures >= 2, let h = base.host, let p = base.port { self.hostLabel = "Retrying \(h):\(p)" }
                        self.sendNext()
                    }
                }
            }
        }.resume()
    }

    private func report() {
        let label = hostLabel, n = items.count
        DispatchQueue.main.async { self.onState?(label, n) }
    }
}
