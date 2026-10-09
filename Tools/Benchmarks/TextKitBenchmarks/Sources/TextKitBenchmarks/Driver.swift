import Darwin
import Foundation

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Runs every scenario in a child process with a hard time limit, so a pathological case (a
/// 100 MB single line) is recorded as "did not finish" instead of hanging the whole run.
enum Driver {
    struct Case {
        let shape: Shape
        let megabytes: Double
        let timeoutSeconds: Double
    }

    static func run(quick: Bool, outputPath: String) {
        let cases: [Case] = quick
            ? [Case(shape: .swift, megabytes: 0.04, timeoutSeconds: 60), Case(shape: .swift, megabytes: 1, timeoutSeconds: 120)]
            : [
                Case(shape: .swift, megabytes: 0.04, timeoutSeconds: 60),     // ≈ 1000 lines
                Case(shape: .swift, megabytes: 1, timeoutSeconds: 180),
                Case(shape: .swift, megabytes: 10, timeoutSeconds: 360),
                Case(shape: .swift, megabytes: 100, timeoutSeconds: 900),
                Case(shape: .mixedEndings, megabytes: 10, timeoutSeconds: 360),
                Case(shape: .shortLines, megabytes: 10, timeoutSeconds: 360),
                // Single-line files. Larger than 1 MB is deliberately not run: layout time and memory
                // grow with the line, and an 8 GB machine would be pushed into swap.
                Case(shape: .giantLine, megabytes: 0.05, timeoutSeconds: 120),
                Case(shape: .giantLine, megabytes: 0.1, timeoutSeconds: 120),
                Case(shape: .giantLine, megabytes: 0.25, timeoutSeconds: 150),
                Case(shape: .giantLine, megabytes: 1, timeoutSeconds: 240)
            ]
        var results: [[String: Any]] = []
        for item in cases {
            FileHandle.standardError.write(Data("running \(item.shape.rawValue) \(item.megabytes) MB …\n".utf8))
            let outcome = runChild(item)
            results.append(outcome)
            // Written after every scenario: a crash of the driver keeps what was measured.
            writeResults(results, to: outputPath)
        }
    }

    private static func runChild(_ item: Case) -> [String: Any] {
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["run", item.shape.rawValue, String(item.megabytes), "40"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        let started = Date()
        do { try process.run() } catch {
            return ["shape": item.shape.rawValue, "mb": item.megabytes, "error": "\(error)"]
        }
        var timedOut = false
        while process.isRunning {
            if Date().timeIntervalSince(started) > item.timeoutSeconds {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.availableData)
        let text = buffer.text
        let phases = text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        return [
            "shape": item.shape.rawValue, "mb": item.megabytes, "phases": phases,
            "timed_out": timedOut, "timeout_s": item.timeoutSeconds,
            "exit_status": timedOut ? -1 : Int(process.terminationStatus),
            "wall_s": (Date().timeIntervalSince(started) * 10).rounded() / 10
        ]
    }

    private static func writeResults(_ results: [[String: Any]], to path: String) {
        let machine = [
            "chip": sysctlString("machdep.cpu.brand_string"),
            "memory_gb": (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "date": ISO8601DateFormatter().string(from: Date())
        ] as [String: Any]
        let document: [String: Any] = ["machine": machine, "results": results]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
