import Foundation

/// The `Content-Length` framing of the language server protocol.
enum LSPFraming {
    static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)

        return data
    }

    /// Reads whole messages out of a byte stream that delivers them in arbitrary pieces.
    struct Reader {
        private var buffer = Data()

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// The next complete message body, or nil if more bytes are needed. A header that cannot
        /// be understood throws: the stream is out of step and nothing after it can be trusted.
        mutating func next() throws -> Data? {
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

            let header = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
            var length: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            guard let length, length >= 0 else { throw LSPError.malformedHeader(header) }

            let bodyStart = separator.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }

            let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
            buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))

            return body
        }
    }
}

public enum LSPError: Error, Equatable, Sendable {
    case malformedHeader(String)
    case malformedMessage
    /// The server answered with an error.
    case server(code: Int, message: String)
    /// The connection ended before the answer came.
    case connectionClosed
    /// The server was restarted while the request was out; its answer, if any, is for a past session.
    case restarted
    case notRunning
}
