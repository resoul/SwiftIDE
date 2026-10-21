import Foundation

/// The language of a document, as one value for everyone who needs it: colours, language servers
/// and editor commands. It names the language; grammars and protocol types live elsewhere.
public enum DocumentLanguage: String, CaseIterable, Codable, Sendable {
    case swift
    case c
    case cpp
    case objectiveC
    case objectiveCPP
    case markdown
    case json
    case xml
    case yaml
    case toml
    case shell
    /// Key-value and directive files without a grammar of their own: `.gitignore`, `.xcconfig`,
    /// `.strings`, `.pbxproj`, a Makefile or a Dockerfile.
    case config
    /// Metal shaders, which read as C++.
    case metal
    case plainText

    /// C and the languages built on it, which are served by clangd and need the build's flags.
    public var isCFamily: Bool {
        switch self {
        case .c, .cpp, .objectiveC, .objectiveCPP: true
        case .swift, .markdown, .json, .xml, .yaml, .toml, .shell, .config, .metal, .plainText: false
        }
    }

    /// Whether the language has blocks that can be folded: braces, or the sections and code fences
    /// of Markdown.
    public var supportsFolding: Bool {
        switch self {
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP, .markdown, .json, .xml, .yaml, .toml, .shell, .config,
             .metal:
            true
        case .plainText: false
        }
    }

    /// What starts a comment that runs to the end of the line, if the language has one.
    public var lineCommentPrefix: String? {
        switch self {
        case .swift, .c, .cpp, .objectiveC, .objectiveCPP, .metal: "//"
        case .yaml, .toml, .shell: "#"
        case .markdown, .json, .xml, .config, .plainText: nil
        }
    }

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .objectiveCPP: "Objective-C++"
        case .markdown: "Markdown"
        case .json: "JSON"
        case .xml: "XML"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .shell: "Shell"
        case .config: "Config"
        case .metal: "Metal"
        case .plainText: "Plain Text"
        }
    }

    /// What the file name says. `isProvisional` is for names that fit more than one language: a
    /// `.h` is taken for C until something better is known.
    public struct Guess: Equatable, Sendable {
        public let language: DocumentLanguage
        public let isProvisional: Bool

        public init(language: DocumentLanguage, isProvisional: Bool) {
            self.language = language
            self.isProvisional = isProvisional
        }
    }

    /// Files that are known by their whole name, with no extension or a dot first.
    private static func byWholeName(_ name: String) -> Guess {
        let plain = Guess(language: .plainText, isProvisional: false)
        let lowered = name.lowercased()
        switch lowered {
        case ".gitignore", ".gitattributes", ".gitmodules", ".editorconfig", ".swiftformat", ".swift-version",
             ".dockerignore", ".env", ".npmrc", ".clang-format", "makefile", "gnumakefile", "dockerfile",
             "podfile.lock":
            return lowered == "podfile.lock"
                ? Guess(language: .yaml, isProvisional: false)
                : Guess(language: lowered == ".clang-format" ? .yaml : .config, isProvisional: false)
        case ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile":
            return Guess(language: .shell, isProvisional: false)
        default:
            if lowered.hasPrefix("dockerfile.") || lowered.hasSuffix(".dockerfile") {
                return Guess(language: .config, isProvisional: false)
            }

            return plain
        }
    }

    public static func guess(forPath path: String) -> Guess {
        let name = (path as NSString).lastPathComponent
        let raw = (name as NSString).pathExtension
        // `.C` is C++ by convention; the other names do not depend on case.
        let ext = raw == "C" ? raw : raw.lowercased()
        switch ext {
        case "swift", "swiftinterface": return Guess(language: .swift, isProvisional: false)
        case "c": return Guess(language: .c, isProvisional: false)
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "C": return Guess(language: .cpp, isProvisional: false)
        case "m": return Guess(language: .objectiveC, isProvisional: false)
        case "mm": return Guess(language: .objectiveCPP, isProvisional: false)
        case "h": return Guess(language: .c, isProvisional: true)
        case "md", "markdown", "mdown", "mkd", "mkdn": return Guess(language: .markdown, isProvisional: false)
        case "json", "xcstrings", "resolved", "geojson", "webmanifest", "jsonc":
            return Guess(language: .json, isProvisional: false)
        case "xml", "plist", "entitlements", "storyboard", "xib", "xcscheme", "xcworkspacedata", "xcprivacy",
             "svg", "xsd", "xsl", "xliff", "intentdefinition", "xcdatamodel", "xcmappingmodel":
            return Guess(language: .xml, isProvisional: false)
        case "yaml", "yml": return Guess(language: .yaml, isProvisional: false)
        case "toml": return Guess(language: .toml, isProvisional: false)
        case "sh", "bash", "zsh", "command", "ksh": return Guess(language: .shell, isProvisional: false)
        case "metal": return Guess(language: .metal, isProvisional: false)
        case "xcconfig", "ini", "cfg", "conf", "properties", "strings", "pbxproj", "mk", "make", "env",
             "gitignore", "dockerfile":
            return Guess(language: .config, isProvisional: false)
        default: return byWholeName(name)
        }
    }
}
