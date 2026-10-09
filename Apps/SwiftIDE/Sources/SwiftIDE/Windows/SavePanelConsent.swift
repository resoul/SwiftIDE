import AppKit
import IDEApplication
import IDEDomain

/// Remembers what the Save panel's user agreed to, and for which state of the file.
///
/// Whether a file existed when the panel was dismissed says nothing about whether the user was
/// asked to replace *that* file: one may appear in between. The panel tells its delegate the
/// moment the user confirms a name, and the state of the file is read right there. That state
/// becomes the consent, so anything different at write time is a conflict, not a replacement.
@MainActor
final class SavePanelConsent: NSObject, NSOpenSavePanelDelegate {
    private let revisionOfFile: (String) -> FileRevision?
    private var observed: (path: String, revision: FileRevision?)?

    /// `revisionOfFile` returns the revision of an existing file, nil if there is none.
    init(revisionOfFile: @escaping (String) -> FileRevision?) {
        self.revisionOfFile = revisionOfFile
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag else { return filename }
        let directory = (sender as? NSSavePanel)?.directoryURL
        let full = (filename as NSString).isAbsolutePath
            ? filename : (directory?.appendingPathComponent(filename).path ?? filename)
        observed = (DocumentPath.canonical(full), revisionOfFile(full))
        return filename
    }

    /// What was agreed to for the name the panel finally returned. If the panel did not report
    /// that name (for example because it added an extension), the file is read now: the best
    /// available moment, and still bound to the state that is then written over.
    func target(for url: URL) -> SaveAsTarget {
        let revision: FileRevision?
        if let observed, observed.path == DocumentPath.canonical(url.path) {
            revision = observed.revision
        } else {
            revision = revisionOfFile(url.path)
        }
        return revision.map(SaveAsTarget.replacing) ?? .newFile
    }
}
