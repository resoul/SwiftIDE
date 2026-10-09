import IDEDomain

/// How the grammar's capture names (the usual `@keyword.function`, `@string.escape`, ...) map to
/// the kinds the editor colours. Names with no entry here are left plain.
enum CaptureKinds {
    static func kind(for name: String) -> HighlightKind? {
        switch name {
        case "keyword.directive": return .attribute
        case "comment.documentation": return .documentation
        case "variable.member": return .property
        case "variable.parameter": return .parameter
        case "variable.builtin": return .builtin
        case "string.escape", "character.special", "punctuation.special": return .escape
        case "function.macro", "constant.macro": return .attribute
        case "constructor": return .type
        case "boolean", "constant.builtin": return .constant
        case "attribute": return .attribute
        case "label": return .label
        case "operator": return .operator
        default: break
        }
        let family = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        switch family {
        case "keyword": return .keyword
        case "string": return .string
        case "number": return .number
        case "comment": return .comment
        case "type": return .type
        case "function": return .function
        case "constant": return .constant
        default: return nil   // variable, punctuation.*, spell, ...
        }
    }
}
