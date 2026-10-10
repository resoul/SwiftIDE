import AppKit
import EditorPlatformTextKit
import EditorUI

/// What one `setRenderingAttributes` costs, and what part of it is building the text range.
@MainActor
enum Micro {
    /// What taking the colours off a big document costs (switching colouring off for size): colours
    /// were applied to the part that was in view, then removed over the whole document.
    static func teardown(megabytes: Double) {
        let line = "let values = [" + (1...40).map { "\($0)" }.joined(separator: ", ") + "]\n"
        let editor = TextKitEditorFactory.makeEditor(loadedText: String(repeating: line, count: Int(megabytes * 1_048_576) / line.utf8.count))
        let host = EditorHostView(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        Presenter.present(host)
        guard let tlm = editor.textView.textLayoutManager else { return }
        let total = editor.textView.string.utf16.count
        editor.textView.setSelectedRange(NSRange(location: total / 2, length: 0))
        editor.textView.scrollRangeToVisible(NSRange(location: total / 2, length: 0))
        Presenter.present(host)
        tlm.renderingAttributesValidator = { manager, fragment in
            manager.setRenderingAttributes([.foregroundColor: NSColor.systemBlue], for: fragment.rangeInElement)
        }
        editor.textView.textStorage?.edited(.editedAttributes, range: NSRange(location: total / 2 - 2_000, length: 4_000), changeInLength: 0)
        Presenter.present(host)
        tlm.renderingAttributesValidator = nil
        var removeMs = 0.0, redrawMs = 0.0
        removeMs = milliseconds { tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange) }
        redrawMs = milliseconds { editor.textView.needsDisplay = true; Presenter.present(host) }
        emit(["phase": "teardown", "mb": megabytes, "remove_whole_document_ms": round3(removeMs), "redraw_ms": round3(redrawMs), "footprint_mb": round3(footprintMB())])
    }

    static func run() {
        let line = "let values = [" + (1...600).map { "\($0)" }.joined(separator: ", ") + "]\n"
        let editor = TextKitEditorFactory.makeEditor(loadedText: String(repeating: line, count: 40))
        let host = EditorHostView(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        Presenter.present(host)
        guard let tlm = editor.textView.textLayoutManager, let content = tlm.textContentManager else { return }
        // Offsets of the numbers in the first line.
        let units = Array(line.utf16)
        var spans: [(Int, Int)] = []
        var index = 0
        while index < units.count {
            if units[index] >= 0x30 && units[index] <= 0x39 {
                var end = index
                while end < units.count, units[end] >= 0x30 && units[end] <= 0x39 { end += 1 }
                spans.append((index, end - index))
                index = end
            } else { index += 1 }
        }
        let origin = content.documentRange.location
        var ranges: [NSTextRange] = []
        let buildMs = milliseconds {
            for (location, length) in spans {
                guard let from = content.location(origin, offsetBy: location),
                      let to = content.location(from, offsetBy: length),
                      let range = NSTextRange(location: from, end: to) else { continue }
                ranges.append(range)
            }
        }
        let rangesCopy = ranges
        let setMs = milliseconds {
            for range in rangesCopy { tlm.setRenderingAttributes([.foregroundColor: NSColor.systemBlue], for: range) }
        }
        let removeMs = milliseconds { tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange) }
        let oneCallMs = milliseconds {
            tlm.setRenderingAttributes([.foregroundColor: NSColor.systemBlue], for: rangesCopy[0])
        }
        // The same spans as one run of attributes: a single range covering the whole line.
        let wholeMs = milliseconds {
            if let first = rangesCopy.first, let last = rangesCopy.last, let all = NSTextRange(location: first.location, end: last.endLocation) {
                tlm.setRenderingAttributes([.foregroundColor: NSColor.systemBlue], for: all)
            }
        }
        emit([
            "phase": "micro", "spans": spans.count, "build_ranges_ms": round3(buildMs), "set_all_ms": round3(setMs),
            "per_span_set_us": round3(setMs * 1000 / Double(spans.count)),
            "per_span_build_us": round3(buildMs * 1000 / Double(spans.count)),
            "remove_document_ms": round3(removeMs), "one_call_ms": round3(oneCallMs), "single_range_call_ms": round3(wholeMs)
        ])
    }
}
