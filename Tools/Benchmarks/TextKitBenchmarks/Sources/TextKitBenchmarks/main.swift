import AppKit
import Foundation

// Two modes, one binary:
//   TextKitBenchmarks run <shape> <megabytes> [phaseBudgetSeconds]   one scenario, JSON lines
//   TextKitBenchmarks driver [--quick] <output.json>                 the whole matrix, each
//                                                                    scenario in its own process
let arguments = CommandLine.arguments

if arguments.count >= 4, arguments[1] == "run", let shape = Shape(rawValue: arguments[2]),
   let megabytes = Double(arguments[3]) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApp.finishLaunching()
    let budget = arguments.count > 4 ? (Double(arguments[4]) ?? 40) : 40
    do {
        try await Scenario(shape: shape, megabytes: megabytes, phaseBudgetSeconds: budget).run()
    } catch {
        emit(["phase": "error", "shape": shape.rawValue, "mb": megabytes, "error": "\(error)"])
        exit(1)
    }
} else if arguments.count >= 3, arguments[1] == "driver" {
    let quick = arguments.contains("--quick")
    let output = arguments.last!
    Driver.run(quick: quick, outputPath: output)
} else {
    FileHandle.standardError.write(Data("usage: run <swift|mixed|short|giant> <MB> [budget] | driver [--quick] <out.json>\n".utf8))
    exit(2)
}
