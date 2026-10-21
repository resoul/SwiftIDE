import Foundation
import IDEApplication
import IDEDomain
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterYAML

/// Finds syntax errors by parsing with the Tree-sitter grammar of the language: where the parser had to
/// give up on the text (an error node) or add something to make sense of it (a missing node) there is a
/// problem. A YAML file is a mistake there; a shell script only a warning, because the grammar is
/// bash's and scripts for other shells may read differently.
public struct TreeSitterChecks: SyntaxChecking {
    private static let limit = 10
    private static let sizeLimit = 1_500_000

    public init() {}

    public func supports(_ language: DocumentLanguage) -> Bool { language == .yaml || language == .shell }

    public func check(
        _ text: [UInt16],
        language: DocumentLanguage,
        fileName: String,
        directory: String?
    ) async -> [DocumentDiagnostic] {
        guard text.count <= Self.sizeLimit, let grammar = Self.grammar(for: language) else { return [] }

        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(String(decoding: text, as: UTF16.self)),
              let root = tree.rootNode, root.hasError else { return [] }

        let severity: DocumentDiagnostic.Severity = language == .yaml ? .error : .warning
        let source = language == .yaml ? "YAML" : "Shell"
        var found: [DocumentDiagnostic] = []
        var pending: [Node] = [root]
        while let node = pending.popLast(), found.count < Self.limit * 4 {
            if node.isMissing {
                let location = Int(node.byteRange.lowerBound) / 2
                found.append(DocumentDiagnostic(
                    range: UTF16TextRange(location: min(location, text.count), length: 0),
                    severity: severity,
                    message: "Missing \(Self.describe(node.nodeType ?? "token"))",
                    source: source
                ))
            } else if node.nodeType == "ERROR" {
                let range = Int(node.byteRange.lowerBound) / 2..<min(text.count, Int(node.byteRange.upperBound) / 2)
                found.append(DocumentDiagnostic(
                    range: UTF16TextRange(location: range.lowerBound, length: max(1, min(range.count, 40))),
                    severity: severity,
                    message: Self.message(forErrorIn: text, range),
                    source: source
                ))
            } else if node.hasError {
                for index in 0..<node.childCount {
                    if let child = node.child(at: index) { pending.append(child) }
                }
            }
        }

        return Array(found.sorted { $0.range.location < $1.range.location }.prefix(Self.limit))
    }

    static func grammar(for language: DocumentLanguage) -> Language? {
        switch language {
        case .yaml: Language(tree_sitter_yaml())
        case .shell: Language(tree_sitter_bash())
        default: nil
        }
    }

    private static func describe(_ type: String) -> String {
        type.isEmpty ? "token" : "“\(type)”"
    }

    private static func message(forErrorIn text: [UInt16], _ range: Range<Int>) -> String {
        let snippet = String(
            decoding: text[range.lowerBound..<min(range.upperBound, range.lowerBound + 30)],
            as: UTF16.self
        )
        .split(whereSeparator: \.isNewline).first.map(String.init)?
        .trimmingCharacters(in: .whitespaces) ?? ""

        return snippet.isEmpty ? "Syntax error" : "Syntax error near “\(snippet)”"
    }
}
