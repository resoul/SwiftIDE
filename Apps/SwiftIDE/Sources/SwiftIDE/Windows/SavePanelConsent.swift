import AppKit
import IDEApplication
import IDEDomain

@MainActor
final class SavePanelConsent: NSObject, NSOpenSavePanelDelegate {
    private let revisionOfFile: (String) -> FileRevision?
    private var observed: (path: String, revision: FileRevision?)?

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
