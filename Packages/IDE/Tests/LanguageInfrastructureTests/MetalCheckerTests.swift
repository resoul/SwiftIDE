import Foundation
import IDEApplication
import IDEDomain
import Testing
@testable import LanguageInfrastructure

private let shader = """
#include <metal_stdlib>
using namespace metal;

kernel void scale(device float *data [[buffer(0)]],
                  uint id [[thread_position_in_grid]]) {
    data[id] *= 2.0;
    undefined_call(id);
}
"""

@Test
func theCompilersMessagesAreFoundInTheTextAtTheirPlace() {
    let text = Array(shader.utf16)
    let output = "/tmp/x/shader.metal:7:5: error: use of undeclared identifier 'undefined_call'\n"
        + "    undefined_call(id);\n    ^\n"
        + "/tmp/x/shader.metal:6:12: warning: unused thing\n/tmp/x/other.h:1:1: error: in a header\n"
        + "/tmp/x/shader.metal:7:5: note: explained\n1 error generated.\n"
    let found = MetalChecker.parse(output, text: text, file: "/tmp/x/shader.metal")
    #expect(found.count == 2)
    #expect(found[0].severity == .error && found[0].message == "use of undeclared identifier 'undefined_call'")
    let nsText = shader as NSString
    #expect(nsText
        .substring(with: NSRange(location: found[0].range.location, length: found[0].range.length)) == "undefined_call")
    #expect(found[1].severity == .warning && found[1].source == "Metal")
    #expect(MetalChecker().supports(.metal) && !MetalChecker().supports(.cpp))
    let past = MetalChecker.parse(
        "/f.metal:99:1: error: x\n/f.metal:8:50: error: past the end of the line\n",
        text: text,
        file: "/f.metal"
    )
    #expect(
        past.count == 1 && past[0].range.location + past[0].range.length <= text.count,
        "a place outside the text is not drawn outside"
    )
}

@Test
func aMissingToolchainIsOneNoteNotAWall() {
    let found = MetalChecker.parse(
        "xcrun: error: unable to find utility \"metal\", not a developer tool or in PATH\n",
        text: [],
        file: "x"
    )
    #expect(found.count == 1 && found[0].severity == .information && found[0].message.contains("MetalToolchain"))
}

@Test
func theRealCompilerFindsTheMistakeInAShaderIfItIsInstalled() async throws {
    let installed = (try? await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: ["-find", "metal"],
        timeout: .seconds(10),
        outputLimit: 4_096
    )) != nil
    guard installed else { return }

    let found = await MetalChecker().check(Array(shader.utf16), language: .metal, fileName: "k.metal", directory: nil)
    #expect(found.contains { $0.severity == .error && $0.message.contains("undefined_call") })
    let source = "#include <metal_stdlib>\n"
        + "kernel void f(device float *a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a[i] = 1; }\n"
    let good = await MetalChecker().check(Array(source.utf16), language: .metal, fileName: "k.metal", directory: nil)
    #expect(good.isEmpty)
}
