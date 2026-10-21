import Foundation

/// Renaming, duplicating and deleting files and folders of a project. The adapter checks the place
/// and the names again; it never leaves the project folder, never replaces an existing item, and
/// deletes by moving to the Trash, so nothing is lost for good.
public protocol ProjectItemOperating: Sendable {
    /// Renames `path` inside its folder and returns the new path.
    func rename(_ path: String, to name: String) throws -> String

    /// Copies `path` next to itself under `name` and returns the path of the copy.
    func duplicate(_ path: String, as name: String) throws -> String

    /// Moves `path` to the Trash.
    func trash(_ path: String) throws

    /// Moves `path` into `directory` (inside the project) under its own name and returns the new
    /// path; an item already in that folder stays where it is and its path is returned.
    func move(_ path: String, into directory: String) throws -> String

    /// Copies `path` — which may be outside the project, for something taken from Finder — into
    /// `directory` and returns the copy's path. A name already taken there gets a "copy" name.
    func copy(_ path: String, into directory: String) throws -> String
}

/// Names for existing items: exactly one part, unlike a new item's typed path.
public enum ItemName {
    public static func single(_ text: String) throws -> String {
        let parts = try NewEntryName.parts(of: text)
        guard parts.count == 1 else { throw NewEntryError.invalidName(text) }

        return parts[0]
    }

    /// The name offered for a copy: "Name copy.ext", or "Name copy 2.ext" when that is taken.
    public static func copyName(of name: String, taken: (String) -> Bool = { _ in false }) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // A name like ".env" has no extension: the whole of it is the base.
        let split = base.isEmpty ? (name, "") : (base, ext)

        func candidate(_ number: Int?) -> String {
            let stem = split.0 + " copy" + (number.map { " \($0)" } ?? "")

            return split.1.isEmpty ? stem : stem + "." + split.1
        }

        var number: Int?
        while taken(candidate(number)) { number = (number ?? 1) + 1 }

        return candidate(number)
    }
}

extension NewEntryError {
    /// An item cannot be moved or copied into itself.
    public static let intoItself = NewEntryError.failed("A folder cannot be moved or copied into itself.")

    /// Why an existing item cannot be changed: it is the project folder itself.
    public static let isProjectFolder = NewEntryError.failed("The project folder itself cannot be changed here.")
}
