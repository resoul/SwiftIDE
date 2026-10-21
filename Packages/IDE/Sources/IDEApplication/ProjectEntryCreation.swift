import Foundation

public enum NewEntryKind: Sendable, Equatable {
    /// Any file, named exactly as typed, empty.
    case file
    /// A Swift file: `.swift` is added to a name without an extension, and it starts with an import.
    case swiftFile
    case folder

    /// The name a file of this kind gets for what the user typed as its last part.
    public func fileName(forTyped name: String) -> String {
        guard self == .swiftFile, (name as NSString).pathExtension.isEmpty, !name.hasSuffix(".") else { return name }

        return name + ".swift"
    }

    /// What a new file of this kind starts with.
    public var initialContents: Data {
        self == .swiftFile ? Data("import Foundation\n".utf8) : Data()
    }
}

public enum NewEntryError: Error, Equatable, Sendable {
    case emptyName
    /// A part of the name is `.`, `..` or has a character a file name cannot hold.
    case invalidName(String)
    case outsideProject
    case notAFolder
    case alreadyExists(String)
    case failed(String)

    public var message: String {
        switch self {
        case .emptyName: "Enter a name."
        case .invalidName(let part): "“\(part)” cannot be used as a file or folder name."
        case .outsideProject: "The new item would be outside the project folder."
        case .notAFolder: "The selected place is not a folder."
        case .alreadyExists(let name): "“\(name)” already exists."
        case .failed(let reason): "Could not create it: \(reason)"
        }
    }
}

/// What the user types for a new file or folder: a name, or a path of names separated by `/`
/// (the folders in between are created too).
public enum NewEntryName {
    /// The parts of `text`, or the reason it cannot be used.
    public static func parts(of text: String) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw NewEntryError.emptyName }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        for part in parts where part.isEmpty || part == "." || part == ".." || part.contains(":")
            || part.contains("\0") {
            throw NewEntryError.invalidName(part.isEmpty ? trimmed : part)
        }

        return parts
    }
}

/// Makes a new file or folder on disk. The adapter checks the place and the name again.
public protocol ProjectEntryCreating: Sendable {
    /// Creates `name` inside `directory` and returns the path of what was created.
    func create(_ kind: NewEntryKind, named name: String, in directory: String) throws -> String
}
