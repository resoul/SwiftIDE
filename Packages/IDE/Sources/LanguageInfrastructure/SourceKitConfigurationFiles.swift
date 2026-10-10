import Foundation
import IDEApplication

/// Reads the configuration files SourceKit-LSP reads (upstream "Configuration File"): the user's, from
/// lowest priority to highest, and the project's `.sourcekit-lsp/config.json`, which overrides them.
/// The server reads them only when it starts, so a change is for the next start.
///
/// Only the places the documentation names are read: `~/.sourcekit-lsp`, `~/Library/Application
/// Support/org.swift.sourcekit-lsp` and `$XDG_CONFIG_HOME/sourcekit-lsp`. The documentation also says
/// "the other Library folders"; those are not read, and not verified.
public struct SourceKitConfigurationFiles: ConfigurationFileReading {
    private let home: String
    private let xdgConfigHome: String?

    public init(
        home: String = NSHomeDirectory(),
        xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    ) {
        self.home = home
        self.xdgConfigHome = xdgConfigHome
    }

    public func projectFile(root: String) -> ConfigurationFile {
        Self.read((root as NSString).appendingPathComponent(".sourcekit-lsp/config.json"))
    }

    public func userFiles() -> [ConfigurationFile] {
        var paths = [
            home + "/.sourcekit-lsp/config.json",
            home + "/Library/Application Support/org.swift.sourcekit-lsp/config.json",
        ]
        if let xdgConfigHome, !xdgConfigHome.isEmpty { paths.append(xdgConfigHome + "/sourcekit-lsp/config.json") }

        return paths.map(Self.read)
    }

    /// Whether `path` is named like a project's configuration file (`.sourcekit-lsp/config.json`).
    public static func isConfigurationFile(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)

        return url.lastPathComponent == "config.json" && url.deletingLastPathComponent().lastPathComponent == ".sourcekit-lsp"
    }

    /// Whether `path` is the project's configuration file of the project at `root`.
    public static func isProjectFile(_ path: String, root: String) -> Bool {
        DocumentPath.canonical(path) == DocumentPath.canonical((root as NSString).appendingPathComponent(".sourcekit-lsp/config.json"))
    }

    static func read(_ path: String) -> ConfigurationFile {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }

        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }

        return .present(data)
    }
}
