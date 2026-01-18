import Foundation

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "WindowGroups.logger")
    private let formatter: DateFormatter
    private var entries: [String] = []
    private let maxEntries = 200
    private let fileURL: URL

    private init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.formatter = formatter

        let fileManager = FileManager.default
        let logsDir = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
        if let logsDir {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
            fileURL = logsDir.appendingPathComponent("WindowGroups.log")
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
        } else {
            fileURL = URL(fileURLWithPath: "/tmp/WindowGroups.log")
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    var logFileURL: URL {
        fileURL
    }

    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        queue.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            print(entry)
            self.appendToFile(entry)
        }
    }

    func recentEntries(limit: Int = 20) -> [String] {
        queue.sync {
            let slice = entries.suffix(limit)
            return Array(slice)
        }
    }

    func clear() {
        queue.async {
            self.entries.removeAll()
            try? "".write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func appendToFile(_ entry: String) {
        guard let data = (entry + "\n").data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            print("Logger write failed: \(error)")
        }
    }
}
