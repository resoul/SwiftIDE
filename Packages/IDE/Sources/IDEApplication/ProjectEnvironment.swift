import Foundation

/// The tools a project is served with: the `swift` and the `sourcekit-lsp` that were found, and the
/// version `swift` reported. Two toolchains are the same only if all three are.
public struct Toolchain: Equatable, Sendable {
    public let swift: String
    public let sourceKitLSP: String
    public let version: String

    public init(swift: String, sourceKitLSP: String, version: String) {
        self.swift = swift
        self.sourceKitLSP = sourceKitLSP
        self.version = version
    }
}

/// Finds the toolchain the application uses. The implementation runs processes, so it is async.
public protocol ToolchainResolving: Sendable {
    /// nil when it cannot be told (no Xcode selected, a tool does not answer).
    func resolve() async -> Toolchain?
}

/// What one configuration file of SourceKit-LSP is, as far as it could be read.
public enum ConfigurationFile: Equatable, Sendable {
    case absent
    case present(Data)
    /// It is there and could not be read.
    case unreadable
}

/// Where SourceKit-LSP's configuration files are looked for. The implementation reads files.
public protocol ConfigurationFileReading: Sendable {
    /// `.sourcekit-lsp/config.json` of the project at `root`.
    func projectFile(root: String) -> ConfigurationFile
    /// The files of the user, lowest priority first (the project's file overrides them all).
    func userFiles() -> [ConfigurationFile]
}

/// The build configuration (`debug` or `release`) the server prepares and indexes the package in. It
/// is a setting of the server, so it takes part in what a context is (ADR-034).
public enum BuildConfigurationSetting: Equatable, Sendable {
    /// Chosen by the project's own configuration file, which the server obeys.
    case selected(String)
    /// Not chosen by the project: it comes from the user's files or from the server's default.
    case inherited(String)
    /// What the server uses cannot be confirmed: a file it reads is not readable as JSON with a
    /// known value, or the project's file waits for the user's decision about trust.
    case unknown

    public var value: String? {
        switch self {
        case .selected(let value), .inherited(let value): value
        case .unknown: nil
        }
    }

    /// The value the server uses when no file says otherwise (measured on Xcode 27.0, ADR-034).
    public static let serverDefault = "debug"

    /// What the files say, in the server's order of priority: the server's default, the user's files,
    /// the project's file. The project's file is obeyed only when the user trusts the project's
    /// configuration; refused, it is ignored (ADR-028), and undecided, what the server does is not
    /// yet known.
    public static func resolve(project: ConfigurationFile, user: [ConfigurationFile], trust: ConfigurationTrust) -> Self {
        var inherited = serverDefault
        for file in user {
            switch read(file) {
            case .absent, .noValue: continue
            case .value(let value): inherited = value
            case .invalid: return .unknown
            }
        }

        switch (read(project), trust) {
        case (.absent, _), (.noValue, _), (_, .refused): return .inherited(inherited)
        case (.value(let value), .granted): return .selected(value)
        case (.value, .undecided), (.invalid, .granted), (.invalid, .undecided): return .unknown
        }
    }

    private enum Reading {
        case absent, noValue, value(String), invalid
    }

    private static func read(_ file: ConfigurationFile) -> Reading {
        switch file {
        case .absent: return .absent
        case .unreadable: return .invalid
        case .present(let data):
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .invalid }

            guard let swiftPM = object["swiftPM"] else { return .noValue }

            guard let section = swiftPM as? [String: Any] else { return .invalid }

            guard let setting = section["configuration"] else { return .noValue }

            guard let name = setting as? String, name == "debug" || name == "release" else { return .invalid }

            return .value(name)
        }
    }
}

/// The tools and settings a project is served with. A change of either makes earlier answers
/// (what a target is, what the server prepared) stale.
public struct ProjectEnvironment: Equatable, Sendable {
    public var toolchain: Toolchain?
    public var configuration: BuildConfigurationSetting
    /// An opaque fingerprint of the server's configuration inputs, including options the client
    /// does not interpret. nil until the files have been read; a refused project file is excluded.
    public var configurationFingerprint: String?

    public init(
        toolchain: Toolchain? = nil,
        configuration: BuildConfigurationSetting = .unknown,
        configurationFingerprint: String? = nil
    ) {
        self.toolchain = toolchain
        self.configuration = configuration
        self.configurationFingerprint = configurationFingerprint
    }
}
