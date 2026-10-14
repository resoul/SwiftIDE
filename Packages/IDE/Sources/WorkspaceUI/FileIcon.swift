import AppKit
import IDEApplication
import UITheme

/// App-owned icons keep file types recognisable regardless of Finder's default application.
@MainActor
enum FileIcon {
    case folder, linkedFolder, swift, project, code, configuration, image, document

    init(file: ProjectFile) {
        self.init(name: file.name, isDirectory: file.isDirectory, isSymbolicLink: file.isSymbolicLink)
    }

    init(name: String, isDirectory: Bool = false, isSymbolicLink: Bool = false) {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory {
            self = isSymbolicLink ? .linkedFolder : ["xcodeproj", "xcworkspace"].contains(ext) ? .project : .folder

            return
        }

        if ext == "swift" { self = .swift }
        else if ["json", "yaml", "yml", "toml", "plist", "xml", "xcconfig", "resolved"].contains(ext)
            || [".gitignore", ".gitattributes", ".swiftformat", ".editorconfig", ".clang-format", ".clangd"]
            .contains(name.lowercased()) {
            self = .configuration
        } else if [
            "c",
            "h",
            "cpp",
            "hpp",
            "cc",
            "cxx",
            "m",
            "mm",
            "js",
            "jsx",
            "ts",
            "tsx",
            "py",
            "go",
            "rs",
            "php",
            "java",
            "kt",
            "kts",
            "rb",
            "sh",
            "zsh",
            "sql"
        ].contains(ext) {
            self = .code
        } else if ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico"].contains(ext) {
            self = .image
        } else { self = .document }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .linkedFolder: "folder.badge.questionmark"
        case .swift: "swift"
        case .project: "tabler:hammer"
        case .code: "tabler:file-code"
        case .configuration: "tabler:settings"
        case .image: "photo"
        case .document: "doc.text"
        }
    }

    var tint: NSColor {
        switch self {
        case .folder, .linkedFolder, .project: WorkspaceTheme.folderIcon
        case .swift: WorkspaceTheme.swiftFileIcon
        case .code: WorkspaceTheme.sourceFileIcon
        case .configuration: WorkspaceTheme.configurationFileIcon
        case .image: WorkspaceTheme.imageFileIcon
        case .document: WorkspaceTheme.fileIcon
        }
    }

    var description: String {
        switch self {
        case .folder: "Folder"
        case .linkedFolder: "Linked folder"
        case .swift: "Swift source file"
        case .project: "Xcode project or workspace"
        case .code: "Source file"
        case .configuration: "Configuration file"
        case .image: "Image file"
        case .document: "Document"
        }
    }

    func image() -> NSImage? { WorkspaceIcon.image(symbol, description: description) }
}
