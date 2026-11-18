import Foundation

/// Audit and flight-recorder logging recent UI automation events to an in-memory ring buffer and optional JSONL + frames on disk.
public actor TrajectoryRecorder {
    public static let shared = TrajectoryRecorder()

    private let maxBufferedEvents = 100
    private var buffer: [TrajectoryEvent] = []
    private var sequence: Int = 0
    private var traceDirectory: String?
    private var saveImages: Bool = true
    private var eventsWrittenToDisk: Int = 0
    private let isoFormatter: ISO8601DateFormatter

    public init() {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
    }

    public func status() -> (active: Bool, directory: String?, saveImages: Bool, bufferedEvents: Int, diskEvents: Int) {
        (traceDirectory != nil, traceDirectory, saveImages, buffer.count, eventsWrittenToDisk)
    }

    public func startTrace(directory: String?, saveImages: Bool = true) throws -> String {
        let dirPath: String
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dirPath = (directory as NSString).expandingTildeInPath
        } else {
            let stamp = Int(Date().timeIntervalSince1970)
            dirPath = "/tmp/macos-use-traces/trace-\(stamp)"
        }

        try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        let jsonlPath = (dirPath as NSString).appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: jsonlPath) {
            FileManager.default.createFile(atPath: jsonlPath, contents: Data())
        }

        self.traceDirectory = dirPath
        self.saveImages = saveImages
        self.eventsWrittenToDisk = 0
        return dirPath
    }

    public func stopTrace() -> (active: Bool, directory: String?, eventsWritten: Int) {
        let prevDir = traceDirectory
        let written = eventsWrittenToDisk
        traceDirectory = nil
        return (false, prevDir, written)
    }

    @discardableResult
    public func record(
        tool: String,
        targetSummary: String,
        methodUsed: String? = nil,
        uiChanged: Bool? = nil,
        escalated: Bool? = nil,
        elapsedMs: Int,
        snapshotID: String? = nil,
        imageData: Data? = nil,
        error: String? = nil
    ) -> TrajectoryEvent {
        sequence += 1
        var framePath: String?

        if let dir = traceDirectory {
            if saveImages, let imageData, !imageData.isEmpty {
                let fname = String(format: "frame_%04d.jpg", sequence)
                let fpath = (dir as NSString).appendingPathComponent(fname)
                if (try? imageData.write(to: URL(fileURLWithPath: fpath), options: .atomic)) != nil {
                    framePath = fpath
                }
            }
        }

        let event = TrajectoryEvent(
            seq: sequence,
            timestamp: isoFormatter.string(from: Date()),
            tool: tool,
            targetSummary: targetSummary,
            methodUsed: methodUsed,
            uiChanged: uiChanged,
            escalated: escalated,
            elapsedMs: elapsedMs,
            snapshotID: snapshotID,
            framePath: framePath,
            error: error
        )

        buffer.append(event)
        while buffer.count > maxBufferedEvents {
            buffer.removeFirst()
        }

        if let dir = traceDirectory {
            let jsonlPath = (dir as NSString).appendingPathComponent("events.jsonl")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let encoded = try? encoder.encode(event),
               let lineData = String(data: encoded, encoding: .utf8).map({ $0 + "\n" })?.data(using: .utf8)
            {
                if let handle = FileHandle(forWritingAtPath: jsonlPath) {
                    _ = try? handle.seekToEnd()
                    _ = try? handle.write(contentsOf: lineData)
                    try? handle.close()
                    eventsWrittenToDisk += 1
                } else if (try? lineData.write(to: URL(fileURLWithPath: jsonlPath), options: .atomic)) != nil {
                    eventsWrittenToDisk += 1
                }
            }
        }

        return event
    }

    public func recentEvents(limit: Int = 25) -> [TrajectoryEvent] {
        let count = max(1, min(limit, maxBufferedEvents))
        return Array(buffer.suffix(count))
    }
}
