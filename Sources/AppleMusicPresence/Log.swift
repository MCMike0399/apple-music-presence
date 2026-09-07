import Foundation

/// Minimal file + stderr logger. One line per event, ISO-8601 timestamps.
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "amp.log")
    private let fileURL: URL
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let maxBytes = 1_000_000

    private init() {
        fileURL = Paths.supportDirectory.appendingPathComponent("presence.log")
    }

    func info(_ message: String) { write("INFO", message) }
    func warn(_ message: String) { write("WARN", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            self.rotateIfNeeded()
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.data(using: .utf8)!.write(to: self.fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let old = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}

enum Paths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AppleMusicPresence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let settingsFile = supportDirectory.appendingPathComponent("settings.json")
    static let cacheFile = supportDirectory.appendingPathComponent("artwork-cache.json")
}
