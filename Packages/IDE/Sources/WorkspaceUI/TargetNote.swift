import IDEApplication

/// The words about a file's target for the window subtitle.
public enum TargetNote {
    public static func text(names: [String], basis: MembershipBasis? = .listed) -> String? {
        switch names.count {
        case 0: nil
        case 1: basis == .inferred ? "Target: \(names[0]) (inferred)" : "Target: \(names[0])"
        default: "Target: ambiguous (\(names.joined(separator: ", ")))"
        }
    }
}
