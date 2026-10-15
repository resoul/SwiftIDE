import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    /// Lowercase keys, including when the response is supplied by a test transport.
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }

    /// Opt-in validation: polling and other service flows can inspect the raw response instead.
    public func requireSuccess(now: Date = Date()) throws {
        guard (200...299).contains(status) else {
            throw HTTPError.status(code: status, retryAfter: retryAfter(relativeTo: now))
        }
    }

    /// Metadata only; the transport never schedules a retry itself.
    public func retryAfter(relativeTo now: Date = Date()) -> TimeInterval? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = TimeInterval(raw), seconds.isFinite else { return nil }

            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            guard var date = formatter.date(from: raw) else { continue }

            // RFC 9110's obsolete two-digit year must not resolve more than 50 years into the future.
            if format.contains("-yy "), let boundary = Calendar(identifier: .gregorian)
                .date(byAdding: .year, value: 50, to: now), date > boundary {
                date = Calendar(identifier: .gregorian).date(byAdding: .year, value: -100, to: date) ?? date
            }

            return max(0, date.timeIntervalSince(now))
        }

        return nil
    }
}
