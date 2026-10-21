import Foundation
import IDEApplication
import IDEDomain

/// Checks a Metal shader by compiling it: `xcrun metal -fsyntax-only`, which is the compiler that will
/// build it, so what it says is what the build would say. (clangd cannot read Metal: it does not know
/// the language.) The text is written to a temporary file next to nothing else, and the folder of the
/// real file is given as an include folder, so `#include "Shared.h"` still finds its header. The
/// Metal toolchain is a separate download in recent Xcode versions; without it there is one note saying so.
public struct MetalChecker: SyntaxChecking {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(20)) { self.timeout = timeout }

    public func supports(_ language: DocumentLanguage) -> Bool { language == .metal }

    public func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String,
        directory: String?
    ) async -> [DocumentDiagnostic] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftide-metal-\(UUID().uuidString)")
        let file = scratch.appendingPathComponent("shader.metal")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data(String(decoding: text, as: UTF16.self).utf8).write(to: file)
        } catch {
            return []
        }

        defer { try? FileManager.default.removeItem(at: scratch) }

        // The shell folds the compiler's messages into its output whatever the exit status is.
        var script = "xcrun metal -fsyntax-only -x metal \"$0\""
        var arguments = [file.path]
        if let directory {
            script += " -I \"$1\""
            arguments.append(directory)
        }

        script += " 2>&1; exit 0"
        let output: Data
        do {
            output = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script] + arguments,
                timeout: timeout,
                outputLimit: 512 * 1024
            )
        } catch {
            return []
        }

        return Self.parse(String(decoding: output, as: UTF8.self), text: text, file: file.path)
    }

    private static let diagnostic = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+): (fatal error|error|warning): (.*)$"#
    )

    /// The compiler's messages about `file`, placed in the text. Messages about other files (the headers it
    /// includes) are left out, and so are notes, which only explain the message before them.
    static func parse(_ output: String, text: [UInt16], file: String) -> [DocumentDiagnostic] {
        if output.contains("unable to find utility") || output.contains("error: sdk \"") {
            return [DocumentDiagnostic(
                range: UTF16TextRange(location: 0, length: 0),
                severity: .information,
                message: "The Metal compiler is not installed, so this shader is not checked "
                    + "(xcodebuild -downloadComponent MetalToolchain)",
                source: "Metal"
            )]
        }

        var lineStarts = [0]
        for (index, unit) in text.enumerated() where unit == 0x0A { lineStarts.append(index + 1) }

        var found: [DocumentDiagnostic] = []
        for line in output.split(separator: "\n") {
            let string = String(line)
            let range = NSRange(location: 0, length: (string as NSString).length)
            guard let match = diagnostic.firstMatch(in: string, range: range) else { continue }

            let path = (string as NSString).substring(with: match.range(at: 1))
            guard path == file, let number = Int((string as NSString).substring(with: match.range(at: 2))),
                  let column = Int((string as NSString).substring(with: match.range(at: 3))),
                  number >= 1, number <= lineStarts.count else { continue }

            let kind = (string as NSString).substring(with: match.range(at: 4))
            let start = lineStarts[number - 1]
            var end = start
            while end < text.count, text[end] != 0x0A, text[end] != 0x0D { end += 1 }

            // The column counts bytes of UTF-8; this counts UTF-16 units.
            var bytes = 0
            var location = start
            while location < end, bytes < column - 1 {
                let unit = text[location]
                bytes += unit < 0x80 ? 1 : (unit < 0x800 ? 2 : 3)
                location += 1
            }

            var length = 0
            while location + length < end, Scan.isWordPart(text[location + length]) { length += 1 }

            let place = min(location, text.count)
            found.append(DocumentDiagnostic(
                range: UTF16TextRange(location: place, length: min(max(1, length), text.count - place)),
                severity: kind == "warning" ? .warning : .error,
                message: (string as NSString).substring(with: match.range(at: 5)),
                source: "Metal"
            ))
        }

        return found
    }
}

private enum Scan {
    static func isWordPart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F ||
            (unit >= 0x30 && unit <= 0x39)
    }
}
