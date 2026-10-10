import Foundation

/// One target of a package, as `swift package describe` names it.
public struct PackageTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case library, executable, test, other
    }

    public let name: String
    public let kind: Kind
    /// The target's folder, absolute.
    public let directory: String
    /// The files the package lists for it, relative to `directory`. Headers are not among them.
    public let sources: [String]

    public init(name: String, kind: Kind, directory: String, sources: [String]) {
        self.name = name
        self.kind = kind
        self.directory = directory
        self.sources = sources
    }
}

/// Which target a file belongs to.
public enum TargetMembership: Equatable, Sendable {
    case none
    case one(PackageTarget)
    /// More than one target claims the file. SwiftPM refuses overlapping sources, so a package does not
    /// give this; a build system that can (Xcode) will, and the user then chooses.
    case several([PackageTarget])

    public var names: [String] {
        switch self {
        case .none: []
        case .one(let target): [target.name]
        case .several(let targets): targets.map(\.name)
        }
    }
}

/// The targets of a package and where their files are: what is asked of a file to know its target.
public struct PackageLayout: Equatable, Sendable {
    public struct ParseError: Error, Equatable {
        public let reason: String
    }

    public let targets: [PackageTarget]

    public init(targets: [PackageTarget]) {
        self.targets = targets
    }

    /// Reads the JSON of `swift package describe --type json`. Anything that is not it is refused
    /// rather than guessed at.
    public static func parse(_ data: Data, root: String) throws -> PackageLayout {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["targets"] as? [[String: Any]] else {
            throw ParseError(reason: "not the output of `swift package describe`")
        }

        let targets = try raw.map { entry -> PackageTarget in
            guard let name = entry["name"] as? String, let path = entry["path"] as? String else {
                throw ParseError(reason: "a target without a name or a path")
            }

            let kind: PackageTarget.Kind = switch entry["type"] as? String {
            case "library": .library
            case "executable": .executable
            case "test": .test
            default: .other
            }

            return PackageTarget(
                name: name,
                kind: kind,
                directory: (root as NSString).appendingPathComponent(path),
                sources: entry["sources"] as? [String] ?? []
            )
        }

        return PackageLayout(targets: targets)
    }

    /// A file the package lists belongs to the target that lists it; one it does not (made since, or
    /// a header) belongs to the innermost target folder that holds it; one outside every target to none.
    public func membership(of file: String) -> TargetMembership {
        func relative(to directory: String) -> String? {
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"

            return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : nil
        }

        let listed = targets.filter { target in relative(to: target.directory).map(target.sources.contains) ?? false }
        if !listed.isEmpty { return Self.membership(of: listed) }

        let holding = targets.filter { relative(to: $0.directory) != nil }
        guard let deepest = holding.map({ $0.directory.count }).max() else { return .none }

        return Self.membership(of: holding.filter { $0.directory.count == deepest })
    }

    private static func membership(of targets: [PackageTarget]) -> TargetMembership {
        targets.count == 1 ? .one(targets[0]) : .several(targets)
    }
}

/// Asks a package for its layout. The implementation runs a process, so it is async and bounded.
public protocol PackageDescribing: Sendable {
    func describe(root: String) async throws -> PackageLayout
}

/// The words about a file's target for the window subtitle.
public enum TargetNote {
    public static func text(names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "Target: \(names[0])"
        default: "Target: ambiguous (\(names.joined(separator: ", ")))"
        }
    }
}
