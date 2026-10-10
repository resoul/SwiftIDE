import Foundation
import SpacingRules

// spacing-check [--fix] [--exclude NAME]... PATH...
//
// Checks the blank-line rules of TK-023 in every .swift file under the paths. Prints
// `path:line:column: error: [rule] message` for each violation and exits 1 if there is any.
// With --fix it adds the missing blank lines (only when the result has the same tokens and
// comments) and exits 0. Directories named by --exclude, at any depth, are skipped.
// Exit codes: 0 clean (or fixed), 1 violations, 2 an error such as an unreadable file.

var fix = false
var excluded: Set<String> = [".build", ".swiftpm"]
var roots: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--fix": fix = true
    case "--exclude":
        guard let name = arguments.popFirst() else { fputs("--exclude needs a name\n", stderr); exit(2) }
        excluded.insert(name)
    case "-h", "--help":
        print("usage: spacing-check [--fix] [--exclude NAME]... PATH...")
        exit(0)
    default: roots.append(argument)
    }
}
guard !roots.isEmpty else { fputs("usage: spacing-check [--fix] [--exclude NAME]... PATH...\n", stderr); exit(2) }

func swiftFiles(under root: String, excluded: Set<String>) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else { return root.hasSuffix(".swift") ? [root] : [] }

    var result: [String] = []
    guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
    for case let url as URL in walker {
        if excluded.contains(url.lastPathComponent) {
            walker.skipDescendants()
            continue
        }
        if url.pathExtension == "swift", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            result.append(url.path)
        }
    }
    return result.sorted()
}

var violations = 0
var failed = false
var files = 0
let skipped = excluded
for path in roots.flatMap({ swiftFiles(under: $0, excluded: skipped) }) {
    files += 1
    guard let data = FileManager.default.contents(atPath: path), let source = String(data: data, encoding: .utf8) else {
        fputs("\(path): error: cannot read the file as UTF-8\n", stderr)
        failed = true
        continue
    }
    if fix {
        do {
            if let fixed = try SpacingChecker.fix(source, path: path) {
                try fixed.write(toFile: path, atomically: true, encoding: .utf8)
                print("fixed \(path)")
            }
        } catch {
            fputs("\(path): error: \(error)\n", stderr)
            failed = true
        }
    } else {
        for violation in SpacingChecker.check(source, path: path) {
            print(violation.formatted)
            violations += 1
        }
    }
}
if failed { exit(2) }
if !fix {
    print("spacing-check: \(files) files, \(violations) violations")
    if violations > 0 { exit(1) }
}
