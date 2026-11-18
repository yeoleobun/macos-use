import Darwin
import Foundation

/// Reads and writes MCP JSON-RPC 2.0 frames over isolated `stdin` / `stdout` file descriptors.
/// Supports both standard newline-delimited JSON lines and `Content-Length:` headers.
public final class MCPStdioTransport: @unchecked Sendable {
    private let inputFD: Int32
    private let outputFD: Int32
    private let writeQueue = DispatchQueue(label: "com.macosuse.mcp.stdout")
    private var readBuffer = Data()

    public init(inputFD: Int32 = STDIN_FILENO, outputFD: Int32) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    public func nextMessageData() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)

        while true {
            if let extracted = popMessageFromBuffer() {
                return extracted
            }
            let bytesRead = Darwin.read(inputFD, &chunk, chunk.count)
            if bytesRead > 0 {
                readBuffer.append(contentsOf: chunk[0..<bytesRead])
            } else if bytesRead == 0 {
                // EOF: flush any trailing JSON message without newline
                let trimmed = readBuffer.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
                readBuffer.removeAll(keepingCapacity: false)
                return trimmed.isEmpty ? nil : Data(trimmed)
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
    }

    public func sendResponse(_ response: JSONRPCResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A) // '\n'
        writeAll(data)
    }

    private func writeAll(_ data: Data) {
        writeQueue.sync {
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let n = Darwin.write(outputFD, base.advanced(by: written), data.count - written)
                    if n > 0 {
                        written += n
                    } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    private func popMessageFromBuffer() -> Data? {
        // Trim leading blank lines / whitespace
        while let first = readBuffer.first, first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09 {
            readBuffer.removeFirst()
        }
        guard !readBuffer.isEmpty else { return nil }

        // Handle Content-Length framing if present
        if let prefixStr = String(data: readBuffer.prefix(32), encoding: .utf8),
           prefixStr.lowercased().hasPrefix("content-length:")
        {
            let sepCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
            let sepLF = Data([0x0A, 0x0A])
            let headerRange: Range<Data.Index>?
            if let r = readBuffer.range(of: sepCRLF) {
                headerRange = r
            } else if let r = readBuffer.range(of: sepLF) {
                headerRange = r
            } else {
                return nil
            }

            guard let sepRange = headerRange,
                  let headerText = String(data: readBuffer[..<sepRange.lowerBound], encoding: .utf8)
            else { return nil }

            var contentLength: Int?
            for line in headerText.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let len = contentLength else {
                readBuffer.removeSubrange(..<sepRange.upperBound)
                return nil
            }

            let bodyStart = sepRange.upperBound
            let bodyEnd = readBuffer.index(bodyStart, offsetBy: len, limitedBy: readBuffer.endIndex)
            guard let validEnd = bodyEnd else { return nil }

            let payload = Data(readBuffer[bodyStart..<validEnd])
            readBuffer.removeSubrange(..<validEnd)
            return payload
        }

        // Standard newline-delimited JSON
        if let nlIndex = readBuffer.firstIndex(of: 0x0A) {
            var lineData = Data(readBuffer[..<nlIndex])
            readBuffer.removeSubrange(...nlIndex)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            return lineData.isEmpty ? nil : lineData
        }

        return nil
    }
}
