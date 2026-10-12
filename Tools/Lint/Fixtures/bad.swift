// The same code with what the tools must find.

struct Sample {
    var label: String
    var detail: String?
    var kind: Int

    public init(label: String, detail: String? = nil,
                kind: Int = 0) {
        self.label = label
        self.detail = detail
        self.kind = kind
    }

    func parts(resolved: Int?) -> [String] {
        guard let resolved else { return [] }
        guard resolved > 0 else { return [label] }
        var parts = [label]
        if resolved > 1 { parts.append("one") }
        if resolved > 2 { parts.append("two") }

        if detail != nil {
            parts.append("detail")
            parts.append("more")
        }
        // The answer, with its note kept next to it.
        return parts
    }

    func single() -> Int {
        return 1
    }

    mutating func again(_ value: Int) {
        if value > 3 {
            label = "big"
            return
        }
        label = "small"
    }
}

extension Sample {
    func limited(_ lock: Lock, _ output: (String) -> Void, _ streamedBytesAreTooManyToShowThemAll: Int) {
        if lock.withLock({ streamedBytesAreTooManyToShowThemAll == 128_000 }) { output("[output preview limited]"); output("again") }
    }
}

class Actions {
    var tracking = Button()
    public func showRemoteSelection() { _ = view; showBranches(nil) }
    /// Filters the branch list.
    @objc private func filterChanged(_ sender: Any?) { render() }
    func configure() {
        tracking.target = self; tracking.action = selector
    }
}
