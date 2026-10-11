import AppKit
import IDEApplication

public extension FileNameTone {
    var colour: NSColor {
        switch self {
        case .normal: .labelColor
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .orange: .systemOrange
        }
    }
}
