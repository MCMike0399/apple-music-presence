import Foundation

/// Discord Rich Presence over the local IPC socket (`$TMPDIR/discord-ipc-N`).
/// Reconnects automatically and replays the last activity after a reconnect.
final class DiscordClient {
    enum ConnectionState: Equatable { case disconnected, connecting, connected(username: String) }

    var onStateChange: ((ConnectionState) -> Void)?

    private(set) var state: ConnectionState = .disconnected {
        didSet { if state != oldValue { DispatchQueue.main.async { self.onStateChange?(self.state) } } }
    }

    private var clientId: String
    private let queue = DispatchQueue(label: "amp.discord")
    private var fd: Int32 = -1
    private var reader: Thread?
    private var reconnectTimer: DispatchSourceTimer?
    private var reconnectDelay: TimeInterval = 2
    private var enabled = false
    private var lastActivity: [String: Any]?
    private var lastSentJSON: String?
    private var nonce = 0
    private let pid = Int(ProcessInfo.processInfo.processIdentifier)

    init(clientId: String) {
        self.clientId = clientId
    }

    /// Switches Discord application. Forces a reconnect since the app id is bound at handshake.
    func setClientId(_ id: String) {
        queue.async {
            guard id != self.clientId else { return }
            self.clientId = id
            if self.enabled {
                self.closeSocket()
                self.scheduleReconnect(after: 0.5)
            }
        }
    }

    func start() {
        queue.async {
            guard !self.enabled else { return }
            self.enabled = true
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            if self.fd >= 0 {
                self.sendFrame(opcode: 1, payload: ["cmd": "SET_ACTIVITY", "args": ["pid": self.pid], "nonce": self.nextNonce()])
            }
            self.lastActivity = nil
            self.lastSentJSON = nil
            self.closeSocket()
        }
    }

    /// Sets (or clears, with nil) the activity. Duplicate payloads are suppressed.
    func setActivity(_ activity: [String: Any]?) {
        queue.async {
            self.lastActivity = activity
            self.flushActivity()
        }
    }

    // MARK: - Connection

    private static func candidateSocketPaths() -> [String] {
        var dirs: [String] = []
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { dirs.append(tmp) }
        dirs.append(NSTemporaryDirectory())
        dirs.append("/tmp")
        var seen = Set<String>()
        var paths: [String] = []
        for dir in dirs where !seen.contains(dir) {
            seen.insert(dir)
            for i in 0..<10 { paths.append((dir as NSString).appendingPathComponent("discord-ipc-\(i)")) }
        }
        return paths
    }

    private func connect() {
        guard enabled, fd < 0 else { return }
        state = .connecting
        for path in Self.candidateSocketPaths() where FileManager.default.fileExists(atPath: path) {
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(sock); continue }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { buf in
                    for (i, b) in bytes.enumerated() { buf[i] = b }
                    buf[bytes.count] = 0
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) }
            }
            if rc == 0 {
                fd = sock
                Log.shared.info("Discord: connected to \(path)")
                startReader()
                sendFrame(opcode: 0, payload: ["v": 1, "client_id": clientId])
                return
            }
            close(sock)
        }
        state = .disconnected
        scheduleReconnect(after: reconnectDelay)
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self, self.enabled, self.fd < 0 else { return }
            self.connect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func closeSocket() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        lastSentJSON = nil
        state = .disconnected
    }

    private func handleDisconnect() {
        queue.async {
            guard self.fd >= 0 else { return }
            Log.shared.warn("Discord: connection lost")
            self.closeSocket()
            if self.enabled { self.scheduleReconnect(after: self.reconnectDelay) }
        }
    }

    // MARK: - Framing

    private func nextNonce() -> String {
        nonce += 1
        return String(nonce)
    }

    private func sendFrame(opcode: UInt32, payload: [String: Any]) {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var header = Data()
        var op = opcode.littleEndian
        var len = UInt32(body.count).littleEndian
        header.append(Data(bytes: &op, count: 4))
        header.append(Data(bytes: &len, count: 4))
        let frame = header + body
        let written = frame.withUnsafeBytes { ptr -> Int in
            var total = 0
            while total < frame.count {
                let n = write(fd, ptr.baseAddress! + total, frame.count - total)
                if n <= 0 { return -1 }
                total += n
            }
            return total
        }
        if written < 0 {
            handleDisconnect()
        }
    }

    private func flushActivity() {
        guard case .connected = state, fd >= 0 else { return }
        var args: [String: Any] = ["pid": pid]
        if let activity = lastActivity { args["activity"] = activity }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": nextNonce()]
        // Compare without the nonce so identical activities are not re-sent.
        if let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            if json == lastSentJSON { return }
            lastSentJSON = json
        }
        sendFrame(opcode: 1, payload: payload)
    }

    private func startReader() {
        let sock = fd
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            var pending = Data()
            while true {
                let n = read(sock, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(buffer, count: n)
                while pending.count >= 8 {
                    let op = pending.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
                    let len = Int(pending.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
                    guard pending.count >= 8 + len else { break }
                    let body = pending.subdata(in: 8..<(8 + len))
                    pending.removeSubrange(0..<(8 + len))
                    self?.handleFrame(opcode: op, body: body, sock: sock)
                }
            }
            self?.handleDisconnect()
        }
        thread.name = "discord-ipc-reader"
        thread.start()
        reader = thread
    }

    private func handleFrame(opcode: UInt32, body: Data, sock: Int32) {
        queue.async {
            guard sock == self.fd else { return } // stale reader after a reconnect
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            switch opcode {
            case 1:
                let evt = json["evt"] as? String
                if evt == "READY" {
                    let user = (json["data"] as? [String: Any])?["user"] as? [String: Any]
                    let name = user?["username"] as? String ?? "?"
                    self.reconnectDelay = 2
                    self.state = .connected(username: name)
                    Log.shared.info("Discord: ready as \(name)")
                    self.flushActivity()
                } else if evt == "ERROR" {
                    let data = json["data"] as? [String: Any]
                    Log.shared.error("Discord: error \(data?["code"] ?? "?"): \(data?["message"] ?? "")")
                }
            case 2:
                Log.shared.warn("Discord: server closed the connection: \(json)")
                self.handleDisconnect()
            case 3:
                self.sendFrame(opcode: 4, payload: json)
            default:
                break
            }
        }
    }
}
