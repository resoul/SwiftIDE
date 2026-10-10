import Darwin
import Foundation

// MARK: Output

/// One JSON object per line on stdout. The driver reads these lines even from a run that is later
/// killed, so results of finished phases survive a timeout in a later one.
func emit(_ values: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

// MARK: Time

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let clock = ContinuousClock()
    let elapsed = try clock.measure(body)
    return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
}

func milliseconds<T>(_ body: () throws -> T, result: inout T?) rethrows -> Double {
    var value: T?
    let time = try milliseconds { value = try body() }
    result = value
    return time
}

struct Stats {
    let count: Int
    let p50: Double, p95: Double, p99: Double, max: Double, mean: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        count = sorted.count
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            let rank = Int((Double(sorted.count) * p).rounded(.up)) - 1
            return sorted[Swift.min(sorted.count - 1, Swift.max(0, rank))]
        }
        p50 = percentile(0.50)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        max = sorted.last ?? .nan
        mean = sorted.isEmpty ? .nan : sorted.reduce(0, +) / Double(sorted.count)
    }

    var json: [String: Any] {
        // No samples: NaN cannot be written as JSON.
        if count == 0 { return ["n": 0] }
        return ["n": count, "p50_ms": round3(p50), "p95_ms": round3(p95), "p99_ms": round3(p99),
         "max_ms": round3(max), "mean_ms": round3(mean)]
    }
}

func round3(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }

// MARK: Memory

/// Physical footprint, the number Activity Monitor calls "Memory", in MB.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
}

/// Highest resident set size so far, in MB.
func peakResidentMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576   // bytes on macOS
}

// MARK: Test data

enum Shape: String {
    /// Typical Swift: LF, mostly ASCII, some Cyrillic and emoji in strings.
    case swift
    /// The same with CRLF and a sprinkling of lone CR and LF.
    case mixedEndings = "mixed"
    /// Many very short lines: paragraph count stress.
    case shortLines = "short"
    /// One line without any newline.
    case giantLine = "giant"
    /// Lines of Swift array literals, `LINE_CHARS` characters each (default 1000): where the
    /// cost of colouring a line starts to hurt.
    case wideLines = "wide"
}

enum Generator {
    private static let swiftBlock: [String] = [
        "import Foundation", "",
        "/// Computes a running total for the given values.",
        "struct Accumulator<Element: Numeric & Sendable>: Sendable {",
        "    private(set) var total: Element = .zero",
        "    private(set) var count = 0", "",
        "    mutating func add(_ value: Element) {",
        "        total += value",
        "        count += 1",
        "    }", "",
        "    func describe(label: String = \"total\") -> String {",
        "        \"\\(label): \\(total) of \\(count) values 📊\"",
        "    }",
        "}", "",
        "extension Accumulator where Element: BinaryInteger {",
        "    var average: Double { count == 0 ? 0 : Double(total) / Double(count) }",
        "}", "",
        "func process(_ items: [Int], using transform: (Int) -> Int) -> Accumulator<Int> {",
        "    var accumulator = Accumulator<Int>()",
        "    for item in items where item % 2 == 0 {",
        "        accumulator.add(transform(item))",
        "    }",
        "    return accumulator",
        "}", ""
    ]

    /// Exactly `bytes` bytes of UTF-8 (a whole number of lines, or of words for the giant line).
    static func make(_ shape: Shape, bytes: Int) -> String {
        switch shape {
        case .swift, .mixedEndings:
            let crlf = shape == .mixedEndings
            var block = ""
            for (index, line) in swiftBlock.enumerated() {
                let ending = crlf ? (index % 17 == 0 ? "\n" : (index % 23 == 0 ? "\r" : "\r\n")) : "\n"
                block += line + ending
            }
            return repeated(block, toAtLeast: bytes)
        case .shortLines:
            return repeated("ab\n", toAtLeast: bytes)
        case .giantLine:
            return repeated("word поток 😀 value, ", toAtLeast: bytes)
        case .wideLines:
            let width = Int(ProcessInfo.processInfo.environment["LINE_CHARS"] ?? "") ?? 1_000
            var lines: [String] = []
            var produced = 0, number = 0
            while produced < bytes {
                var line = "let values\(lines.count) = ["
                while line.utf8.count < width {
                    number += 1
                    line += "\(number), "
                }
                line += "0]\n"
                produced += line.utf8.count
                lines.append(line)
            }
            return lines.joined()
        }
    }

    private static func repeated(_ unit: String, toAtLeast bytes: Int) -> String {
        let unitBytes = unit.utf8.count
        let copies = max(1, (bytes + unitBytes - 1) / unitBytes)
        return String(repeating: unit, count: copies)
    }
}
